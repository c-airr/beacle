# Beacle

![platform](https://img.shields.io/badge/platform-Windows-brightgreen)
![language](https://img.shields.io/badge/frontend-Flutter-blue)
![language](https://img.shields.io/badge/backend-Go-00ADD8)
![status](https://img.shields.io/badge/status-beta-orange)
![license](https://img.shields.io/badge/license-MIT-green)
![Stars](https://img.shields.io/github/stars/c-airr/beacle)
![issues](https://img.shields.io/github/issues/c-airr/beacle)
![last commit](https://img.shields.io/github/last-commit/c-airr/beacle)
![repo size](https://img.shields.io/github/repo-size/c-airr/beacle)
![top language](https://img.shields.io/github/languages/top/c-airr/beacle)
![contributors](https://img.shields.io/github/contributors/c-airr/beacle)
![last release](https://img.shields.io/github/v/release/c-airr/beacle)

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
