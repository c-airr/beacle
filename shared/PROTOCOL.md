# Beacle protocol (v1)

Wire contract between the three components. Go types live in `shared/`;
the Flutter app mirrors them in `app/lib/models/`.

## Network model (CGNAT-safe)

- **Backend** is the only network entry point on the desktop.
- **Agent** connects **outbound-only** to the backend over a single WebSocket.
- The backend **never** initiates TCP connections to agents.
- Commands and snapshots share that one WebSocket tunnel.

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
| `heartbeat`         | either          | —              | keepalive ~15 s |
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

## UI → Backend

REST under `/api/*`, live stream at `GET /ws` (JSON `WSMessage` frames).
The backend proxies any `/api/vps/{id}/agent/*` request to the matching
agent over WebSocket, so the UI never talks to agents directly.

**Power save:** `POST /api/ui/power-mode` with `{"mode":"active"|"eco"|"sleep"}`.
The desktop app sends `eco` when idle, `sleep` when minimized/background.
WebSockets stay connected; backend only sets agent power mode.

Install script: `GET /install` returns the universal bash installer; agent binary:
`GET /download/agent?arch=amd64`. The UI fetches the one-liner from
`GET /api/install-command`.
