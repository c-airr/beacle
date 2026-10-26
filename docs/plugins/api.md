# Plugin API reference

Everything a Beacle plugin can call, return and name. For a walk-through,
see [Writing Beacle plugins](README.md). The same API is described for
editors in [`plugins/beacle.d.lua`](../../plugins/beacle.d.lua).

Plugins need Beacle 2.2.0 or later — the panel and, for `agent.lua`, the
agent on each server. What is marked *2.2.5* needs 2.2.5 on that side; the
panel updates an older agent itself when it pushes a plugin to it (see
[Agents](#agents)).

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
- [Agents](#agents)
- [Panel HTTP API](#panel-http-api)

## Where each function exists

| | agent.lua | backend.lua |
|---|:-:|:-:|
| `beacle.log`, `print` | ✓ | ✓ |
| `beacle.every` | ✓ | ✓ |
| `beacle.on` | ✓ | ✓ |
| `beacle.now`, `beacle.date` *2.2.5* | ✓ | ✓ |
| `beacle.config` *2.2.5* | ✓ (no secrets) | ✓ |
| `beacle.json.encode/decode` | ✓ | ✓ |
| `beacle.base64.encode/decode` *2.2.6* | ✓ | ✓ |
| `beacle.store.get/set` | ✓ | ✓ |
| `beacle.http.get/post` | ✓ | ✓ |
| `beacle.http.request` *2.2.5* | ✓ | ✓ |
| `beacle.metric` | ✓ | ✓ *2.2.5* (this computer) |
| `beacle.read`, `beacle.list` | ✓ | |
| `beacle.write` *2.2.5* | ✓ | |
| `beacle.exec` | ✓ | |
| `beacle.servers`, `beacle.value`, `beacle.call` | | ✓ |
| `beacle.api` *2.2.5* | | ✓ |
| `beacle.alert`, `beacle.resolve` *2.2.5* | | ✓ |
| `beacle.configure` *2.2.6* | | ✓ |
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
- `event:<name>` handlers in **backend.lua** are called by the panel itself
  (*2.2.5*):

  | Name | `args` |
  |---|---|
  | `event:alert` | An alert raised or resolved, any kind: `{ id, type, severity, message, key, server, server_name, resolved }`. `server` is `"local"` for this computer. |

  Each runs on its own, after the alert is stored; a handler that raises an
  alert itself sees that one too, so check `args.type`/`args.key` before
  reacting.

Arguments and return values are plain data: `nil`, booleans, numbers,
strings, and tables of those (lists or string-keyed maps). Functions are
dropped.

### `beacle.now()` → `number` *2.2.5*

The time in seconds since 1970 (UTC), with milliseconds.

### `beacle.date(t?, layout?)` → `string` *2.2.5*

`t` (default now) in this computer's time zone, as `layout` in Go's
notation: `"2006-01-02 15:04"`, `"15:04:05"`, `"Mon 2 Jan"`. The default is
`"2006-01-02 15:04:05"`. On an agent that is the server's time zone.

### `beacle.config(key?)` → `value` | `{ key = value, … }` *2.2.5*

What the user set in the plugin's settings (Settings → Plugins → the
plugin's settings button, the sliders). See `config` in [manifest.json](#manifestjson). A field not
set gives its `default`, or `nil`. Saving the settings restarts the
plugin, so read them at the top of the file if you like. On an agent,
`secret` fields are never there.

### `beacle.json.encode(value)` → `string` | `nil, err`

### `beacle.json.decode(text)` → `value` | `nil, err`

Lists become JSON arrays, other tables objects. An empty table encodes as
`[]`. Numbers decode as Lua numbers, `null` as `nil`.

### `beacle.base64.encode(text)` → `string` / `beacle.base64.decode(text)` → `string` | `nil, err` *2.2.6*

Standard base64, with padding on the way out and optional on the way in —
what an `Authorization: Basic` header wants:
`"Basic " .. beacle.base64.encode(user .. ":" .. password)`.

### `beacle.store.get(key)` → `value`

### `beacle.store.set(key, value)`

Keeps plain data across restarts. `nil` deletes the key. The whole store
holds at most 64 KiB of JSON; a `set` past that raises an error and changes
nothing. The backend and each agent have a store of their own. Removing the
plugin deletes its stores.

### `beacle.http.get(url)` → `body, status` | `nil, err`

### `beacle.http.post(url, body?, content_type?)` → `body, status` | `nil, err`

`url` must be `http://` or `https://` with a host listed in
`permissions.http` (`"*"` there is any host), or the host of a `url` field
the user filled in in the plugin's settings; redirects to other hosts are
refused. `content_type`
defaults to `application/json`. A response is a `body` (up to 1 MiB) and
its HTTP `status` — a 404 is an answer, not an error. 10 s timeout, cut
short so a host that does not answer returns `nil, err` while the task,
handler or slot it runs in still has time to handle it.

### `beacle.http.request{ method, url, headers, body, timeout }` → `{ status, headers, body }` | `nil, err` *2.2.5*

Any method (`GET` by default, `PUT`, `PATCH`, `DELETE`, `HEAD`…), with
request `headers` (`{ Authorization = "Bearer " .. beacle.config("token") }`).
A table `body` is sent as JSON with `Content-Type: application/json`
unless you set one. `timeout` is in seconds (default 10, cut like
`get`'s). The answer's `headers` have lower-case names. Same hosts as `get`.

## agent.lua

### `beacle.read(path)` → `string` | `nil, err`

Reads a whole file, up to 1 MiB. `path` must be absolute and, once `.` and
`..` are resolved, inside a prefix of `permissions.read`. Symlinks are
followed (most of `/sys` is symlinks); a plugin cannot create any.

### `beacle.list(dir)` → `{ name, … }` | `nil, err`

The names in a directory, same rule as `read`.

### `beacle.write(path, data, { append = true }?)` → `true` | `nil, err` *2.2.5*

Creates or replaces a file (mode 0644) under a prefix of
`permissions.write`, same path rule as `read`; `append` adds to its end
instead. A replace goes through a temporary file, so nobody reads half of
it. Writing through a symlink is refused. At most 1 MiB per call.

### `beacle.exec(program, args?, opts?)` → `stdout, exit_code, stderr` | `nil, err`

Runs `program` with the list of string `args`. `program` must be exactly an
entry of `permissions.exec`; a bare name is looked up in `PATH`. There is no
shell — no pipes, globs or variables. Standard output and (*2.2.5*)
standard error are returned, up to 1 MiB each, the rest dropped. A program
that runs and exits non-zero returns its output and code; one that cannot
start, or runs past its time, returns `nil, err`.

`opts` (*2.2.5*):

| Field | |
|---|---|
| `stdin` | Text fed to the program's standard input. |
| `env` | `{ NAME = "value" }` added to the agent's environment. |
| `dir` | Working directory. |
| `timeout` | Seconds; default 5. Cut to what is left of the task or handler, so a long job also needs a longer `timeout` in the manifest. |

### `beacle.metric(name, value)`

Records the latest reading of metric `name`, which must be declared in the
manifest (by name, or by a wildcard: see `metrics`). It is sent with the
agent's next report. `value = nil` drops the metric (*2.2.5*) — a disk that
was unplugged stops showing its last reading and its alerts resolve.

## backend.lua

### `beacle.servers()` → `{ Server, … }`

Every server in the panel, in no fixed order. A `Server` is:

| Field | |
|---|---|
| `id` | Stable id; what the other functions take. |
| `name` | Display name. |
| `status` | `online`, `high_load`, `offline`, `agent_down`, `restarting`, `powered_off`, `pending` |
| `online` | `true` while its agent is connected. |
| `host` | The address the panel reaches it on (Tailscale IP, or the public IP on WireGuard). *2.2.5* |
| `public_ip` | Its public address, as the agent sees it. *2.2.5* |
| `tags` | `{ "prod", … }`, as set in its edit dialog. *2.2.5* |
| `location` | City, as on the map. *2.2.5* |
| `agent_version` | *2.2.5* |

### `beacle.value(server_id, metric)` → `number` | `nil`

The latest reading of `metric` on that server: a bare name for this plugin's
own (`"cpu_temp"`), `"plugin.metric"` for any plugin's. `nil` when the
server never reported it, or is unknown.

*2.2.5:* `"system.cpu"`, `system.mem`, `system.disk` (fullest disk),
`system.load1`, `system.rx`, `system.tx` (bytes/s) are the panel's own
readings. Server `"local"` is this computer: metrics of backend parts.

### `beacle.metric(name, value)` *2.2.5*

As in agent.lua, for this computer: the backend part's readings are
recorded once a minute under the server id `"local"` — `ui.chart{ metric,
server = "local" }` draws them, `beacle.value("local", name)` reads them —
and alert by the manifest's `warn`/`crit` like a server's. For an outside
device (a board on the LAN, a web page's response time) that is the place
for its history.

### `beacle.call(server_id, action, args?)` → `result` | `nil, err`

Runs this plugin's `beacle.on(action)` handler in `agent.lua` on that
server and waits for it (at most 10 s, or the manifest's `timeout`). Fails
with `err` when the server is offline, the plugin is not running there, or
the handler raised.

### `beacle.api(method, path, body?)` → `answer, status` | `nil, err` *2.2.5*

Calls the panel's own API, in process — the one the app uses, so a plugin
can do whatever a click in the panel does. `answer` is the decoded JSON (or
the raw text), `status` the HTTP status: a 4xx is an answer, check it.
`body` is a string, or a table sent as JSON. `path` may carry a query
(`"/api/vps/x/history?hours=6"`).

Only routes matching `permissions.api` are allowed, `"METHOD /path"` with
`*` for one path segment and `*` for any method:

```json
"api": [
  "GET /api/vps",
  "GET /api/vps/*/agent/docker/containers",
  "POST /api/vps/*/agent/docker/containers/*/*"
]
```

A path must be in its plain form (no `..`, `//`, `%`). Never reachable,
whatever the manifest says: `/api/plugins…` and an agent's plugin routes
(a plugin cannot install or change plugins), `/api/shutdown`, and the
terminals. Everything on a server goes through
`/api/vps/{id}/agent/<agent route>` — the routes are those of
[agent/api.go](../../agent/api.go) without their `/api`: docker, systemd,
files, firewall, cron, processes, updates, reboot.

Useful ones:

| | |
|---|---|
| `GET /api/vps` | Servers with their full record |
| `GET /api/vps/{id}` | One server with its latest snapshot (all metrics, containers, services) |
| `GET /api/vps/{id}/history?hours=24` | Recorded samples |
| `GET /api/alerts` · `POST /api/alerts/{id}/resolve` | Alerts |
| `GET /api/vps/{id}/agent/docker/containers` · `POST …/containers/{cid}/{start\|stop\|restart}` | Docker |
| `GET /api/vps/{id}/agent/services/systemd` · `POST …/systemd/{unit}/{start\|stop\|restart}` | systemd |
| `GET /api/vps/{id}/agent/fs/read?path=…` · `PUT …/fs/write` | Files |
| `POST /api/webhooks/test` | Send a test notification |

### `beacle.configure{ key = value, … }` → `true` | `nil, err` *2.2.6*

Saves the plugin's settings from its own setup screen (the `plugin.setup`
slot), checked against the manifest's `config` like the settings form's:
a number must be a number, a `select` one of its options, a `url` start
with `http://` or `https://`. Keys left out keep their value, secrets too.
The plugin restarts with the new settings once the handler that called it
has returned — anything kept only in Lua variables starts over.

### `beacle.alert{ key, message, severity?, server? }` *2.2.5*

Raises an alert like the panel's own: in Alerts, under *Needs attention*,
and through the notification webhooks. `severity` is `"warning"` (default)
or `"critical"`; `server` a server id, or none for this computer. Raising a
`key` that is still open does nothing, so it can be called on every check.

### `beacle.resolve(key, server?)` *2.2.5*

Resolves that alert. Turning the plugin off or removing it resolves all of
its alerts.

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
| `server.actions` *2.2.5* | In a server's header, before its buttons | `Server` | list of small blocks (`button`, `link`, `toggle`), or `nil` | — |
| `settings.section` *2.2.5* | Inside the plugin's own card in Settings → Plugins | — | list of blocks | — |
| `plugin.setup` *2.2.6* | The plugin's own setup screen: **Configure** on its card in Settings → Plugins, opened by itself right after an install from the Marketplace | — | list of blocks | — |

`plugin.setup` is for plugins meant for anyone, where the settings are
choices rather than a few fields: where your service is, a key, which of
the things found there to watch. Build it from `ui.input`, `ui.select`,
`ui.checklist`, `ui.toggle` and buttons; keep what is typed in a Lua table
and save it with `beacle.configure` (above).
A plugin without it keeps the form its manifest's `config` describes.

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

### `ui.button{ label, action, args, confirm }`

Runs `beacle.on(action)` with `args` (a table; `server` is added on a
server's page). The slot redraws afterwards. With `confirm = "Restart
nginx?"` (*2.2.5*) the panel asks that first.

### `ui.link{ text, url }` *2.2.5*

Opens `url` (`http`/`https` only) in the browser.

### `ui.toggle{ label, value, action, args }` *2.2.5*

A switch, on when `value` is `true`. Flipping it runs `beacle.on(action)`
with `args` plus `value` (the new state) and `server`; draw it from your
state so it shows what took effect.

### `ui.select{ label, value, options, action, args }` *2.2.5*

A drop-down of the strings in `options`. Picking one runs
`beacle.on(action)` with `args` plus `value` and `server`.

### `ui.code{ text, height, tail }` *2.2.5*

Monospace, selectable text in a scrolling box `height` px high (default
240) — command output, a log. `tail = true` keeps the end in view.

### `ui.input{ action, args, label, hint, value, secret }`

A text field with an initial `value`. Enter, its ↵ button or leaving the
field (*2.2.6*) runs `beacle.on(action)` with `args` (*2.2.6*) plus
`value = text` and `server`. With `secret = true` (*2.2.6*) what is typed is
masked and `value` is never shown: say in `hint` whether one is saved.

### `ui.checklist{ label, options, values, action, args }` *2.2.6*

A tick box for each string in `options`, ticked when it is in `values`.
Ticking or unticking one runs `beacle.on(action)` with `args` plus `values`
(the ticked options, in their order) and `server`.

### `ui.row{ block, … }`

Blocks side by side, each taking an equal share of the width.

### `ui.column{ block, … }`

Blocks one under another (a list of blocks returned from a slot already is
one).

### `ui.card{ title, block, … }`

Blocks one under another in a framed card, like the panel's own, with an
optional `title` on top. Put several in a `ui.row` for tiles side by side.
New in 2.2.5. To run on older panels too, start backend.lua with
`ui.card = ui.card or ui.column`: there the tiles are drawn without frame or
title.

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
puzzle piece. (The app cannot look icons up by name at run time, so the
list is fixed.)

`thermostat`, `memory`, `speed`, `storage`, `bolt`, `chart`, `heart`,
`cloud`, `power`, `network`, `shield`, `list`

*2.2.5:* `home`, `dashboard`, `settings`, `terminal`, `code`, `bug`,
`build`, `cpu`, `gpu`, `disk`, `folder`, `file`, `database`, `server`,
`docker`, `wifi`, `router`, `globe`, `link`, `lock`, `key`, `user`,
`users`, `mail`, `chat`, `bell`, `warning`, `error`, `check`, `info`,
`clock`, `calendar`, `timer`, `history`, `sync`, `download`, `upload`,
`search`, `star`, `flag`, `battery`, `sun`, `moon`, `water`, `fan`,
`camera`, `music`, `game`, `money`, `cart`, `robot`, `puzzle`

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
  },
  "config": [
    { "key": "device", "label": "Device status URL", "type": "url", "help": "e.g. http://192.168.1.50/status" },
    { "key": "every", "label": "Check every (s)", "type": "number", "default": 10 }
  ]
}
```

| Field | Rule |
|---|---|
| `id` | `^[a-z0-9_-]{1,32}$` |
| `name`, `version` | non-empty |
| `permissions.read[]` | absolute paths (`/…`) |
| `permissions.exec[]` | a program name or path, no spaces |
| `permissions.http[]` | a bare host name: no scheme, port or path; `"*"` = any host |
| `permissions.write[]` *2.2.5* | absolute paths (`/…`), for `beacle.write` |
| `permissions.api[]` *2.2.5* | `"METHOD /api/…"`, see [`beacle.api`](#beacleapimethod-path-body--answer-status--nil-err-225) |
| `metrics.<name>` | `^[a-z0-9_]{1,32}$`; ending in `*` (*2.2.5*, `"disk_*"`) it declares every metric that starts so — names made up at run time, of `a-z 0-9 _ -`, at most 256 per plugin |
| `metrics.*.warn`, `crit` | numbers; `0` or missing = no alert at that level; `crit` not below `warn` |
| `config[]` *2.2.5* | the settings form, in order: `key` (`^[a-z0-9_]{1,32}$`, once), `label`, `type`, `default`, `help`, `options` |
| `config[].type` | `text` (default), `secret` (hidden, stays on this computer), `number`, `bool`, `url` (its host may be called, see `http`), `select` (one of `options`) |
| `timeout` *2.2.5* | seconds a task or handler may run, 1–300 (default 10). While one runs, the plugin's other tasks and its slots wait. |

Outside the plugin, a metric is named `<id>.<name>` (`temps.cpu_temp`) —
in snapshots, history, alerts and per-server levels.

**Alerts.** A level counts once the value has stayed at or above it for
10 s. `crit` wins over `warn`. The alert resolves when the value is under
95 % of the lowest level, or the metric is no longer reported. A server's
edit dialog can replace `warn` for that server.

**What the user is told.** Before installing, and on the plugin's card,
the panel turns `permissions` and `config` into sentences — "Can send data
to any address on the internet", "Runs bash — which can run any command",
"Reads files under /etc — they can hold passwords…" — with the risky ones
in red, and offers the code to read. Ask for the least you need: `"*"` in
`http`, a shell or interpreter in `exec`, `write`, a `read` prefix at or
above `/etc`, `/root`, `/home`, `/opt`, `/var`, `/srv` or `/boot`, and any
`api` entry that is not `GET` are all shown as dangerous.

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
| A task, handler or the file's top level | 10 s, or the manifest's `timeout` |
| A slot function | 500 ms |
| `beacle.every` interval | ≥ 5 s |
| `read`, `exec` output, `http` body | 1 MiB |
| `exec` | 5 s, or its `timeout` |
| `http` | 10 s |
| `store` | 64 KiB of JSON per side |
| Each package file | 1 MiB; an uploaded .zip up to 8 MiB |

## Agents

The backend sends each server the agent parts it should run when a plugin
is installed, changed, turned on or off, when its settings are saved and
whenever the agent connects. Nothing is installed by hand on a server, and
the agent binary stays as it is.

*2.2.5:* an agent older than 2.2.5 on a server that gets a plugin is
updated by the panel, from the latest GitHub release, at most once an hour
and only when that release is new enough. A server where the agent should
stay as it is: turn the plugin off there (click it in the plugin's card).

## Panel HTTP API

What the app uses, on the panel's loopback address (`127.0.0.1:9930`). Of
use for scripting an install.

| Method | Path | Body | |
|---|---|---|---|
| `GET` | `/api/plugins` | — | Plugins with state per server, plus `texts`, `hide`, `tabs` |
| `POST` | `/api/plugins/inspect` | `{ "path": "…" }`, `{ "zip": "<base64>" }` or `{ "catalog": "<id>", "ref": "…" }` *2.2.6* | Validate and describe a package without installing |
| `POST` | `/api/plugins` | same | Install or update; a folder `path` installs it linked. Answers `{ id, version, setup }`, `setup` when it has a `plugin.setup` screen |
| `PATCH` | `/api/plugins/{id}` | `{ "enabled": bool, "disabled_on": [server ids], "config": { … } }` | Any field may be left out; `config` replaces the settings (a `secret` left out keeps its value) |
| `DELETE` | `/api/plugins/{id}` | — | Remove, everywhere |
| `GET` | `/api/plugins/{id}/log` | — | The backend part's log lines |
| `GET` | `/api/plugins/ui?slot=…&server=…&tab=…` | — | Run one slot's functions (`plugin.setup`: `tab` is the plugin id) |
| `GET` | `/api/plugins/catalog?ref=…&version=…` *2.2.6* | — | The Marketplace: `plugins/index.json` of the Beacle repository at `ref` (the app's commit or version; `main` when that has none), with what is installed and what has an update |
| `POST` | `/api/plugins/{id}/action` | `{ "action": "…", "args": { … } }` | Run a `beacle.on` handler |

The backend pushes agent parts to agents itself (`POST /api/plugins/sync`
and `/api/plugins/call` on the agent, over its WebSocket); see
[PROTOCOL.md](../../shared/PROTOCOL.md#plugins).
