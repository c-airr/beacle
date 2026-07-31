<h1 align="center">Beacle</h1>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows-0078d6?logo=windows&logoColor=white" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/frontend-Flutter-02569B?logo=flutter&logoColor=white" alt="Frontend: Flutter">
  <img src="https://img.shields.io/badge/backend-Go-00ADD8?logo=go&logoColor=white" alt="Backend: Go">
  <img src="https://img.shields.io/badge/protocol-gRPC-4285F4?logo=grpc&logoColor=white" alt="Protocol: gRPC">
  <img src="https://img.shields.io/badge/security-mTLS-critical?logo=letsencrypt&logoColor=white" alt="Security: mTLS">
  <img src="https://img.shields.io/badge/networking-Tailscale-black?logo=tailscale&logoColor=white" alt="Networking: Tailscale">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Status: beta">
  <img src="https://img.shields.io/github/license/c-airr/beacle" alt="License">
</p>

<p align="center">
  <img src="https://img.shields.io/github/stars/c-airr/beacle?style=social" alt="GitHub stars">
  <img src="https://img.shields.io/github/forks/c-airr/beacle?style=social" alt="GitHub forks">
  <img src="https://img.shields.io/github/issues/c-airr/beacle" alt="Open issues">
  <img src="https://img.shields.io/github/issues-pr/c-airr/beacle" alt="Open PRs">
  <img src="https://img.shields.io/github/last-commit/c-airr/beacle" alt="Last commit">
  <img src="https://img.shields.io/github/commit-activity/m/c-airr/beacle" alt="Commit activity">
</p>

<p align="center">
  <img src="https://img.shields.io/github/repo-size/c-airr/beacle" alt="Repo size">
  <img src="https://img.shields.io/github/languages/top/c-airr/beacle" alt="Top language">
  <img src="https://img.shields.io/github/v/release/c-airr/beacle?include_prereleases" alt="Latest release">
  <img src="https://img.shields.io/github/downloads/c-airr/beacle/total" alt="Total downloads">
</p>

**Status: BETA** — finishing infrastructure. **v1.0 target: when i feel like it**

## Roadmap

### Now (BETA) — infrastructure

- [x] Single WebSocket tunnel agent ↔ backend (register, snapshots, commands, power modes)
- [x] Embedded backend lifecycle in `beacle.exe`
- [x] Tailscale `serve` + Windows firewall helpers
- [ ] Stable agent deploy path (mirror / GitHub releases)
- [ ] End-to-end reliability: persistent WS, no stale UI

### v1.0 (~1 week) — first release

- Finish and polish the full UI (Overview, Servers, Processes, Docker, Systemd, Proxy, Map, Alerts, Settings)
- Onboarding and VPS install flow that “just works”
- Adaptive refresh (active / eco / sleep) without dropping WebSocket
- Documentation and release binaries

### v2.0 — platform

- **Plugin system** — extend Beacle with custom panels and data frames without forking core
- **Architecture refresh** — cleaner separation for long-term maintenance
- **No Tailscale requirement** — direct or tunneled connectivity options
- UI refresh and improved navigation
- Performance and UX improvements across the board
