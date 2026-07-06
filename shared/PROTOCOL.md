# Beacle protocol (v1)

Wire contract between the three components. Go types live in this package;
the Flutter app mirrors them in `app/lib/models/`.

## Network model (CGNAT-safe)

- **Backend** is the only network entry point.
- **Agent** and **UI** connect **outbound-only** to the backend.
- The backend **never** initiates TCP connections to agents or clients.
- Commands to agents are pushed over the agent's existing outbound WebSocket.

## Agent → Backend

**Zero-config auto-registration.** A first-time agent calls
`/api/agents/register` with **no** Authorization header; the backend creates
the VPS entry automatically and returns the assigned `vps_id` + `token` in
`RegisterResponse`. The agent persists them in its config and uses
`Authorization: Bearer <token>` for everything afterwards. There is no manual
"create VPS" endpoint.

| Method | Path                  | Body              | Notes |
|--------|-----------------------|-------------------|-------|
| POST   | `/api/agents/register`| `RegisterRequest` | on startup; unauthenticated first time |
| POST   | `/api/agents/report`  | `AgentReport`     | optional HTTP fallback (outbound) |
| GET    | `/agent/ws`           | —                 | outbound WebSocket tunnel (Bearer token) |

### Agent WebSocket (`GET /agent/ws`)

JSON frames use `AgentWSMessage`:

| `type`           | Direction        | Payload field | Notes |
|------------------|------------------|---------------|-------|
| `report`         | agent → backend  | `report`      | periodic metrics (default 5 s) |
| `command`        | backend → agent  | `command`     | proxied UI/API request |
| `command_result` | agent → backend  | `result`      | HTTP-equivalent response |
| `ping` / `pong`  | either           | —             | keepalive |

`AgentCommand` fields: `id`, `method`, `path` (e.g. `/api/system/processes`),
optional `body`. `AgentCommandResult` fields: `id`, `status_code`, `body`.

## Backend → Agent (commands over WebSocket)

The UI calls `/api/vps/{id}/agent/*` on the backend; the backend forwards the
request as an `AgentCommand` on the agent's WebSocket. The agent executes the
route locally and returns `AgentCommandResult`. There is **no** inbound HTTP
listener on the agent in production.

Equivalent agent API paths (executed locally after WS delivery):

| Method | Path | Notes |
|--------|------|-------|
| GET  | `/api/health` | liveness |
| GET  | `/api/system` | `SystemMetrics` |
| GET  | `/api/system/processes` | `[]ProcessInfo` |
| GET  | `/api/system/ports` | `[]PortInfo` |
| GET  | `/api/system/ports/{port}` | `PortInfo` + health probe |
| GET  | `/api/docker/containers` | `[]ContainerInfo` |
| POST | `/api/docker/containers/{id}/start\|stop\|restart` | |
| GET  | `/api/docker/containers/{id}/logs?tail=200` | text |
| GET  | `/api/docker/containers/{id}/stats` | `ContainerStats` |
| GET  | `/api/docker/images` | `[]ImageInfo` |
| GET  | `/api/docker/compose` | `[]ComposeProject` |
| GET  | `/api/services/systemd` | `[]SystemdUnit` |
| POST | `/api/services/systemd/{unit}/start\|stop\|restart` | |
| GET  | `/api/services/systemd/{unit}/logs?lines=200` | journalctl |
| GET  | `/api/services/screen` | `[]ScreenSession` |
| GET  | `/api/proxy` | `ProxyState` (provider auto-detected) |
| POST | `/api/proxy/sites` | `ProxySiteRequest` → add site |
| PUT  | `/api/proxy/sites/{id}` | edit site |
| DELETE | `/api/proxy/sites/{id}` | delete site |
| POST | `/api/proxy/reload` | reload provider config |
| POST | `/api/proxy/validate` | `ProxyValidateResult` |
| GET  | `/api/ping?target=host` | `PingResult` (used for VPS↔VPS links) |
| POST | `/api/update` | self-update from backend `/download/agent` |
| POST | `/api/rollback` | restore previous binary |

## UI → Backend

REST under `/api/*`, live stream at `GET /ws` (JSON `WSMessage` frames).
The backend proxies any `/api/vps/{id}/agent/*` request to the matching
agent over WebSocket, so the UI never talks to agents directly.

Install script: `GET /install` returns the universal bash installer (same for
every VPS - the agent auto-registers); agent binary:
`GET /download/agent?arch=amd64`. The UI fetches the one-liner from
`GET /api/install-command`.

Backend public URL: set `BEACLE_PUBLIC_URL` or `-base-url` (used in install
commands). Flutter app: `BEACLE_BACKEND` dart-define at build time.
