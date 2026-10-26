# Writing Beacle plugins

A plugin adds something to Beacle without changing Beacle itself: a reading
from every server, a chart, an alert, a tab, a button that does something on
a server. It is written in Lua, installed from **Settings → Plugins** with one
click, and from there the panel sends each part where it belongs.

This page walks through writing one. Every function, block and id is listed
in the [API reference](api.md). The plugins in [`plugins/demo/`](../../plugins/demo) are
complete, working examples — reading one next to this page is the quickest
way in:

- [`uptime`](../../plugins/demo/uptime) — backend only: checks web pages from the
  panel. The pages come from its settings form (`config`), response times
  are a wildcard metric of this computer with a chart per page, a page that
  stays down raises an alert with notifications, and a switch pauses it.
- [`temp`](../../plugins/demo/temp) — one tab of tiles: this computer's
  temperatures from LibreHardwareMonitor and a device on the LAN that
  serves JSON (both set in its settings, with a day of history), and every
  server's CPU and GPU from its agent part, with alerts.
- [`neofetch`](../../plugins/demo/neofetch) — runs a program on every server and
  can post its output to an address on the LAN: the example of what the
  install dialog shows in red.

- [What a plugin is](#what-a-plugin-is)
- [Your first plugin in five minutes](#your-first-plugin-in-five-minutes)
- [The package](#the-package)
- [manifest.json](#manifestjson)
- [agent.lua: the server side](#agentlua-the-server-side)
- [backend.lua: the panel side](#backendlua-the-panel-side)
- [Blocks: building the screen](#blocks-building-the-screen)
- [Alerts](#alerts)
- [Buttons and talking to servers](#buttons-and-talking-to-servers)
- [Changing the panel: texts and hiding](#changing-the-panel-texts-and-hiding)
- [Developing: linked folders, logs, errors](#developing-linked-folders-logs-errors)
- [Editor support](#editor-support)
- [Limits and the sandbox](#limits-and-the-sandbox)
- [Recipes](#recipes)
- [Troubleshooting](#troubleshooting)

## What a plugin is

Beacle has three parts, and a plugin can have code in two of them:

```
 your servers                     your computer
┌──────────────┐   WebSocket    ┌───────────────┐   loopback   ┌──────────┐
│ agent        │ ◀────────────▶ │ backend       │ ◀──────────▶ │ app      │
│  agent.lua   │                │  backend.lua  │              │ (draws)  │
└──────────────┘                └───────────────┘              └──────────┘
```

- **`agent.lua`** runs inside the agent on **every server**. It reads files,
  runs programs and reports numbers (metrics). It is the only place that can
  see the server itself.
- **`backend.lua`** runs once, in the **backend on your computer**. It decides
  what the panel shows: it puts blocks (numbers, bars, charts, tables,
  buttons) into places in the panel, and it can ask the agent part on a
  server to do something.
- The **app** runs no plugin code. It draws the blocks `backend.lua` returns,
  in Beacle's own style, in light and dark theme.

A plugin can have just one of the two files. Metrics without a screen of
their own need only `agent.lua` — they still get history, alerts and a place
in a server's edit dialog. A tab that only shows what the panel already knows
needs only `backend.lua`.

Plugins run **Lua 5.1** (the [gopher-lua](https://github.com/yuin/gopher-lua)
implementation, built into Beacle — nothing to install anywhere).

## Your first plugin in five minutes

Report how many users are logged in on each server, and show it.

1. Make a folder, say `~/beacle-plugins/users`, with three files:

   **manifest.json**
   ```json
   {
     "id": "users",
     "name": "Logged-in users",
     "version": "1.0.0",
     "permissions": { "exec": ["who"] },
     "metrics": {
       "count": { "label": "Users", "warn": 5 }
     }
   }
   ```

   **agent.lua**
   ```lua
   beacle.every(30, function()
     local out = beacle.exec("who", {})
     local n = 0
     for _ in (out or ""):gmatch("[^\n]+") do n = n + 1 end
     beacle.metric("count", n)
   end)
   ```

   **backend.lua**
   ```lua
   beacle.slot("server.section", { title = "Users" }, function(server)
     return { ui.stat{ metric = "count" }, ui.chart{ metric = "count", hours = 24 } }
   end)
   ```

2. In Beacle: **Settings → Plugins → Link a folder**, paste the folder's
   path, confirm. (Linking keeps it reloading while you work; to give it to
   someone, zip the folder and they use **Install .zip**.)
3. Open a server on **Servers**: a *Users* card shows the count and, after a
   while, a chart. Five logged-in users raise an alert, which goes out through
   your webhooks like any other.

That is the whole cycle. The rest of this page is detail.

## The package

```
users/
  manifest.json   required
  agent.lua       optional
  backend.lua     optional (but one of the two .lua files must exist)
```

To share a plugin, zip it. The files can be at the root of the zip or inside
one folder (what "Send to → Compressed folder" or `zip -r users.zip users`
makes). Other files in the zip are ignored, and each file may be up to 1 MiB.

Installing a plugin whose `id` is already installed **updates** it and keeps
its settings (on/off, servers it is off on). If the new version asks for
permissions the old one did not have, the install dialog says so.

## manifest.json

```json
{
  "id": "temps",
  "name": "Temperatures",
  "version": "1.0.0",
  "permissions": {
    "read": ["/sys/class/thermal", "/sys/class/hwmon"],
    "exec": ["nvidia-smi"],
    "http": ["api.example.com"]
  },
  "metrics": {
    "cpu_temp": { "label": "CPU", "unit": "°C", "warn": 80, "crit": 90 }
  }
}
```

| Field | |
|---|---|
| `id` | 1–32 characters of `a-z 0-9 _ -`. Names the plugin everywhere, so do not change it between versions. |
| `name` | What people see. |
| `version` | Free text; shown in Settings. |
| `permissions.read` | Absolute path prefixes `beacle.read` and `beacle.list` may open. `"/sys/class/thermal"` covers everything under it. |
| `permissions.exec` | Programs `beacle.exec` may run, by name (`"nvidia-smi"`, looked up in `PATH`) or full path. |
| `permissions.http` | Host names `beacle.http` may call (no scheme, no port). Redirects to other hosts are refused. |
| `metrics` | Every metric `agent.lua` reports. Name: 1–32 of `a-z 0-9 _`. |

A metric's fields, all optional:

| Field | |
|---|---|
| `label` | Shown by `ui.stat`, `ui.chart`, alerts and the edit dialog. |
| `unit` | Appended to the value: `"°C"`, `"%"`, `" req/s"`. |
| `warn` | A warning alert fires at this value or above. |
| `crit` | A critical alert fires at this value or above. |

**Permissions are the contract with the user.** They are shown before
installing, and the sandbox enforces them: a plugin that did not list
`/etc` cannot read `/etc`, one that did not list `curl` cannot run it. Ask
for the least you need.

## agent.lua: the server side

`agent.lua` runs on each server when the plugin is installed and on every
agent start after that. The file's top level runs once; it sets things up and
registers what should happen later:

```lua
-- runs once, at load
local last = nil

-- runs now, then every 10 seconds
beacle.every(10, function()
  local raw = beacle.read("/sys/class/thermal/thermal_zone0/temp")
  if raw then
    last = tonumber(raw) / 1000
    beacle.metric("cpu_temp", last)
  end
end)

-- runs when the backend asks (see "Buttons and talking to servers")
beacle.on("now", function(args)
  return last
end)
```

What `agent.lua` can use:

- `beacle.read(path)`, `beacle.list(dir)` — files under `permissions.read`.
- `beacle.exec(program, args)` — programs in `permissions.exec`.
- `beacle.http.get/post` — hosts in `permissions.http` (for a service on the
  server itself, list `127.0.0.1` or `localhost`).
- `beacle.metric(name, value)` — report a reading.
- `beacle.every`, `beacle.on`, `beacle.log`, `beacle.json`, `beacle.store`.

**Metrics.** `beacle.metric` keeps the latest value; the agent sends it with
its regular report (every few seconds while the panel is open, less often
when it is idle), the panel keeps a history of it for charts, and the alert
levels from the manifest are checked against it. Report a metric only when
you have a real reading — a server without a GPU should report no
`gpu_temp`, not `0`. If the plugin stops (an error, see below), its metrics
disappear instead of going stale.

**The agent runs as root.** That is why the sandbox exists: everything
outside the Lua state goes through the functions above and the permissions
you declared. See [Limits and the sandbox](#limits-and-the-sandbox).

**Plugins keep running without the panel.** The agent stores the plugins it
was given and starts them again after a restart, even while your computer is
off. Readings taken while the panel is away are buffered with the rest of
the agent's history.

A server can refuse plugins altogether with `"disable_plugins": true` in the
agent's `config.json`.

## backend.lua: the panel side

`backend.lua` runs once, in the backend on your computer. It mostly
registers **slots** — functions that return what to draw in one place of the
panel:

```lua
beacle.slot("server.section", { title = "Temperatures" }, function(server)
  return {
    ui.stat{ metric = "cpu_temp" },
    ui.chart{ metric = "cpu_temp", hours = 24 },
  }
end)
```

| Slot | Where | The function gets | Returns |
|---|---|---|---|
| `nav.tab` | A page of its own, in the sidebar | nothing | a list of blocks |
| `server.section` | A card on every server's page (above History) | the server | a list of blocks, or `nil` |
| `servers.column` | Beside each server in the server list | the server | **one** small block, or `nil` |
| `overview.card` | A card on the Overview | nothing | a list of blocks |

`opts` sets the card's `title`. `nav.tab` also needs an `id` (unique within
your plugin) and can name an `icon` — see the [icon list](api.md#icons).
Ctrl+K finds plugin tabs by their title.

A `server` is a table: `{ id, name, status, online }`.

What `backend.lua` can use besides blocks:

- `beacle.servers()` — every server.
- `beacle.value(server_id, metric)` — the latest reading, or `nil`.
- `beacle.call(server_id, action, args)` — run a handler in `agent.lua`.
- `beacle.http.get/post` — hosts in `permissions.http`.
- `beacle.every`, `beacle.on`, `beacle.log`, `beacle.json`, `beacle.store`.
- `beacle.text`, `beacle.hide` — see below.

**Slot functions must be quick.** The panel waits for them, so each call has
500 ms. Never `exec` or `http` inside one: fetch in `beacle.every` and keep
the result in a local variable the slot reads.

```lua
local weather = "…"
beacle.every(600, function()
  local body = beacle.http.get("https://wttr.in/Warsaw?format=3")
  if body then weather = body end
end)
beacle.slot("overview.card", { title = "Weather" }, function()
  return { ui.label(weather) }
end)
```

**When it redraws.** The panel asks for a slot when the screen opens, after
a button or input in it, whenever plugins change, and every 15 seconds.
Blocks that name a `metric` don't wait for that: they follow the live data
as it arrives.

## Blocks: building the screen

Blocks are made with the `ui.*` functions and nest with `ui.row` (side by
side), `ui.column` (one under another) and `ui.card` (one under another, in
a framed tile):

```lua
return {
  ui.label("Readings from the last report."),
  ui.row{
    ui.stat{ metric = "cpu_temp" },
    ui.stat{ metric = "gpu_temp" },
    ui.bar{ label = "Fan", value = fan_percent },
  },
  ui.chart{ metric = "cpu_temp", hours = 24 },
  ui.table{ columns = { "Sensor", "°C" }, rows = { { "core0", "54" }, { "core1", "57" } } },
  ui.button{ label = "Rescan sensors", action = "rescan" },
}
```

| Block | Shows |
|---|---|
| `ui.label(text)` or `ui.label{ text, tone }` | A line of text. `tone`: `"ok"`, `"warn"`, `"err"`, `"dim"`. |
| `ui.stat{ … }` | A number with a label, coloured by the metric's warn/crit levels. |
| `ui.bar{ … }` | A 0–100 bar (CPU-style). |
| `ui.chart{ metric, hours }` | The metric's recorded history on one server. |
| `ui.table{ columns, rows }` | A table. |
| `ui.button{ label, action, args }` | A button that runs `beacle.on(action)`. |
| `ui.input{ action, label, hint }` | A text field; Enter runs `beacle.on(action)`. |
| `ui.row{ … }`, `ui.column{ … }` | Layout. |
| `ui.card{ title, … }` | A framed tile; several in a `ui.row` sit side by side. |

`stat`, `bar` and `chart` take either a fixed `value` or a `metric`. A
`metric` is read on the block's server: on a server's page and in the
server list that is the server being drawn; in a tab or on the Overview,
name it with `server = id`. A bare metric name is one of your plugin's own;
`"otherplugin.metric"` reads another plugin's.

A block type this version of the panel does not know is skipped rather than
breaking the screen. The exact fields of every block are in the
[reference](api.md#blocks).

## Alerts

Give a metric `warn` and/or `crit` in the manifest and Beacle does the rest:

- the value has to stay at or above the level for 10 seconds (sensors spike
  — so do CPUs, and the built-in CPU alert works the same way);
- `warn` raises a warning, `crit` a critical alert; going from one to the
  other raises the new one;
- it resolves once the value drops 5 % below the lowest level (so a reading
  sitting right on the line does not flap);
- a metric that disappears (plugin removed or failing) resolves its alerts;
- alerts go to your webhooks (Discord, Telegram, …) like every other alert,
  and appear in the panel in its language: *CPU at 92.5°C (limit 90°C)*.

A server's **edit dialog** (Servers → *Edit server*, the button above the
list) lists every metric with a level and
lets you set a different `warn` for that server — a Raspberry Pi in a hot
cupboard can warn at 70 while the rest warn at 80.

## Buttons and talking to servers

Buttons and inputs call a handler in `backend.lua`. On a server's page and
in the server list, `args.server` is that server's id:

```lua
-- backend.lua
beacle.slot("server.section", { title = "Cache" }, function(server)
  return { ui.button{ label = "Clear cache", action = "clear" } }
end)

beacle.on("clear", function(args)
  local freed, err = beacle.call(args.server, "clear", {})
  if err then return "Failed: " .. err end
  return "Freed " .. freed .. " MB"     -- a returned string is shown as a toast
end)
```

```lua
-- agent.lua (manifest: "exec": ["sh"] — or better, the exact program)
beacle.on("clear", function(args)
  local out = beacle.exec("varnishadm", { "ban", "req.url ~ ." })
  return 12
end)
```

`beacle.call` waits for the agent's answer (at most 10 s) and returns
whatever its handler returned — a number, a string, a table. Arguments and
results are plain data (they travel as JSON): no functions.

## Changing the panel: texts and hiding

**Texts.** `beacle.text(key, text)` replaces a text of the panel in every
language. The keys are the ones in
[`app/lib/l10n/strings_en.dart`](../../app/lib/l10n/strings_en.dart):

```lua
beacle.text("navAlerts", "Fires")
beacle.text("ovTagline", "The farm at a glance")
```

**Hiding.** `beacle.hide(id)` removes a part of the panel — a sidebar entry,
an Overview section, a part of a server's page:

```lua
beacle.hide("navMap")
beacle.hide("server.cores")
```

The ids are listed in the [reference](api.md#hide-ids). Settings cannot be
hidden: it is where plugins are switched off.

Both apply while the plugin is on and disappear with it.

## Developing: linked folders, logs, errors

**Link, don't zip.** **Settings → Plugins → Link a folder** installs a
plugin straight from a folder and watches it: every save of one of its three
files reloads it — the backend part at once, the agent parts on every
connected server a moment later. The card shows the folder it is linked to.

**Logs.** `beacle.log(...)` (and `print`) write to the plugin's log.

- The backend part's log is under the plugin's **Log** button in Settings.
- The agent part logs to the agent's own log on the server
  (`journalctl -u beacle-agent`).

**Errors.** A plugin never takes Beacle down with it:

- A syntax error refuses the install with the line number.
- An error while `backend.lua` loads shows on the plugin's card in
  Settings; an error in a slot shows in place of that slot's blocks.
- An error inside `beacle.every` is logged and the next run tries again;
  **five failures in a row stop the plugin** on that side.
- In Settings each server shows the plugin's state there: *running*,
  *error* (hover for why), *waiting* (not reported yet, or the server is
  offline), *off*. An agent older than 2.2.0 shows as an error: *agent too
  old*. Clicking a server switches the plugin off there, and back on.

To restart a stopped plugin, switch it off and on. In a linked folder,
saving restarts the backend part; the agent parts restart when
`agent.lua` or `manifest.json` actually changes.

## Editor support

[`plugins/beacle.d.lua`](../../plugins/beacle.d.lua) describes the whole API
for the Lua language server, which gives completion, signatures and warnings
in VS Code (the *Lua* extension by sumneko) and other editors. Put a
`.luarc.json` in your plugin's folder:

```json
{
  "runtime.version": "Lua 5.1",
  "workspace.library": ["C:/path/to/beacle/plugins/beacle.d.lua"],
  "diagnostics.globals": ["beacle", "ui"]
}
```

## Limits and the sandbox

| | |
|---|---|
| Language | Lua 5.1 with `string`, `table`, `math` and the base functions |
| Not available | `os`, `io`, `debug`, `package`, `require`, `load`, `loadstring`, `dofile`, `loadfile`, `coroutine` |
| One call into a plugin | 10 s (a task, a handler, the file's top level) |
| One slot function | 500 ms |
| `beacle.every` | at least every 5 s |
| `beacle.read`, `exec` output, `http` body | 1 MiB |
| `beacle.exec` | 5 s, no shell, no stdin |
| `beacle.http` | 10 s |
| `beacle.store` | 64 KiB per plugin, per side (backend and each agent have their own) |
| Package files | 1 MiB each |

A call that runs past its time — an endless loop included — is stopped and
counts as an error; the plugin stays usable.

What the sandbox does **not** do: limit memory. A plugin that builds a
gigabyte string can still hurt the agent. Install plugins you have read, as
you would a script you run as root.

Everything a plugin can do is reachable only from your own computer: the
panel's API listens on loopback and refuses browsers, and an agent takes
plugins only from its own panel.

## Recipes

**A value from a command, parsed.**
```lua
beacle.every(30, function()
  local out = beacle.exec("df", { "--output=pcent", "/" })
  local pct = out and tonumber(out:match("(%d+)%%"))
  if pct then beacle.metric("root_full", pct) end
end)
```

**JSON from a local service** (`"http": ["127.0.0.1"]`).
```lua
beacle.every(15, function()
  local body = beacle.http.get("http://127.0.0.1:8080/stats")
  local stats = body and beacle.json.decode(body)
  if stats then beacle.metric("queue", stats.queue_length) end
end)
```

**Remember something across restarts.**
```lua
local runs = beacle.store.get("runs") or 0
beacle.every(60, function()
  runs = runs + 1
  beacle.store.set("runs", runs)
end)
```

**A fleet-wide table in a tab of its own.**
```lua
beacle.slot("nav.tab", { id = "fleet", title = "Fleet", icon = "list" }, function()
  local rows = {}
  for _, s in ipairs(beacle.servers()) do
    rows[#rows + 1] = { s.name, s.online and "up" or "down", beacle.value(s.id, "queue") or "—" }
  end
  return { ui.table{ columns = { "Server", "State", "Queue" }, rows = rows } }
end)
```

**Only some servers.** Return `nil` from a slot for servers it does not
apply to; switch the plugin off on servers in Settings so the agent part
does not run there at all.

## Plugins for everyone: a setup screen and the Marketplace

A plugin you write for your own machines can hard-code what it watches. One
meant for anyone cannot: give it a setup screen. Register the
`plugin.setup` slot, draw the choices with `ui.input`, `ui.select`,
`ui.checklist` and buttons, keep what is typed in a Lua table and save it
with `beacle.configure{ … }` — the plugin restarts with it.
[`plugins/uptime-kuma`](../../plugins/uptime-kuma/backend.lua) is a whole
example: an address and a key, *Connect*, then which monitors to watch.

The Marketplace (Settings → Plugins → *Marketplace*) lists
[`plugins/index.json`](../../plugins/index.json). To add a plugin there,
put its folder under `plugins/` and an entry in the index with its `id`,
`name`, `description`, `version` (both as in its manifest — a test checks),
`path` and `min_beacle`; the panel fetches both at the commit the app was
built from, so it reaches people with the next release.

## Troubleshooting

| Symptom | Why, and what to do |
|---|---|
| Install refused: *manifest: …* | The message names the field. |
| Install refused: *agent.lua line N: …* | A syntax error; fix that line. |
| A server says *agent too old* | Update the agent on it (Servers → Update agent) to 2.2.0 or later. |
| A server says *plugins are disabled on this server* | `disable_plugins` is set in that agent's `config.json`. |
| *permission denied: path not in permissions.read* | Add the path (or a folder above it) to the manifest. Paths are checked as written: `../` is resolved first. |
| *metric "x" is not declared in manifest.json* | Every reported metric has to be in `metrics`. |
| *timed out after 500ms* in a slot | The slot does slow work; move it into `beacle.every`. |
| A value shows `—` | No reading yet, or the server never reported one (no such sensor). |
| The plugin stopped | Five task failures in a row; see the log, fix, switch off and on. |
