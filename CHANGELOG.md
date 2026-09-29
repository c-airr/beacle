# Changelog

## 2.0.0 — 2026-09-29

Admin release: firewall, updates, cron, reboot-and-restore, system logs,
webhooks, tags and per-server thresholds.

### Added

- **Tags and per-server thresholds** — group servers with tags and filter by
  them; override CPU/RAM/disk alert thresholds per server.
- **System log viewer** — syslog, auth.log, dmesg and proxy logs with live
  grep filtering.
- **OS updates** — pending APT/DNF updates with a security count, one-click
  background upgrade, reboot-required flag.
- **Cron and timers** — view crontabs and systemd timers, add and edit cron
  entries without memorizing the syntax.
- **Firewall manager** — UFW, firewalld and iptables behind one panel
  (nftables-only hosts get a read-only listing), with an SSH guard that
  refuses to lock you out and a dry-run of every change.
- **Reboot and restore** — reboot/poweroff from the panel with automatic
  screen and nohup session restore afterwards; no false offline alerts
  while the box is gone.
- **Alert webhooks** — Discord, ntfy.sh and Telegram notifications sent by
  the two most stable servers, so they arrive even with the desktop off.

## 1.2.0 — 2026-09-28

Docker grows up, processes can be killed, and the panel speaks Polish.

### Added

- **Docker Exec** — run a one-shot command inside any container (`cat .env`,
  migrations, …) with output, exit code and a 10-command history. The old
  "not wired yet" placeholder is gone.
- **Docker Compose actions** — Restart, Pull, Down and Pull & Up per project,
  with a progress dialog and full CLI output.
- **Docker Prune** — reclaim disk space with a preview of what will be freed
  before anything is removed. Volumes stay opt-in, off by default.
- **Kill processes** — SIGTERM / SIGKILL straight from the processes table,
  with a confirmation showing PID and command. The agent refuses PID 1 and
  its own PID.
- **Polish language** — English + Polish for onboarding, navigation, Docker,
  Services and Settings. First-run setup asks for the language (English by
  default); switch anytime in Settings. Remaining screens still English.

### Fixed

- Backend proxy timeouts for long operations: compose actions get 6 min,
  prune 3 min, exec 45 s — no more 502 while the agent is still pulling
  images.

### Protocol

- New agent routes: `POST /api/docker/containers/{id}/exec`,
  `POST /api/docker/compose/{project}/{action}`,
  `GET /api/docker/prune/preview`, `POST /api/docker/prune`,
  `POST /api/system/processes/{pid}/kill`. See `shared/PROTOCOL.md`.

## 1.1.0

- Stable release: monitoring, Docker, systemd, reverse proxy, map, alerts.
- Builds for Windows, Linux and macOS, built and attested by CI.
