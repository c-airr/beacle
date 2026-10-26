-- Runs in the panel's backend. Reads your Uptime Kuma and shows its
-- monitors in Beacle: an "Uptime Kuma" tab with a tile per monitor and its
-- response time over the last day, an alert (with your notifications) while
-- one is down, and a card on the Overview then.
--
-- Two ways in, picked on its setup screen (Settings → Plugins → Uptime Kuma
-- → Configure):
--   metrics      /metrics with an API key: every monitor, with response times
--   status page  a public status page by its slug: its monitors, no key
-- The address is typed in its settings, so it needs no "http" permission.

ui.card = ui.card or ui.column

local URL = (beacle.config("url") or ""):gsub("/+$", "")
local SOURCE = beacle.config("source") or "metrics"
local API_KEY = beacle.config("api_key") or ""
local SLUG = beacle.config("slug") or ""
local EVERY = math.max(10, beacle.config("every") or 30)
local ALERTS = beacle.config("alerts") ~= false

-- Monitors to watch, by name; none means all of them.
local WATCH, watch_all = {}, true
for name in tostring(beacle.config("monitors") or ""):gmatch("[^\n]+") do
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name ~= "" then
    WATCH[name], watch_all = true, false
  end
end
local function watched(name) return watch_all or WATCH[name] end

local STATUS = { [0] = "down", [1] = "up", [2] = "pending", [3] = "maintenance" }
local TONE = { down = "err", up = "ok", pending = "warn", maintenance = "dim" }

-- What the last read found: every monitor in Kuma (for the setup screen)
-- and the state of each one. Monitor names seen before are kept, so the
-- setup screen lists them at once after a restart.
local monitors = {} -- name -> { status, ms, msg }
local seen = beacle.store.get("seen") or {}
local last = { error = URL == "" and "not set up yet" or "not read yet" }

-- djb2, in hex: keeps two names that differ only in punctuation apart.
local function checksum(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  local hex = ""
  for _ = 1, 8 do
    hex = ("0123456789abcdef"):sub(h % 16 + 1, h % 16 + 1) .. hex
    h = math.floor(h / 16)
  end
  return hex
end

local function metric(name)
  local slug = name:lower():gsub("[^a-z0-9]", "_")
  return "ms_" .. slug:sub(1, 43) .. "_" .. checksum(name)
end

-- monitor_name="…" out of a Prometheus label set, with \" and \\ inside.
local function label(labels, key)
  local start = labels:find(key .. '="', 1, true)
  if not start then return nil end
  local i, out = start + #key + 2, {}
  while i <= #labels do
    local c = labels:sub(i, i)
    if c == "\\" then
      local n = labels:sub(i + 1, i + 1)
      out[#out + 1] = n == "n" and "\n" or n
      i = i + 2
    elseif c == '"' then
      return table.concat(out)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return nil
end

-- /metrics: monitor_status and monitor_response_time per monitor.
local function read_metrics()
  local headers = {}
  if API_KEY ~= "" then
    headers.Authorization = "Basic " .. beacle.base64.encode(":" .. API_KEY)
  end
  local r, err = beacle.http.request{ url = URL .. "/metrics", headers = headers, timeout = 10 }
  if not r then return nil, err end
  if r.status == 401 or r.status == 403 then return nil, "the API key was refused (HTTP " .. r.status .. ")" end
  if r.status ~= 200 then return nil, "HTTP " .. r.status .. " from /metrics" end
  local found = {}
  for line in r.body:gmatch("[^\n]+") do
    local name_ = line:match("^([%w_]+){")
    if name_ == "monitor_status" or name_ == "monitor_response_time" then
      local labels, value = line:match("^[%w_]+{(.*)}%s+(%S+)")
      local name = labels and label(labels, "monitor_name")
      local n = tonumber(value)
      if name and n then
        local m = found[name] or {}
        if name_ == "monitor_status" then m.status = STATUS[n] else m.ms = n end
        found[name] = m
      end
    end
  end
  if next(found) == nil and not r.body:find("monitor_status", 1, true) then
    return nil, "that address does not look like Uptime Kuma's /metrics"
  end
  return found
end

-- A public status page: its monitor list, then their latest heartbeats.
local function read_status_page()
  if SLUG == "" then return nil, "no status page slug" end
  local page, err = beacle.http.request{ url = URL .. "/api/status-page/" .. SLUG, timeout = 10 }
  if not page then return nil, err end
  if page.status ~= 200 then return nil, "HTTP " .. page.status .. " for status page " .. SLUG end
  local beats, err2 = beacle.http.request{ url = URL .. "/api/status-page/heartbeat/" .. SLUG, timeout = 10 }
  if not beats then return nil, err2 end
  local p, b = beacle.json.decode(page.body), beacle.json.decode(beats.body)
  if type(p) ~= "table" or type(b) ~= "table" then return nil, "the status page did not answer with JSON" end
  local found = {}
  for _, group in ipairs(p.publicGroupList or {}) do
    for _, m in ipairs(group.monitorList or {}) do
      local list = (b.heartbeatList or {})[tostring(m.id)] or {}
      local latest = list[#list] or {}
      found[m.name] = { status = STATUS[latest.status] or "pending", ms = tonumber(latest.ping), msg = latest.msg }
    end
  end
  return found
end

-- Monitors with an open alert, across restarts: one taken off the list, or
-- gone from Kuma, is resolved instead of staying open for good.
local alerted = beacle.store.get("alerted") or {}
local function set_alerted(name, on)
  if (alerted[name] or false) ~= on then
    alerted[name] = on or nil
    beacle.store.set("alerted", alerted)
  end
end
for name in pairs(alerted) do
  if not ALERTS or not watched(name) then
    beacle.resolve(name)
    set_alerted(name, false)
  end
end

local function read()
  if URL == "" then return end
  local found, err
  if SOURCE == "status page" then
    found, err = read_status_page()
  else
    found, err = read_metrics()
  end
  if not found then
    -- Kuma out of reach says nothing about the monitors: no alert either way.
    last = { error = err, at = beacle.now(), good = last.good }
    return
  end
  last = { at = beacle.now(), good = beacle.now() }
  local names, changed = {}, false
  for name in pairs(found) do
    names[#names + 1] = name
    if not seen[name] then seen[name], changed = true, true end
  end
  if changed then beacle.store.set("seen", seen) end
  monitors = found
  for name, m in pairs(found) do
    if watched(name) then
      beacle.metric(metric(name), m.status == "up" and m.ms or nil)
      if ALERTS and m.status == "down" then
        beacle.alert{ key = name, severity = "critical",
          message = name .. " is down in Uptime Kuma" .. ((m.msg and m.msg ~= "") and (": " .. m.msg) or "") }
        set_alerted(name, true)
      elseif m.status == "up" or m.status == "maintenance" then
        beacle.resolve(name)
        set_alerted(name, false)
      end
    end
  end
  for name in pairs(alerted) do
    if not found[name] then
      beacle.resolve(name)
      set_alerted(name, false)
    end
  end
end

if URL ~= "" then beacle.every(EVERY, read) end

local function sorted(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function ago(at)
  if not at then return "never" end
  local s = beacle.now() - at
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. " min ago" end
  return "at " .. beacle.date(at, "15:04")
end

-- ---------------------------------------------------------------- setup ----

-- What is typed on the setup screen and not saved yet. Saved settings
-- restart the plugin, which starts over from them.
local draft = { url = URL, source = SOURCE, slug = SLUG }

beacle.on("set", function(args)
  draft[args.key] = args.value
end)

beacle.on("connect", function()
  local url = tostring(draft.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if url == "" then return "Type the address of your Uptime Kuma first." end
  local ok, err = beacle.configure{ url = url, source = draft.source, slug = draft.slug, api_key = draft.api_key }
  if not ok then return err end
  return "Saved. Reading the monitors…"
end)

beacle.on("pick", function(args)
  local ok, err = beacle.configure{ monitors = table.concat(args.values or {}, "\n") }
  if not ok then return err end
end)

beacle.on("every", function(args)
  beacle.configure{ every = tonumber(args.value) }
end)

beacle.on("alerts", function(args)
  beacle.configure{ alerts = args.value == true }
end)

beacle.slot("plugin.setup", {}, function()
  local b = {
    ui.label{ text = "Where Beacle reads your monitors from.", tone = "dim" },
    ui.input{ label = "Uptime Kuma address", hint = "http://192.168.1.10:3001", value = draft.url,
              action = "set", args = { key = "url" } },
    ui.select{ label = "Read from", value = draft.source, options = { "metrics", "status page" },
               action = "set", args = { key = "source" } },
  }
  if draft.source == "status page" then
    b[#b + 1] = ui.input{ label = "Status page slug", hint = "the end of the status page's address", value = draft.slug,
                          action = "set", args = { key = "slug" } }
  else
    b[#b + 1] = ui.input{ label = "API key", secret = true,
                          hint = API_KEY ~= "" and "saved — type a new one to replace it" or "Uptime Kuma → Settings → API Keys",
                          action = "set", args = { key = "api_key" } }
  end
  b[#b + 1] = ui.button{ label = URL == "" and "Connect" or "Save and reconnect", action = "connect" }

  if URL ~= "" then
    if last.error then
      b[#b + 1] = ui.label{ text = "Uptime Kuma: " .. last.error, tone = last.at and "err" or "dim" }
    else
      local n = 0
      for _ in pairs(monitors) do n = n + 1 end
      b[#b + 1] = ui.label{ text = "Connected — " .. n .. " monitors, read " .. ago(last.at) .. ".", tone = "ok" }
    end
  end

  local names = sorted(next(monitors) and monitors or seen)
  if #names > 0 then
    local picked = {}
    for _, name in ipairs(names) do
      if WATCH[name] then picked[#picked + 1] = name end
    end
    b[#b + 1] = ui.checklist{ label = "Monitors to watch — none ticked: all of them", options = names,
                              values = picked, action = "pick" }
    b[#b + 1] = ui.row{
      ui.select{ label = "Read every", value = tostring(math.floor(EVERY)), options = { "15", "30", "60", "300" }, action = "every" },
      ui.toggle{ label = "Alert when one is down", value = ALERTS, action = "alerts" },
    }
  end
  return b
end)

-- ----------------------------------------------------------------- tabs ----

local function tile(name, m)
  local st = m.status or "pending"
  local t = { title = name,
    ui.row{
      ui.label{ text = st, tone = TONE[st] },
      ui.label{ text = m.ms and (math.floor(m.ms) .. " ms") or "", tone = "dim" },
    },
  }
  if m.msg and m.msg ~= "" and st ~= "up" then t[#t + 1] = ui.label{ text = m.msg, tone = "dim" } end
  t[#t + 1] = ui.chart{ metric = metric(name), server = "local", hours = 24, title = "Response time" }
  return ui.card(t)
end

beacle.slot("nav.tab", { id = "kuma", title = "Uptime Kuma", icon = "heart" }, function()
  if URL == "" then
    return { ui.label{ text = "Not set up yet: Settings → Plugins → Uptime Kuma → Configure.", tone = "dim" } }
  end
  local names, counts = {}, { up = 0, down = 0, pending = 0, maintenance = 0 }
  for name, m in pairs(monitors) do
    if watched(name) then
      names[#names + 1] = name
      counts[m.status or "pending"] = (counts[m.status or "pending"] or 0) + 1
    end
  end
  table.sort(names, function(a, b)
    -- Down first, then by name.
    local da, db = monitors[a].status == "down", monitors[b].status == "down"
    if da ~= db then return da end
    return a < b
  end)
  local out = {}
  if last.error then
    out[#out + 1] = ui.label{ text = "Uptime Kuma: " .. last.error .. " (last good read " .. ago(last.good) .. ")", tone = "err" }
  end
  out[#out + 1] = ui.label{ text = counts.up .. " up, " .. counts.down .. " down, " .. counts.pending .. " pending, "
    .. counts.maintenance .. " in maintenance · read " .. ago(last.at), tone = counts.down > 0 and "err" or "dim" }
  local row = {}
  for _, name in ipairs(names) do
    row[#row + 1] = tile(name, monitors[name])
    if #row == 3 then
      out[#out + 1] = ui.row(row)
      row = {}
    end
  end
  if #row > 0 then
    while #row < 3 do row[#row + 1] = ui.column{} end
    out[#out + 1] = ui.row(row)
  end
  return out
end)

beacle.slot("overview.card", { title = "Uptime Kuma" }, function()
  local down = {}
  for name, m in pairs(monitors) do
    if watched(name) and m.status == "down" then down[#down + 1] = name end
  end
  if #down == 0 then return nil end
  table.sort(down)
  local b = { ui.label{ text = #down .. " monitors down", tone = "err" } }
  for _, name in ipairs(down) do
    b[#b + 1] = ui.label{ text = name .. ((monitors[name].msg or "") ~= "" and (" — " .. monitors[name].msg) or ""), tone = "dim" }
  end
  return b
end)

beacle.slot("settings.section", {}, function()
  if URL == "" then return { ui.label{ text = "Not set up yet — press Configure.", tone = "dim" } } end
  return { ui.label{ text = SOURCE .. " at " .. URL .. ", every " .. math.floor(EVERY) .. " s" ..
    (last.error and (" · " .. last.error) or ""), tone = last.error and "err" or "dim" } }
end)
