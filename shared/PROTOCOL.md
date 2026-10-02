# Beacle protocol (v1)

Wire contract between the three components. Go types live in `shared/`;
the Flutter app mirrors them in `app/lib/models/`.

## Network model (CGNAT-safe)

- **Backend** is the only network entry point on the desktop (panel API on
  loopback; agents use a separate listener on the Tailscale IP or inside the
  WireGuard tunnel).
- **Agent** connects **outbound-only** to the backend over a single WebSocket.
- The backend **never** initiates TCP connections to agents for commands or
  metrics (WireGuard handshakes are UDP and only carry the same WebSocket).
- Commands and snapshots share that one WebSocket tunnel.

### Transports (2.0)

| Transport   | Agent dials | Notes |
|-------------|-------------|-------|
| `tailscale` | `http://<panel-tailscale-ip>:9930/agent/ws` | default for pre-2.0 servers |
| `wireguard` | `http://10.87.0.1:9930/agent/ws` via in-process tunnel | panel initiates UDP to VPS `:51931` |

Migration from Tailscale: backend `POST /api/vps/{id}/wireguard/migrate` issues
keys and pushes `POST /api/transport/wireguard` to the agent (join token in body).
The agent keeps the old panel URL for `WGSwitchFallback` (10 minutes) until
`register_ack` arrives over WireGuard. Switch back:
`POST /api/vps/{id}/wireguard/switch-tailscale`.

## Agent ↔ Backend (WebSocket only)

**No HTTP** for agent registration or metrics. The agent dials `GET /agent/ws`
once at startup (and reconnects automatically). All traffic is JSON
`AgentWSMessage` frames.

| `type`              | Direction       | Payload fields | Notes |
|---------------------|-----------------|----------------|-------|
| `register`          | agent → backend | `register`     | first frame after connect |
| `register_ack`      | backend → agent | `register_ack` | `vps_id`, `token` (first time), `power_mode` |
| `power_mode`        | backend → agent | `mode`         | `active`, `eco`, or `sleep` — agent owns all intervals |
| `refresh`           | backend → agent | —              | push all snapshots immediately |
| `heartbeat`         | agent → backend | —              | optional JSON liveness; WS Ping/Pong every ~20 s is the real keepalive |
| `metrics`           | agent → backend | `metrics`      | periodic + on critical change |
| `docker_snapshot`   | agent → backend | `docker`       | periodic + on change / user action |
| `systemd_snapshot`  | agent → backend | `services`     | periodic + on change / user action |
| `ports_snapshot`    | agent → backend | `ports`        | periodic + on change |
| `proxy_snapshot`    | agent → backend | `proxy`        | periodic + on change / user action |
| `alert`             | agent → backend | (reserved)     | backend evaluates snapshots today |
| `command`           | backend → agent | `command`      | proxied UI/API request |
| `command_result`    | agent → backend | `result`       | correlated by `request_id` |
| `log_stream`        | either          | (reserved)     | future plugins |
| `file_transfer`     | either          | (reserved)     | future plugins |
| `error`             | backend → agent | `error`        | registration failed |

### Power modes (agent-side intervals)

| Mode   | metrics | ports | docker/systemd/proxy | watchdog |
|--------|---------|-------|--------------------|----------|
| active | 3 s     | 10 s  | 12 s               | off      |
| eco    | 15 s    | 45 s  | 60 s               | 5 s      |
| sleep  | 60 s    | 120 s | 120 s              | 5 s      |

Intervały służą wyłącznie do synchronizacji. Zmiany stanu (crash, service failed,
user action, wysokie CPU itd.) są pushowane natychmiast — nie czekamy na tick.

### Commands

```json
{
  "type": "command",
  "command": {
    "request_id": "a1b2c3d4",
    "method": "POST",
    "path": "/api/docker/containers/abc/restart"
  }
}
```

```json
{
  "type": "command_result",
  "result": {
    "request_id": "a1b2c3d4",
    "status_code": 200,
    "body": {"ok": true}
  }
}
```

Returning agents may send `Authorization: Bearer <token>` on the WebSocket upgrade.
First-time agents connect without a token and register via the `register` frame.

## Backend → Agent (commands over WebSocket)

The UI calls `/api/vps/{id}/agent/*` on the backend; the backend forwards the
request as an `AgentCommand` on the agent's WebSocket. The agent executes the
route locally and returns `AgentCommandResult`. There is **no** inbound HTTP
listener on the agent in production.

### Agent command routes (1.2)

Docker lifecycle (existing): `POST /api/docker/containers/{id}/{start|stop|restart|remove}`,
`GET .../logs`, `GET .../stats`, `GET /api/docker/compose` (read-only list).

New in 1.2:

- `POST /api/docker/containers/{id}/exec` with `{"command": "..."}` — one-shot
  `sh -c` inside the container, 30 s limit, combined output + exit code.
- `POST /api/docker/compose/{project}/{restart|up|down|pull}` — compose CLI in
  the project's working dir (from container labels). `up` means pull-then-up.
  Long timeout (5 min agent-side).
- `GET /api/docker/prune/preview` — reclaimable images/volumes estimate.
- `POST /api/docker/prune` with `{"images": bool, "volumes": bool, "builder": bool}` —
  removes exactly the selected scopes.
- `POST /api/system/processes/{pid}/kill` with `{"signal": "term"|"kill"}` —
  SIGTERM/SIGKILL. The agent refuses PID 1 and its own PID.

### Agent command routes (2.0)

- `GET /api/system/logs` — readable system logs (id/label/path). `GET
  /api/system/logs/{id}?tail=&grep=` — tail with case-insensitive grep.
- `GET /api/system/updates` — pending APT/DNF updates + reboot-required.
  `POST /api/system/updates/apply` — background `upgrade -y`.
  `GET /api/system/updates/status` — running/last job with output tail.
- `GET /api/system/cron` — root crontab (editable) + system cron files +
  systemd timers. `POST /api/system/cron` with a `CronEntrySpec`, `PUT
  /api/system/cron/{id}`, `DELETE /api/system/cron/{id}` — root crontab only.
- `GET /api/firewall/status` — backend (ufw/firewalld/iptables/nftables),
  rules, guarded ports, listeners. `POST /api/firewall/dry-run` previews a
  mutation. `POST /api/firewall/allow|deny` with a `FirewallRuleSpec`,
  `POST /api/firewall/delete` with `{"id","force"}`. The agent refuses to
  deny guarded ports (SSH + agent) to the world; deleting an allow that
  covers them needs `force`.
- `POST /api/system/reboot` with `{"restore": bool}` — snapshots screens +
  running nohups into `/var/lib/beacle/restore.json` when asked, then
  reboots. `POST /api/system/poweroff` — halts. `GET /api/system/restore` —
  last boot-restore result. The backend marks the VPS restarting/powered_off
  so no offline alert fires; the marker expires after 15 min.
- `POST /api/watchdog/config` — watchdog config pushed by the backend
  (persisted as `watchdog.json`, mode 0600). `POST /api/watchdog/send` with
  a `WebhookMessage` — immediate delivery to all targets. `GET
  /api/watchdog/status` — enabled/role/counts (never secret URLs).
- File explorer (wire paths are absolute POSIX paths; errors are 400 bad
  path, 403 protected/disabled, 404 missing, 409 conflict):
  - `GET /api/fs/dir?path=&hidden=1` — `FSListing` with mtime, owner,
    symlink target and a per-file `version`.
  - `GET /api/fs/read?path=&offset=&limit=` — one chunk (default 256 KiB,
    max 1 MiB), base64 `data`, `eof`, `binary` guess on offset 0.
  - `PUT /api/fs/write` with `{"path","content","version"}` — atomic text
    save keeping mode/owner. Empty `version` = create only; a stale
    `version` is 409, so a file edited on the server is never clobbered.
  - `POST /api/fs/upload` with `{"path","offset","data","final","overwrite"}`
    — chunks land in `<path>.beacle-part`, `final` renames into place. A
    wrong offset is 409 with `received` = where to resume.
  - `POST /api/fs/mkdir` `{"path"}`, `POST /api/fs/rename`
    `{"from","to","overwrite"}`, `POST /api/fs/delete` `{"path","recursive"}`.
    `/`, top-level directories and the agent's own files cannot be deleted
    or renamed.
  - `"disable_files": true` in the agent's `config.json` turns all of this
    off (403).
  - `GET /api/fs/list` stays as the screen launcher's picker (no dotfiles).

## UI → Backend

REST under `/api/*`, live stream at `GET /ws` (JSON `WSMessage` frames).
The backend proxies any `/api/vps/{id}/agent/*` request to the matching
agent over WebSocket, so the UI never talks to agents directly.

**Power save:** `POST /api/ui/power-mode` with `{"mode":"active"|"eco"|"sleep"}`.

**Webhooks (2.0):** `GET /api/webhooks` — targets plus the elected
primary/secondary watchers. `PUT /api/webhooks` with `{"targets": [...]}` —
Discord (`kind`, webhook `url`), ntfy (topic `url`), Telegram (`url` = bot
token, `chat_id`). `POST /api/webhooks/test` — test message down the real
path, answers `{"via": ...}`. VPS statuses `restarting` and `powered_off`
ride the normal `vps_list` stream.
The desktop app sends `eco` when idle, `sleep` when minimized/background.
WebSockets stay connected; backend only sets agent power mode.

The current stable GitHub release carries `install_agent.sh`,
`beacle-agent-amd64`, and `beacle-agent-arm64`. The UI one-liner is
`curl -fsSL …/releases/latest/download/install_agent.sh | sudo bash -s -- <backend-url>`.
The script detects the VPS architecture and updates `backend_url` on reinstall
without deleting the registered VPS id or token.
`GET /download/agent?arch=amd64` redirects to the GitHub asset. Clicking
**Update agent** makes the VPS pull the latest asset from GitHub directly.
