-- Runs in the panel's backend. Checks web pages from this computer: a tab
-- with every page, its response time over the last day and a switch to
-- pause it; an alert (with notifications) when one stays down; a card on the
-- Overview while something is down. Backend-only: nothing runs on servers.
--
-- The pages are set in Settings → Plugins → Uptime. "http": ["*"] in the
-- manifest lets it reach whatever is typed there.

local SITES = {}
for url in tostring(beacle.config("sites") or ""):gmatch("[^%s,]+") do
  SITES[#SITES + 1] = url
end
local EVERY = math.max(5, beacle.config("every") or 10)
local DOWN_AFTER = math.max(1, beacle.config("down_after") or 2)

-- Latest result per page: up (true/false/nil = not checked yet), what was
-- seen, when, and failures in a row.
local state = {}
for _, url in ipairs(SITES) do
  state[url] = { seen = "not checked yet", fails = 0 }
end

-- Paused pages survive a restart of the panel.
local paused = beacle.store.get("paused") or {}

-- Pages with an open alert, kept across restarts: one taken out of the
-- settings while down is never checked again, so it is resolved here.
local alerted = beacle.store.get("alerted") or {}
do
  local listed, gone = {}, false
  for _, url in ipairs(SITES) do listed[url] = true end
  for url in pairs(alerted) do
    if not listed[url] then
      beacle.resolve(url)
      alerted[url], gone = nil, true
    end
  end
  if gone then beacle.store.set("alerted", alerted) end
end

local function set_alerted(url, on)
  if (alerted[url] or false) ~= on then
    alerted[url] = on or nil
    beacle.store.set("alerted", alerted)
  end
end

local function host_of(url)
  return (url:match("^%a+://([^/:]+)") or url):lower()
end

local pages_on = {} -- host -> how many pages it has here
for _, url in ipairs(SITES) do
  pages_on[host_of(url)] = (pages_on[host_of(url)] or 0) + 1
end

-- djb2, in hex: tells two pages of one host apart in a metric name.
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

-- A metric name per page: "ms_example_com", and "ms_example_com_1a2b3c4d"
-- when another page here shares the host — the site and its /health.
local function metric(url)
  local host = host_of(url)
  local name = host:gsub("[^a-z0-9]", "_")
  if (pages_on[host] or 0) > 1 then
    return "ms_" .. name:sub(1, 52) .. "_" .. checksum(url)
  end
  return "ms_" .. name:sub(1, 61)
end

local function record(url, up, seen, ms)
  local s = state[url]
  s.up, s.seen, s.at = up, seen, beacle.now()
  s.fails = up and 0 or s.fails + 1
  beacle.metric(metric(url), up and ms or nil)
  if up then
    beacle.resolve(url)
    set_alerted(url, false)
  elseif s.fails >= DOWN_AFTER then
    beacle.alert{ key = url, message = url .. " is down: " .. seen, severity = "critical" }
    set_alerted(url, true)
  end
end

local next_site = 1
beacle.every(EVERY, function()
  -- One page per tick, in turn, skipping paused ones.
  local url
  for _ = 1, #SITES do
    local candidate = SITES[next_site]
    next_site = next_site % #SITES + 1
    if not paused[candidate] then
      url = candidate
      break
    end
  end
  if not url then return end

  local started = beacle.now()
  local r, err = beacle.http.request{ url = url, timeout = 8 }
  local ms = math.floor((beacle.now() - started) * 1000)
  if not r then
    record(url, false, err)
  elseif r.status >= 400 then
    record(url, false, "HTTP " .. r.status)
  else
    record(url, true, "HTTP " .. r.status, ms)
  end
end)

local function ago(at)
  if not at then return "—" end
  local seconds = beacle.now() - at
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. " min ago" end
  return "at " .. beacle.date(at, "15:04")
end

-- The switch on each page's row: args.value is the new state.
beacle.on("watch", function(args)
  paused[args.url] = (not args.value) or nil
  beacle.store.set("paused", paused)
  if paused[args.url] then
    beacle.resolve(args.url) -- a paused page is not down
    set_alerted(args.url, false)
    beacle.metric(metric(args.url), nil)
  end
end)

beacle.slot("nav.tab", { id = "uptime", title = "Uptime", icon = "heart" }, function()
  if #SITES == 0 then
    return { ui.label{ text = "No pages to check. Add them in Settings → Plugins → Uptime.", tone = "dim" } }
  end
  local tiles = {}
  for _, url in ipairs(SITES) do
    local s = state[url]
    local label, tone = "unknown", "dim"
    if paused[url] then
      label = "paused"
    elseif s.up == true then
      label, tone = "up", "ok"
    elseif s.up == false then
      label, tone = "down", "err"
    end
    tiles[#tiles + 1] = ui.card{ title = url,
      ui.row{
        ui.label{ text = label .. " · " .. s.seen, tone = tone },
        ui.label{ text = ago(s.at), tone = "dim" },
        ui.toggle{ label = "Check", value = not paused[url], action = "watch", args = { url = url } },
      },
      ui.chart{ metric = metric(url), server = "local", hours = 24, title = "Response time" },
      ui.link{ text = "Open", url = url },
    }
  end
  return tiles
end)

-- On the Overview only while something is wrong.
beacle.slot("overview.card", { title = "Uptime" }, function()
  local down = {}
  for _, url in ipairs(SITES) do
    if state[url].up == false and not paused[url] then down[#down + 1] = url end
  end
  if #down == 0 then return nil end
  local blocks = { ui.label{ text = #down .. " of " .. #SITES .. " pages down", tone = "err" } }
  for _, url in ipairs(down) do
    blocks[#blocks + 1] = ui.label{ text = url .. " — " .. state[url].seen, tone = "dim" }
  end
  return blocks
end)

-- Under the plugin in Settings → Plugins.
beacle.slot("settings.section", {}, function()
  return { ui.label{ text = #SITES .. " pages, one every " .. EVERY .. " s; an alert after "
    .. DOWN_AFTER .. " failures in a row.", tone = "dim" } }
end)
