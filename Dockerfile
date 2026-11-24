# Cezar (https://github.com/open-mercato/cezar, MIT) for Railway.
# Cezar is published on npm only (no official image), so this image installs the
# exact release from package-lock.json on a pinned Node.js LTS base. Caddy (from the
# official image, pinned) is the public front with HTTP basic auth, because Cezar
# has no login of its own: upstream's server install does the same with nginx.
FROM caddy:2.11.9@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b AS caddy

FROM node:22.23.4-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

ARG GH_VERSION=2.105.0
ARG GH_SHA256=79e7ab5db738c48777b696e374f8b428f0647debfb424f44d2f426370407fe2f

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git less openssh-client procps ripgrep tini util-linux \
 && rm -rf /var/lib/apt/lists/* \
 # GitHub CLI (clone from GitHub, draft PRs), pinned and checksum-verified.
 && curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tgz" | sha256sum -c - \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -r /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_amd64" \
 # Upstream's server install runs Cezar as a normal user; reuse the node image's
 # UID 1000 user, renamed, with its home on the Railway volume.
 && groupmod -n cezar node \
 && usermod -l cezar -d /home/cezar -m node \
 # Keep git inside a 0.5 GB service when cloning or repacking big repositories.
 && git config --system pack.threads 1 \
 && git config --system pack.windowMemory 64m \
 && git config --system pack.deltaCacheSize 32m \
 && git config --system core.packedGitLimit 128m \
 && git config --system core.packedGitWindowSize 32m \
 && git config --system core.bigFileThreshold 16m

# Cezar v0.20.0 plus the agent CLIs it drives (Claude Code, Codex, OpenCode),
# all pinned in package-lock.json.
WORKDIR /opt/cezar
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund --loglevel=error \
 && npm cache clean --force \
 && test "$(node -p 'require("@open-mercato/cezar/package.json").version')" = 0.20.0 \
 && node_modules/.bin/cezar --help >/dev/null \
 && node_modules/.bin/claude --version \
 && node_modules/.bin/codex --version \
 && node_modules/.bin/opencode --version

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/cezar/Caddyfile
COPY start.sh /usr/local/bin/cezar-railway-start
RUN chmod 0755 /usr/local/bin/cezar-railway-start \
 && caddy version \
 && CEZAR_USERNAME=x CEZAR_PASSWORD_HASH=x PORT=8080 caddy validate --config /etc/cezar/Caddyfile --adapter caddyfile

ENV HOME=/home/cezar \
    PATH=/home/cezar/.local/bin:/opt/cezar/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NPM_CONFIG_PREFIX=/home/cezar/.local \
    CEZ_REMOTE=1 \
    CEZ_TERMINAL=1 \
    CEZ_NO_BANNER=1 \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    PORT=8080

EXPOSE 8080
# /home/cezar must be a Railway volume: Cezar's workspace (~/.cezar), cloned
# projects and their task worktrees, and the agents' own logins live there.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/bin/cezar-railway-start"]
