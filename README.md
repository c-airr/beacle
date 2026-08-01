<h1 align="center">Beacle</h1>
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078d6?logo=windows&logoColor=white)](#)
[![Frontend: Flutter](https://img.shields.io/badge/frontend-Flutter-02569B?logo=flutter&logoColor=white)](#)
[![Backend: Go](https://img.shields.io/badge/backend-Go-00ADD8?logo=go&logoColor=white)](#)
[![Protocol: gRPC](https://img.shields.io/badge/protocol-gRPC-4285F4?logo=grpc&logoColor=white)](#)
[![Security: mTLS](https://img.shields.io/badge/security-mTLS-critical?logo=letsencrypt&logoColor=white)](#)
[![Networking: Tailscale](https://img.shields.io/badge/networking-Tailscale-black?logo=tailscale&logoColor=white)](#)
[![Status: beta](https://img.shields.io/badge/status-beta-orange)](#)
[![License](https://img.shields.io/github/license/c-airr/beacle)](#)

[![GitHub stars](https://img.shields.io/github/stars/c-airr/beacle?style=social)](https://github.com/c-airr/beacle/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/c-airr/beacle?style=social)](https://github.com/c-airr/beacle/forks)
[![Open issues](https://img.shields.io/github/issues/c-airr/beacle)](#)
[![Open PRs](https://img.shields.io/github/issues-pr/c-airr/beacle)](#)
[![Last commit](https://img.shields.io/github/last-commit/c-airr/beacle)](#)
[![Commit activity](https://img.shields.io/github/commit-activity/m/c-airr/beacle)](#)

A desktop panel for managing your VPS fleet, so you don't have to juggle SSH sessions across ten terminals anymore. Monitoring, Docker, systemd, reverse proxy, and a map of your infrastructure — all in one app.

**Status: BETA** — infra works, wrapping up the last pieces. v1.0 drops when it's ready.

---

## What it actually does

Beacle is three components talking to each other over Tailscale:

- **Flutter app (Windows)** — the panel you run on your PC
- **Go backend** — runs locally alongside the app (embedded in `beacle.exe`), talks to agents over WebSocket
- **Go agent** — sits on each of your VPS instances, collects metrics, manages Docker/systemd/proxy

All traffic goes over Tailscale, outbound-only, so you don't need to open any ports or worry about CGNAT. The agent connects to the backend, not the other way around.

### What's in the panel

- **Overview** — status of all your servers at a glance
- **Servers** — CPU / RAM / disk / network per VPS, live
- **Processes** — running processes and open ports
- **Docker** — containers, images, compose
- **Systemd** — services + screen sessions
- **Reverse proxy** — GUI for Caddy or Nginx Proxy Manager, no manual config editing
- **Map** — a map of your infrastructure with server locations and latency between them
- **Alerts** — notifications when thresholds are breached (CPU, RAM, server offline) — with hysteresis, so it doesn't spam every 5 seconds
- **Settings** — VPS management, Tailscale, updates

---

## Getting it running

You'll need Tailscale installed on your PC and on every VPS you want to connect. Beacle doesn't manage the VPN itself, it just rides on top of it.

1. Download and run `beacle.exe` on Windows — the backend starts alongside the app in the background
2. On first launch you'll go through a short setup wizard
3. Add your VPS instances from the Tailscale device list
4. On each VPS, run the one-liner the panel gives you

That's it — the agent registers itself and the panel starts getting data.

---

## Roadmap

### Now (BETA) — infrastructure

- [x] Single WebSocket tunnel agent ↔ backend (register, snapshots, commands, power modes)
- [x] Backend embedded in `beacle.exe` lifecycle
- [x] Tailscale `serve` + Windows firewall helpers
- [ ] Stable agent deploy path (mirror / GitHub releases)
- [ ] End-to-end reliability: persistent WS, no stale UI

### v1.0 (~1 week) — first release

- Finish and polish the full UI (Overview, Servers, Processes, Docker, Systemd, Proxy, Map, Alerts, Settings)
- Onboarding and VPS install flow that "just works"
- Adaptive refresh (active / eco / sleep) without dropping WebSocket
- Documentation and release binaries

### v2.0 — platform

- **Plugin system** — extend Beacle with custom panels and data frames without forking core
- **Architecture refresh** — cleaner separation for long-term maintenance
- **No Tailscale requirement** — direct or tunneled connectivity options
- UI refresh and improved navigation
- Performance and UX improvements across the board

---

## Stack

Dart (Flutter) · Go · gRPC · mTLS · Tailscale

## License

MIT
