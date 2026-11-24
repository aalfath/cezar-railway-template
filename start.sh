#!/bin/bash
# Start Cezar on Railway: Cezar on 127.0.0.1:4321 (hosted mode), Caddy on $PORT in
# front of it with HTTP basic auth. Runs as root only to prepare the volume, then
# both processes run as the "cezar" user (UID 1000). If either process stops, the
# container exits non-zero so Railway's ON_FAILURE restart policy brings it back.
set -euo pipefail

log() { echo "[cezar-railway] $*"; }
die() { echo "[cezar-railway] ERROR: $*" >&2; exit 1; }

HOME_DIR=/home/cezar
export HOME="$HOME_DIR" USER=cezar LOGNAME=cezar SHELL=/bin/bash

# --- Login: required, Cezar has no authentication of its own ------------------
CEZAR_USERNAME="${CEZAR_USERNAME:-admin}"
CEZAR_PASSWORD="${CEZAR_PASSWORD:-}"
[ -n "$CEZAR_PASSWORD" ] || die "CEZAR_PASSWORD is empty. Set it to a long random value (the template generates one)."
[ "${#CEZAR_PASSWORD}" -ge 16 ] || die "CEZAR_PASSWORD is shorter than 16 characters."
case "$CEZAR_USERNAME" in ''|*[!A-Za-z0-9._@-]*) die "CEZAR_USERNAME may only contain letters, digits and . _ @ -";; esac
CEZAR_PASSWORD_HASH="$(caddy hash-password --plaintext "$CEZAR_PASSWORD")" || die "could not hash CEZAR_PASSWORD"
[ -n "$CEZAR_PASSWORD_HASH" ] || die "could not hash CEZAR_PASSWORD"
export CEZAR_USERNAME CEZAR_PASSWORD_HASH
unset CEZAR_PASSWORD

export PORT="${PORT:-8080}"
[ "$PORT" != 4321 ] || die "PORT must not be 4321 (Cezar's internal port)."

# --- Size thread pools to the service, not the host -------------------------
# Railway shows every host CPU (32+) inside a 1 vCPU service.
cpus=2
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ]; then
    cpus=$(( (quota + period - 1) / period ))
  fi
fi
[ "$cpus" -ge 2 ] || cpus=2
[ "$cpus" -le 8 ] || cpus=8
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$cpus}" GOMAXPROCS="${GOMAXPROCS:-$cpus}"
export TOKIO_WORKER_THREADS="${TOKIO_WORKER_THREADS:-$cpus}" RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$cpus}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

# Memory limit of this service in MB (Railway Free plan: 512).
mem_mb=0
if [ -r /sys/fs/cgroup/memory.max ]; then
  m="$(cat /sys/fs/cgroup/memory.max)"
  [ "$m" = max ] || mem_mb=$(( m / 1048576 ))
fi
log "service limits: ${cpus} threads, memory ${mem_mb} MB (0 = no limit)"

# Small plans. Each agent session is its own CLI process (Claude Code ~200 MB),
# and Cezar also starts a second one to name tasks and runs every agent's login
# check (up to ~300 MB for OpenCode) when a task starts. Below 1.5 GB: one task
# at a time, finished sessions closed after 1 idle minute, no LLM task naming.
# Below 1 GB (Railway Free plan): Cezar also skips its login checks and uses
# each agent's own model setting. Any variable you set yourself wins.
max_parallel=2 idle_minutes=15
if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 1500 ]; then
  max_parallel=1 idle_minutes=1
  export CEZ_AUTONAME="${CEZ_AUTONAME:-0}"
  log "small plan (${mem_mb} MB): one task at a time, LLM task naming off"
fi
if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 1000 ]; then
  export CEZ_AGENT_MODELS_LOCKED="${CEZ_AGENT_MODELS_LOCKED:-1}"
  log "under 1 GB: agent login checks off, agents use their own model settings"
fi

# --- Volume: Railway mounts it root-owned; Cezar runs as UID 1000 -------------
mkdir -p "$HOME_DIR"
if [ "$(id -u)" = 0 ] && [ "$(stat -c %u "$HOME_DIR")" != 1000 ]; then
  log "preparing $HOME_DIR for the cezar user"
  chown -R 1000:1000 "$HOME_DIR"
fi
as_cezar() {
  if [ "$(id -u)" = 0 ]; then setpriv --reuid=1000 --regid=1000 --init-groups -- "$@"; else "$@"; fi
}
as_cezar mkdir -p "$HOME_DIR/.cezar" "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local/bin" "$HOME_DIR/cezar/projects"
[ -f "$HOME_DIR/.bashrc" ] || as_cezar cp /etc/skel/.bashrc "$HOME_DIR/.bashrc" 2>/dev/null || true
[ -f "$HOME_DIR/.profile" ] || as_cezar cp /etc/skel/.profile "$HOME_DIR/.profile" 2>/dev/null || true
if [ ! -f "$HOME_DIR/.gitconfig" ]; then
  as_cezar git config --global init.defaultBranch main
  as_cezar git config --global user.name "Cezar"
  as_cezar git config --global user.email "cezar@localhost"
fi
# First boot only: seed the workspace config with a parallel cap that fits.
if [ ! -f "$HOME_DIR/.cezar/config.json" ]; then
  as_cezar sh -c "umask 077; printf '{\"schemaVersion\":2,\"resources\":{\"maxParallel\":%s,\"maxMonitoringSessions\":%s,\"idleTimeoutMinutes\":%s}}\n' $max_parallel $(( max_parallel == 1 ? 0 : 2 )) $idle_minutes > '$HOME_DIR/.cezar/config.json'"
  log "first boot: parallel tasks $max_parallel, idle session timeout $idle_minutes min (Settings -> Resources)"
fi

# Cockpit ownership leases from the previous container (old PIDs) make Cezar
# refuse to start after a restart or redeploy ("Cannot verify foreign owner
# identity"). Nothing else runs in this container yet, so they are stale;
# upstream documents removing this folder as safe while no cockpit runs.
if [ -d "$HOME_DIR/.cezar/runtime" ]; then
  rm -r "$HOME_DIR/.cezar/runtime"
  log "cleared stale cockpit leases from the previous container"
fi
# Run-index writer tickets left by a container that was killed mid-write carry
# the old container's hostname, and upstream only reaps those after 5 minutes,
# so saving runs fails until then. No cezar runs yet, so every ticket is stale.
find "$HOME_DIR" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \
  -type d -path '*/.ai/cezar/runs/.index-writers' -print 2>/dev/null |
  while IFS= read -r d; do
    find "$d" -maxdepth 1 -type f -name '*.ticket*' -delete 2>/dev/null || true
  done

# --- Optional agent keys ------------------------------------------------------
# Claude Code reads ANTHROPIC_API_KEY itself. Codex keeps its login in
# ~/.codex/auth.json, so a provided OPENAI_API_KEY is saved there once.
for v in ANTHROPIC_API_KEY OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN; do
  [ -n "${!v:-}" ] || unset "$v"
done
if [ -n "${OPENAI_API_KEY:-}" ] && ! as_cezar codex login status >/dev/null 2>&1; then
  if printenv OPENAI_API_KEY | as_cezar codex login --with-api-key >/dev/null 2>&1; then
    log "Codex: signed in with OPENAI_API_KEY"
  else
    log "Codex: could not sign in with OPENAI_API_KEY (Cezar still starts; sign in from the terminal)"
  fi
fi

# Cezar serves the folder it starts in as its first project. Start it in a small
# git repo ("playground") so a new deployer can run a task straight away; real
# projects are added from the cockpit (Clone from GitHub or Open local folder).
PLAYGROUND="$HOME_DIR/cezar/projects/playground"
if [ ! -d "$PLAYGROUND/.git" ]; then
  as_cezar mkdir -p "$PLAYGROUND"
  as_cezar sh -c "cd '$PLAYGROUND' && git init -q -b main && printf '# Playground\\n\\nA scratch repository for trying Cezar. Add your own projects from the cockpit.\\n' > README.md && git add README.md && git -c user.name=Cezar -c user.email=cezar@localhost commit -q -m 'Playground for Cezar'"
  log "first boot: created the playground project"
fi
cd "$PLAYGROUND"
cez_ver="$(node -p 'require("/opt/cezar/node_modules/@open-mercato/cezar/package.json").version' 2>/dev/null || echo "?")"
log "starting Cezar v${cez_ver} on 127.0.0.1:4321 and the login front on :$PORT"

as_cezar cezar serve --no-open --port 4321 &
cezar_pid=$!
as_cezar caddy run --config /etc/cezar/Caddyfile --adapter caddyfile &
caddy_pid=$!

stop() { kill -TERM "$cezar_pid" "$caddy_pid" 2>/dev/null || true; }
trap 'stop; wait; exit 143' TERM INT

# Exit as soon as either process stops, always with a non-zero status.
while kill -0 "$cezar_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  sleep 2
done
code=0
if ! kill -0 "$cezar_pid" 2>/dev/null; then wait "$cezar_pid" || code=$?; who=cezar; else wait "$caddy_pid" || code=$?; who=caddy; fi
stop
[ "$code" -ne 0 ] || code=1
die "$who stopped (exit $code); exiting so Railway restarts the service"
