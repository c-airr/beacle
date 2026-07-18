# Beacle

**Status: BETA** — finishing infrastructure. **v1.0 target: ~1 week.**

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
