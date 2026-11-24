[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/cezar?utm_medium=integration&utm_source=button&utm_campaign=cezar)

# Cezar on Railway

A one-click Railway template for [Cezar](https://github.com/open-mercato/cezar) (MIT), a web cockpit that runs coding agents (Claude Code, Codex, OpenCode) on tasks in their own git worktrees. It shows each step and diff live, and can open draft pull requests.

## What it deploys

One service, `Cezar`, built from this repo's `Dockerfile`:

| Component | Version | Pinned by |
|---|---|---|
| Cezar (`@open-mercato/cezar`) | 0.20.0 | `package-lock.json` (integrity hash) |
| Claude Code (`@anthropic-ai/claude-code`) | 2.1.331 | `package-lock.json` |
| Codex CLI (`@openai/codex`) | 0.172.0 | `package-lock.json` |
| OpenCode (`opencode-ai`) | 1.19.6 | `package-lock.json` |
| GitHub CLI | 2.105.0 | SHA-256 checksum |
| Node.js base | `node:22.23.4-bookworm-slim` | image digest |
| Caddy (login front) | 2.11.9 | image digest |

- Cezar has no login of its own. Caddy listens on `PORT` (8080) and asks for HTTP basic auth before anything reaches Cezar. Cezar itself listens only on `127.0.0.1:4321`, in upstream's hosted mode (`CEZ_REMOTE=1`), as upstream's own server install does behind nginx.
- `/healthz` answers `ok` without a login once Cezar is up (the Railway health check).
- One volume at `/home/cezar` holds the Cezar workspace, cloned projects, task worktrees and the agents' logins. There is no database.
- If Cezar or Caddy stops, the container exits non-zero, so Railway restarts it.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `CEZAR_PASSWORD` | `${{secret(32)}}` | Login password, generated at deploy (at least 16 characters). |
| `CEZAR_USERNAME` | `admin` | Login username. |
| `PORT` | `8080` | Port of the login front. Leave it. |
| `ANTHROPIC_API_KEY` | empty, optional | Lets Claude Code run with an API key. |
| `OPENAI_API_KEY` | empty, optional | Signs Codex in with an API key on the next start. |
| `GH_TOKEN` | empty, optional | GitHub token (`repo` scope) for private repos and draft pull requests. |

You don't have to set any agent key at deploy. You can also sign an agent in with your own subscription from Cezar's terminal (`claude`, `codex login --device-auth`, `opencode auth login`). Logins are kept on the volume.

## After deploy

1. Open the public URL and sign in with `CEZAR_USERNAME` / `CEZAR_PASSWORD`. Both are in the service's Variables tab.
2. Connect an agent (above).
3. Try a task in the bundled `playground` repo, or add your own with **+ → Clone from GitHub**.

## Memory

| RAM limit | Defaults set on first boot |
|---|---|
| under 1 GB (Free plan, 0.5 GB) | One task at a time, LLM task naming off, agent sign-in probes off, idle agent sessions closed after 1 minute. A Claude Code task peaked at about 380 MB of 476 MB on Railway with no process killed. |
| 1–1.5 GB | Same as above, but the sign-in probes are on. |
| 1.5 GB and up | Cezar's own defaults (2 parallel tasks, task naming). |

Change these defaults later under **Settings → Resources**. Use at least 2 GB (Hobby or higher) for parallel tasks, large repositories, or builds and tests inside tasks.

## Not included

- **Docker inside tasks, and Codex's bubblewrap sandbox:** Railway allows neither privileged containers nor user namespaces. Codex runs without its sandbox, which is Cezar's default.
- **Desktop-only features** (open in editor, design-mode preview): upstream turns these off in hosted mode.

## Updates

Railway sends an "update available" notice to every project deployed from this template when `main` changes. Read [`CHANGELOG.md`](CHANGELOG.md) (breaking changes come first), then apply the update from your project. Data on the volume is kept.

## Licence

The template files are MIT. Cezar is MIT, © its authors. Claude Code, Codex and OpenCode are each under their own licences.
