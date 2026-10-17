---@meta
-- Type definitions for Beacle plugins, for the Lua language server
-- (VS Code: the "Lua" extension by sumneko). They only describe the API;
-- nothing here runs. The full reference is docs/plugins/api.md.
--
-- Point the language server at this file with a .luarc.json next to your
-- plugin, like the one in this folder:
--   { "runtime.version": "Lua 5.1", "workspace.library": ["path/to/demo/beacle.d.lua"] }

---@class beacle
beacle = {}

-- ---------------------------------------------------------------------------
-- Everywhere (agent.lua and backend.lua)

---Writes a line to the plugin's log (Settings → Plugins → Log for the backend
---part; the agent's journal for the agent part). `print` does the same.
---@param ... any
function beacle.log(...) end

---Runs `fn` now and then every `seconds` (at least 5). Register it at the top
---level of the file. Five failures in a row stop the plugin.
---@param seconds number
---@param fn fun()
function beacle.every(seconds, fn) end

---Registers a handler. In agent.lua it answers beacle.call from the backend;
---in backend.lua it answers buttons and inputs in the panel.
---@param name string
---@param fn fun(args: table): any
function beacle.on(name, fn) end

---Seconds since 1970, with milliseconds. (2.2.5)
---@return number
function beacle.now() end

---Formats a time (default now) with a Go layout, default "2006-01-02 15:04:05".
---(2.2.5)
---@param t? number
---@param layout? string
---@return string
function beacle.date(t, layout) end

---The plugin's settings from Settings → Plugins (manifest "config"); one by
---key, or all. Agents do not get secrets. (2.2.5)
---@param key? string
---@return any
function beacle.config(key) end

---@class beacle.json
beacle.json = {}

---@param value any
---@return string|nil json, string|nil err
function beacle.json.encode(value) end

---@param text string
---@return any value, string|nil err
function beacle.json.decode(text) end

---Small key-value storage that survives restarts, 64 KiB per plugin and side.
---@class beacle.store
beacle.store = {}

---@param key string
---@return any
function beacle.store.get(key) end

---Stores a value (nil deletes). Raises an error when the store would pass 64 KiB.
---@param key string
---@param value any
function beacle.store.set(key, value) end

-- ---------------------------------------------------------------------------
-- agent.lua only

---Reads a file under a path listed in permissions.read (at most 1 MiB).
---@param path string
---@return string|nil content, string|nil err
function beacle.read(path) end

---Lists a directory under a path listed in permissions.read.
---@param dir string
---@return string[]|nil names, string|nil err
function beacle.list(dir) end

---Writes a file under a path listed in permissions.write. (2.2.5)
---@param path string
---@param data string
---@param opts? { append?: boolean }
---@return true|nil ok, string|nil err
function beacle.write(path, data, opts) end

---Runs a program listed in permissions.exec, without a shell, for at most 5 s
---(opts.timeout). Returns its standard output and error (up to 1 MiB each)
---and exit code, or nil and an error when it could not run at all.
---@param program string
---@param args? string[]
---@param opts? { stdin?: string, env?: table<string, string>, dir?: string, timeout?: number }
---@return string|nil stdout, number|string code_or_err, string|nil stderr
function beacle.exec(program, args, opts) end

---Reports a reading of a metric declared in manifest.json (a "disk_*"
---declaration covers "disk_sda"); nil drops it. In backend.lua the metric
---belongs to this computer, server "local". (backend: 2.2.5)
---@param name string
---@param value number|nil
function beacle.metric(name, value) end

-- ---------------------------------------------------------------------------
-- agent.lua and backend.lua: HTTP to hosts listed in permissions.http

---@class beacle.http
beacle.http = {}

---@param url string
---@return string|nil body, number|string status_or_err
function beacle.http.get(url) end

---@param url string
---@param body? string
---@param content_type? string defaults to application/json
---@return string|nil body, number|string status_or_err
function beacle.http.post(url, body, content_type) end

---Any method, with headers; a table body goes as JSON. (2.2.5)
---@param req { method?: string, url: string, headers?: table<string, string>, body?: string|table, timeout?: number }
---@return { status: number, headers: table<string, string>, body: string }|nil response, string|nil err
function beacle.http.request(req) end

-- ---------------------------------------------------------------------------
-- backend.lua only

---@class Server
---@field id string
---@field name string
---@field status string online | offline | agent_down | high_load | pending | ...
---@field online boolean the agent is connected right now
---@field host string
---@field public_ip string
---@field tags string[]
---@field location string
---@field agent_version string

---Every server in the panel.
---@return Server[]
function beacle.servers() end

---The latest reading of a metric on a server: one of this plugin's by its bare
---name ("cpu_temp"), any plugin's as "plugin.metric", the panel's own as
---"system.cpu" (mem, disk, load1, rx, tx). Server "local" is this computer.
---Nil when there is none.
---@param server_id string
---@param metric string
---@return number|nil
function beacle.value(server_id, metric) end

---Calls a beacle.on handler in this plugin's agent part on one server.
---@param server_id string
---@param action string
---@param args? any
---@return any result, string|nil err
function beacle.call(server_id, action, args) end

---Calls the panel's API in process, as the app does, for routes listed in
---permissions.api ("GET /api/vps/*"). Returns the decoded answer and the HTTP
---status. (2.2.5)
---@param method string
---@param path string
---@param body? string|table
---@return any answer, number|string status_or_err
function beacle.api(method, path, body) end

---Raises an alert (Alerts, Needs attention, webhooks); again while open does
---nothing. No server = this computer. (2.2.5)
---@param a { key: string, message: string, severity?: "warning"|"critical", server?: string }
function beacle.alert(a) end

---Resolves an alert raised with beacle.alert. (2.2.5)
---@param key string
---@param server? string
function beacle.resolve(key, server) end

---@alias SlotName
---| "nav.tab"         # a page of its own in the sidebar; opts = { id, title, icon }
---| "server.section"  # a card on each server's page; fn gets the server
---| "servers.column"  # one small block beside each server in the list; fn gets the server
---| "overview.card"   # a card on the Overview
---| "server.actions"  # small blocks in a server's header; fn gets the server (2.2.5)
---| "settings.section" # blocks in the plugin's card in Settings → Plugins (2.2.5)

---Puts blocks somewhere in the panel. `fn` returns a list of blocks (one
---block for servers.column), or nil for nothing. It runs while the panel
---waits, so keep it quick: at most 500 ms, no exec or http — gather data in
---beacle.every and keep it in a local variable.
---@param slot SlotName
---@param opts { title?: string, id?: string, icon?: string }
---@param fn fun(server?: Server): Block|Block[]|nil
function beacle.slot(slot, opts, fn) end

---Replaces a text of the panel, in every language. Keys are the ones in
---app/lib/l10n/strings_en.dart, e.g. "navAlerts".
---@param key string
---@param text string
function beacle.text(key, text) end

---Hides a part of the panel. Ids are listed in docs/plugins/api.md.
---@param id string
function beacle.hide(id) end

-- ---------------------------------------------------------------------------
-- Blocks (backend.lua)

---@class Block
---@field type string

---@alias Tone "ok"|"warn"|"err"|"dim"

---@class ui
ui = {}

---@param p string|{ text: string, tone?: Tone }
---@return Block
function ui.label(p) end

---A number with a label. `metric` follows live data on the block's server.
---@param p { value?: number, metric?: string, server?: string, label?: string, unit?: string, tone?: Tone }
---@return Block
function ui.stat(p) end

---A 0-100 bar.
---@param p { value?: number, metric?: string, server?: string, label?: string, detail?: string }
---@return Block
function ui.bar(p) end

---A metric's recorded history.
---@param p { metric: string, server?: string, hours?: number, title?: string, unit?: string }
---@return Block
function ui.chart(p) end

---@param p { columns?: string[], rows: any[][] }
---@return Block
function ui.table(p) end

---Calls beacle.on(action) with args (plus `server` on a server's page);
---with `confirm` the panel asks that question first (2.2.5).
---@param p { label: string, action: string, args?: table, confirm?: string }
---@return Block
function ui.button(p) end

---Enter calls beacle.on(action) with { value = text } (plus `server`).
---@param p { action: string, label?: string, hint?: string, value?: string }
---@return Block
function ui.input(p) end

---Blocks side by side, sharing the width.
---@param children Block[]
---@return Block
function ui.row(children) end

---Blocks one under another.
---@param children Block[]
---@return Block
function ui.column(children) end

---A tile: blocks one under another in a framed card, with an optional title.
---Put several in a ui.row to lay them side by side. New in 2.2.5; for older
---panels too, start with `ui.card = ui.card or ui.column`.
---@param p { title?: string, [integer]: Block }
---@return Block
function ui.card(p) end

---Opens an http(s) link in the browser. (2.2.5)
---@param p { text?: string, url: string }
---@return Block
function ui.link(p) end

---A switch; flipping it calls beacle.on(action) with args + { value = on }. (2.2.5)
---@param p { label?: string, value: boolean, action: string, args?: table }
---@return Block
function ui.toggle(p) end

---A drop-down; picking calls beacle.on(action) with args + { value = option }. (2.2.5)
---@param p { label?: string, value?: string, options: string[], action: string, args?: table }
---@return Block
function ui.select(p) end

---Monospace text in a scrolling box, e.g. command output. (2.2.5)
---@param p { text: string, height?: number, tail?: boolean }
---@return Block
function ui.code(p) end
