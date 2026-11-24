# Changelog

Breaking changes are listed first in each entry.

## 2026-11-24: Cezar 0.20.0 (first release)

- Cezar 0.20.0 with Claude Code 2.1.331, Codex 0.172.0, OpenCode 1.19.6 and GitHub CLI 2.105.0 on `node:22.23.4-bookworm-slim`.
- Caddy 2.11.9 login front (basic auth, generated password), `/healthz` health check.
- One volume at `/home/cezar`. First-boot resource defaults are sized from the service's RAM limit.
- At boot, clears stale cockpit leases and run-index tickets left by the previous container, so restarts and redeploys come up cleanly.
