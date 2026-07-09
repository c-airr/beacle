# Beacle

Local-first VPS management panel. **Each user runs their own backend** — bundled with the desktop app, no central SaaS.

**Current status: BETA** — we are finishing the core infrastructure (agent ↔ backend WebSocket protocol, embedded backend, Tailscale exposure). **v1.0 target: ~1 week** — complete UI polish and first stable release.

## How it works

| Component | Where |
|-----------|--------|
| Panel + backend | Your PC — `beacle.exe` starts the local backend automatically |
| Agents | Linux VPS — install via `curl …/install.sh \| sudo bash` (or your mirror) |
| Data | Per-user isolation (`%AppData%\Beacle\data\`) |

```
beacle.exe  →  starts  →  beacle-backend.exe (127.0.0.1:8930)
                                    ↑
VPS agent ───── outbound WebSocket ─┘
```

Agents connect **outbound-only** over a single persistent WebSocket (`/agent/ws`). No inbound connections to the VPS. See `shared/PROTOCOL.md`.

## Quick start (from release)

1. Download the release bundle: `beacle.exe`, `beacle-backend.exe`, and `data/`
2. Run `beacle.exe` — the backend starts automatically
3. Complete onboarding (Tailscale required in v1)
4. **Settings → VPS** — copy the install command
5. On each VPS (as root): run the install command
6. Servers appear in Overview / Servers with live metrics

**Backend URL** in the install command = your Tailscale IP on port `8930` (via `tailscale serve` on Windows).

## Build (maintainer)

```powershell
.\scripts\build.ps1
# Output: app\build\windows\x64\runner\Release\
```

VPS install (agent served by your backend):

```bash
curl -fsSL http://<your-tailscale-ip>:8930/install | sudo bash -s http://<your-tailscale-ip>:8930
```

## CGNAT / networking (v1)

- Panel ↔ backend: always `127.0.0.1:8930`
- Agent → backend: outbound WebSocket to your Tailscale IP (`tailscale serve` forwards to localhost)
- Tailscale is **required** in v1 for agent reachability without port forwarding

## Roadmap

### Now (BETA) — infrastructure

- [x] Single WebSocket tunnel agent ↔ backend (register, snapshots, commands, power modes)
- [x] Embedded backend lifecycle in `beacle.exe`
- [x] Tailscale `serve` + Windows firewall helpers
- [ ] Stable agent deploy path (mirror / GitHub releases)
- [ ] End-to-end reliability: persistent WS, no stale UI

### v1.0 (~1 week) — first release

- Finish and polish the full UI (Overview, Servers, Metrics, Docker, Systemd, Proxy, Map, Alerts, Settings)
- Onboarding and VPS install flow that “just works”
- Adaptive refresh (active / eco / sleep) without dropping WebSocket
- Documentation and release binaries

### v2.0 — platform

- **Plugin system** — extend Beacle with custom panels and data frames (e.g. CPU temperature) without forking core
- **Architecture refresh** — cleaner separation for long-term maintenance
- **No Tailscale requirement** — direct or tunneled connectivity options
- UI refresh and improved navigation
- Performance and UX improvements across the board

## Monorepo

```
/app     Flutter desktop + embedded backend launcher
/backend Go API (bundled as beacle-backend.exe)
/agent   Linux agent (WebSocket-only to backend)
/shared  DTOs, thresholds, PROTOCOL.md
```

Details: `STRUKTURA.txt`, `shared/PROTOCOL.md`

## License

See `LICENSE`.
