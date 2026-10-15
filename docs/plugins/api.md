# Plugin API reference

Everything a Beacle plugin can call, return and name. For a walk-through,
see [Writing Beacle plugins](README.md). The same API is described for
editors in [`plugins/beacle.d.lua`](../../plugins/beacle.d.lua).

Plugins need Beacle 2.2.0 or later — the panel and, for `agent.lua`, the
agent on each server.

- [Where each function exists](#where-each-function-exists)
- [Common](#common)
- [agent.lua](#agentlua)
- [backend.lua](#backendlua)
- [Slots](#slots)
- [Blocks](#blocks)
- [Hide ids](#hide-ids)
- [Icons](#icons)
- [Text keys](#text-keys)
- [manifest.json](#manifestjson)
- [Lua environment](#lua-environment)
- [Panel HTTP API](#panel-http-api)

## Where each function exists

| | agent.lua | backend.lua |
|---|:-:|:-:|
| `beacle.log`, `print` | ✓ | ✓ |
| `beacle.every` | ✓ | ✓ |
| `beacle.on` | ✓ | ✓ |
| `beacle.json.encode/decode` | ✓ | ✓ |
| `beacle.store.get/set` | ✓ | ✓ |
| `beacle.http.get/post` | ✓ | ✓ |
| `beacle.read`, `beacle.list` | ✓ | |
| `beacle.exec` | ✓ | |
| `beacle.metric` | ✓ | |
| `beacle.servers`, `beacle.value`, `beacle.call` | | ✓ |
| `beacle.slot`, `beacle.text`, `beacle.hide` | | ✓ |
| `ui.*` | | ✓ |

Functions that can fail in an expected way (a missing file, a host that does
not answer) return `nil, error_message` instead of raising, so they read as:

```lua
local body, err = beacle.http.get(url)
if not body then beacle.log("fetch failed: " .. err) return end
```

Misuse — a wrong argument type, an undeclared metric, `every` under 5
seconds — raises a Lua error.

## Common

### `beacle.log(...)`

Writes its arguments, separated by spaces, to the plugin's log. `print` is
the same function. The backend part's last 200 lines are under **Log** in
Settings → Plugins; the agent part writes to the agent's log on the server.

### `beacle.every(seconds, fn)`

Runs `fn()` right away and then every `seconds` (a number, at least 5).
Call it at the top level of the file — tasks are started once the file has
loaded. An error in `fn` is logged and the next run goes ahead; five errors
in a row stop the plugin on that side, and its metrics with it. Tasks of one
plugin never run at the same time as each other or as its handlers.

### `beacle.on(name, fn)`

Registers handler `name`. `fn(args)` gets one argument and its return value
is the answer.

- In **agent.lua**: called by `beacle.call(server, name, args)` from the
  backend part.
- In **backend.lua**: called by a `ui.button` or `ui.input` in the panel.
  `args` is the button's `args` table, or `{ value = text }` for an input,
  plus `server` (the server's id) when the block is drawn for a server. A
  string it returns is shown to the user as a toast.

Arguments and return values are plain data: `nil`, booleans, numbers,
strings, and tables of those (lists or string-keyed maps). Functions are
dropped.

### `beacle.json.encode(value)` → `string` | `nil, err`

### `beacle.json.decode(text)` → `value` | `nil, err`

Lists become JSON arrays, other tables objects. An empty table encodes as
`[]`. Numbers decode as Lua numbers, `null` as `nil`.

### `beacle.store.get(key)` → `value`

### `beacle.store.set(key, value)`

Keeps plain data across restarts. `nil` deletes the key. The whole store
holds at most 64 KiB of JSON; a `set` past that raises an error and changes
nothing. The backend and each agent have a store of their own. Removing the
plugin deletes its stores.

### `beacle.http.get(url)` → `body, status` | `nil, err`

### `beacle.http.post(url, body?, content_type?)` → `body, status` | `nil, err`

`url` must be `http://` or `https://` with a host listed in
`permissions.http`; redirects to other hosts are refused. `content_type`
defaults to `application/json`. A response is a `body` (up to 1 MiB) and
its HTTP `status` — a 404 is an answer, not an error. 10 s timeout.

## agent.lua

### `beacle.read(path)` → `string` | `nil, err`

Reads a whole file, up to 1 MiB. `path` must be absolute and, once `.` and
`..` are resolved, inside a prefix of `permissions.read`. Symlinks are
followed (most of `/sys` is symlinks); a plugin cannot create any.

### `beacle.list(dir)` → `{ name, … }` | `nil, err`

The names in a directory, same rule as `read`.

### `beacle.exec(program, args?)` → `stdout, exit_code` | `nil, err`

Runs `program` with the list of string `args`. `program` must be exactly an
entry of `permissions.exec`; a bare name is looked up in `PATH`. There is no
shell — no pipes, globs or variables — and no stdin. Standard output is
returned (up to 1 MiB, the rest dropped), standard error is discarded. A
program that runs and exits non-zero returns its output and code; one that
cannot start, or runs past 5 s, returns `nil, err`.

### `beacle.metric(name, value)`

Records the latest reading of metric `name`, which must be declared in the
manifest. It is sent with the agent's next report.

## backend.lua

### `beacle.servers()` → `{ Server, … }`

Every server in the panel, in no fixed order. A `Server` is:

| Field | |
|---|---|
| `id` | Stable id; what the other functions take. |
| `name` | Display name. |
| `status` | `online`, `high_load`, `offline`, `agent_down`, `restarting`, `powered_off`, `pending` |
| `online` | `true` while its agent is connected. |

### `beacle.value(server_id, metric)` → `number` | `nil`

The latest reading of `metric` on that server: a bare name for this plugin's
own (`"cpu_temp"`), `"plugin.metric"` for any plugin's. `nil` when the
server never reported it, or is unknown.

### `beacle.call(server_id, action, args?)` → `result` | `nil, err`

Runs this plugin's `beacle.on(action)` handler in `agent.lua` on that
server and waits for it (at most 10 s). Fails with `err` when the server is
offline, the plugin is not running there, or the handler raised.

### `beacle.slot(name, opts, fn)`

Registers `fn` to fill slot `name`. See [Slots](#slots).

### `beacle.text(key, text)`

Replaces the panel text `key` in every language. See [Text keys](#text-keys).

### `beacle.hide(id)`

Hides a part of the panel. See [Hide ids](#hide-ids).

## Slots

| Slot | Place | `fn` receives | `fn` returns | `opts` |
|---|---|---|---|---|
| `nav.tab` | A page in the sidebar, under the main entries | — | list of blocks | `id` (required, unique in the plugin), `title`, `icon` |
| `server.section` | A card on every server's page, above History | `Server` | list of blocks, or `nil` | `title` |
| `servers.column` | Beside each server in the Servers list, before its CPU % | `Server` | one block (keep it small: a `stat` with `label = ""`), or `nil` | `title` (its tooltip) |
| `overview.card` | A card on the Overview, below *Needs attention* | — | list of blocks | `title` |

A plugin can register a slot more than once (two cards, two tabs). Slots of
different plugins appear in order of plugin id.

`fn` has 500 ms. An error or a timeout shows in place of the blocks. The
panel calls it when the screen opens, after any button or input in the slot,
when plugins change, and every 15 s; blocks bound to a `metric` update with
live data in between.

## Blocks

Every block is a table with a `type`; the `ui.*` constructors fill it in.
Unknown fields are ignored and unknown types are skipped.

Fields shared by `stat`, `bar` and `chart`:

- `metric` — a metric name (bare = this plugin's own). The value is read on
  `server`.
- `server` — a server id. Defaults to the server the slot is drawn for
  (`server.section`, `servers.column`); in `nav.tab` and `overview.card`
  there is none, so name it.
- `value` — a fixed number instead of a metric (`stat`, `bar`).

### `ui.label(text)` / `ui.label{ text, tone }`

A line of text. `tone`: `"ok"` (green), `"warn"`, `"err"`, `"dim"`.

### `ui.stat{ metric | value, label, unit, tone }`

A number under a small label. `label` and `unit` default to the metric's in
the manifest; `label = ""` drops the label and shrinks the number (use this
in `servers.column`). Without `tone`, a metric's value is coloured by its
`warn`/`crit` levels. Shown with one decimal unless whole; `—` without a
value.

### `ui.bar{ metric | value, label, detail }`

A horizontal bar for a 0–100 value, coloured at 75 and 90 like disk bars.
`detail` is a note at its right.

### `ui.chart{ metric, server, hours, title, unit }`

The recorded history of a metric on one server, `hours` back (default 24),
pannable and zoomable like the server's History charts. `title` and `unit`
default to the metric's label and unit. History is recorded once per report
and kept as long as the server's other history.

### `ui.table{ columns, rows }`

`columns` is a list of header strings (optional); `rows` a list of lists of
values. Values are shown as text.

### `ui.button{ label, action, args }`

Runs `beacle.on(action)` with `args` (a table; `server` is added on a
server's page). The slot redraws afterwards.

### `ui.input{ action, label, hint, value }`

A text field with an initial `value`. Enter (or its ↵ button) runs
`beacle.on(action)` with `{ value = text }`, plus `server`.

### `ui.row{ block, … }`

Blocks side by side, each taking an equal share of the width.

### `ui.column{ block, … }`

Blocks one under another (a list of blocks returned from a slot already is
one).

## Hide ids

| Id | Hides |
|---|---|
| `navOverview`, `navMap`, `navServers`, `navDocker`, `navServices`, `navProxy`, `navAlerts` | That sidebar entry |
| `navSsh`, `navFiles` | That tool in the sidebar's lower group |
| `overview.kpis` | The row of numbers at the top of the Overview |
| `overview.attention` | *Needs attention* |
| `overview.infra` | *Infrastructure* (the server cards) |
| `overview.activity` | *Recent activity* and the fleet charts |
| `server.updates` | The pending-updates banner on a server's page |
| `server.summary` | The CPU / RAM / uptime tiles |
| `server.cores` | Per-core CPU |
| `server.details` | Disks, network and system info |
| `server.history` | History charts |

`navSettings` cannot be hidden. A hidden screen can still be reached from
Ctrl+K.

## Icons

`nav.tab` takes one of these names in `opts.icon`; anything else shows a
puzzle piece.

`thermostat`, `memory`, `speed`, `storage`, `bolt`, `chart`, `heart`,
`cloud`, `power`, `network`, `shield`, `list`

## Text keys

`beacle.text` takes a key from
[`app/lib/l10n/strings_en.dart`](../../app/lib/l10n/strings_en.dart) — the
left-hand side of each line, e.g. `navAlerts` (sidebar "Alerts") or
`ovTagline`. The new text is shown in every language. Texts with
placeholders such as `{n}` keep them only if you write them in.

## manifest.json

```json
{
  "id": "temps",
  "name": "Temperatures",
  "version": "1.0.0",
  "permissions": {
    "read": ["/sys/class/thermal"],
    "exec": ["nvidia-smi"],
    "http": ["127.0.0.1"]
  },
  "metrics": {
    "cpu_temp": { "label": "CPU", "unit": "°C", "warn": 80, "crit": 90 }
  }
}
```

| Field | Rule |
|---|---|
| `id` | `^[a-z0-9_-]{1,32}$` |
| `name`, `version` | non-empty |
| `permissions.read[]` | absolute paths (`/…`) |
| `permissions.exec[]` | a program name or path, no spaces |
| `permissions.http[]` | a bare host name: no scheme, port or path |
| `metrics.<name>` | `^[a-z0-9_]{1,32}$` |
| `metrics.*.warn`, `crit` | numbers; `0` or missing = no alert at that level; `crit` not below `warn` |

Outside the plugin, a metric is named `<id>.<name>` (`temps.cpu_temp`) —
in snapshots, history, alerts and per-server levels.

**Alerts.** A level counts once the value has stayed at or above it for
10 s. `crit` wins over `warn`. The alert resolves when the value is under
95 % of the lowest level, or the metric is no longer reported. A server's
edit dialog can replace `warn` for that server.

## Lua environment

Lua 5.1 (gopher-lua). Available: `assert`, `error`, `getmetatable`,
`setmetatable`, `ipairs`, `pairs`, `next`, `pcall`, `xpcall`, `rawequal`,
`rawget`, `rawset`, `select`, `tonumber`, `tostring`, `type`, `unpack`,
`getfenv`, `setfenv`, `print`, and the `string`, `table` and `math`
libraries. Not available: `os`, `io`, `debug`, `package`, `coroutine`,
`require`, `module`, `load`, `loadstring`, `loadfile`, `dofile`,
`collectgarbage`.

Each plugin has its own Lua state on each side; plugins cannot see each
other's variables. Reading another plugin's metrics goes through
`beacle.value`.

| Limit | |
|---|---|
| A task, handler or the file's top level | 10 s |
| A slot function | 500 ms |
| `beacle.every` interval | ≥ 5 s |
| `read`, `exec` output, `http` body | 1 MiB |
| `exec` | 5 s |
| `http` | 10 s |
| `store` | 64 KiB of JSON per side |
| Each package file | 1 MiB; an uploaded .zip up to 8 MiB |

## Panel HTTP API

What the app uses, on the panel's loopback address (`127.0.0.1:9930`). Of
use for scripting an install.

| Method | Path | Body | |
|---|---|---|---|
| `GET` | `/api/plugins` | — | Plugins with state per server, plus `texts`, `hide`, `tabs` |
| `POST` | `/api/plugins/inspect` | `{ "path": "…" }` or `{ "zip": "<base64>" }` | Validate and describe a package without installing |
| `POST` | `/api/plugins` | same | Install or update; a folder `path` installs it linked |
| `PATCH` | `/api/plugins/{id}` | `{ "enabled": bool, "disabled_on": [server ids] }` | Either field may be left out |
| `DELETE` | `/api/plugins/{id}` | — | Remove, everywhere |
| `GET` | `/api/plugins/{id}/log` | — | The backend part's log lines |
| `GET` | `/api/plugins/ui?slot=…&server=…&tab=…` | — | Run one slot's functions |
| `POST` | `/api/plugins/{id}/action` | `{ "action": "…", "args": { … } }` | Run a `beacle.on` handler |

The backend pushes agent parts to agents itself (`POST /api/plugins/sync`
and `/api/plugins/call` on the agent, over its WebSocket); see
[PROTOCOL.md](../../shared/PROTOCOL.md#plugins).
