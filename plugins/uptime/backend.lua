-- Runs in the panel's backend. Checks a few web pages from this computer and
-- shows which answer: a tab with every site, and a card on the Overview when
-- one is down. Backend-only: there is no agent.lua, nothing runs on servers.

-- The pages to check. Each one's host must also be in manifest.json under
-- permissions.http, or the request is refused.
local SITES = {
  "https://example.com/",
  "https://example.org/",
}

local CHECK_EVERY = 10 -- seconds between two checks; each check is one site

-- Latest result per site: up (true/false/nil = not checked yet), what was
-- seen, and how many checks ago (the sandbox has no clock, so age is counted
-- in ticks of CHECK_EVERY).
local state = {}
for _, url in ipairs(SITES) do
  state[url] = { up = nil, seen = "not checked yet", at = 0 }
end

-- Paused sites survive a restart of the panel.
local paused = beacle.store.get("paused") or {}

local tick = 0
local next_site = 1
-- Before Beacle 2.2.5 a host that did not answer held the request until the
-- task's own 10 s ran out, and the task failed; five failures in a row
-- stopped the plugin. So a check that did not come back is followed by one
-- tick of rest.
local resting = false

beacle.every(CHECK_EVERY, function()
  tick = tick + 1
  if resting then
    resting = false
    return
  end

  -- One site per tick, round robin, skipping paused ones.
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

  resting = true -- cleared below if the request comes back in time
  local body, status = beacle.http.get(url)
  resting = false

  local s = state[url]
  s.at = tick
  if not body then
    s.up, s.seen = false, status -- status is the error message here
  elseif status >= 400 then
    s.up, s.seen = false, "HTTP " .. status
  else
    s.up, s.seen = true, "HTTP " .. status
  end
end)

local function ago(at)
  if at == 0 then return "—" end
  local seconds = (tick - at) * CHECK_EVERY
  if seconds < 60 then return "just now" end
  return math.floor(seconds / 60) .. " min ago"
end

-- A button (or anything) in the panel runs a handler; args comes from the block.
beacle.on("toggle", function(args)
  if paused[args.url] then
    paused[args.url] = nil
  else
    paused[args.url] = true
  end
  beacle.store.set("paused", paused)
  return (paused[args.url] and "Paused " or "Resumed ") .. args.url
end)

beacle.slot("nav.tab", { id = "uptime", title = "Uptime", icon = "heart" }, function()
  local blocks = {
    ui.label("Each site is checked from this computer, one every " .. CHECK_EVERY .. " s. Add sites at the top of backend.lua and their hosts to manifest.json."),
  }
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
    blocks[#blocks + 1] = ui.row{
      ui.label(url),
      ui.label{ text = label .. " · " .. s.seen, tone = tone },
      ui.label{ text = ago(s.at), tone = "dim" },
      ui.button{ label = paused[url] and "Resume" or "Pause", action = "toggle", args = { url = url } },
    }
  end
  return blocks
end)

-- On the Overview only while something is wrong.
beacle.slot("overview.card", { title = "Uptime" }, function()
  local down = {}
  for _, url in ipairs(SITES) do
    if state[url].up == false and not paused[url] then down[#down + 1] = url end
  end
  if #down == 0 then return nil end
  local blocks = { ui.label{ text = #down .. " of " .. #SITES .. " sites down", tone = "err" } }
  for _, url in ipairs(down) do
    blocks[#blocks + 1] = ui.label{ text = url .. " — " .. state[url].seen, tone = "dim" }
  end
  return blocks
end)
