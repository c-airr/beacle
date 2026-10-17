-- Runs in the panel's backend. One "Temp" tab of tiles:
--   this computer  CPU and GPU, read from LibreHardwareMonitor
--   a LAN device   a small board that serves its state as JSON (written for
--                  a Raspberry Pi Pico W: temp_c, rssi, uptime_s, mem_free…)
--   every server   CPU and GPU from agent.lua, with a day of history; most
--                  VPSes have no sensor and say so.

-- LibreHardwareMonitor on this computer, with Options → Remote Web Server →
-- Run. It has to run as administrator to see the CPU's sensors.
local LHM = "http://127.0.0.1:8085/data.json"

-- The device's JSON status page, e.g. "http://192.168.1.50/status", and the
-- name on its tile. Empty: no tile. Its host must also be in manifest.json
-- under permissions.http.
local DEVICE = ""
local DEVICE_NAME = "Raspberry Pi Pico"

local TILES_PER_ROW = 3

-- ui.card came with Beacle 2.2.5. Before it a tile is a plain column, with
-- its title as the first line.
local card = ui.card or function(p)
  table.insert(p, 1, ui.label(p.title))
  return ui.column(p)
end

local pc = { error = "not read yet" }
local device = { error = "not read yet" }

-- LibreHardwareMonitor formats values with this computer's locale:
-- "45.5 °C" or "45,5 °C".
local function number(text)
  if type(text) == "number" then return text end
  return tonumber((tostring(text or ""):gsub(",", ".")):match("%-?%d+%.?%d*"))
end

-- data.json is a tree: computer → hardware → sensor groups → sensors. A
-- sensor's SensorId names its hardware ("/amdcpu/0/temperature/2",
-- "/gpu-nvidia/0/temperature/0"); hardware nodes carry the model name.
local function read_lhm(tree)
  local found = { cpu = {}, gpu = {} }
  local function walk(node, hardware)
    local id = node.SensorId or ""
    if node.Type == "Temperature" or id:find("/temperature/", 1, true) then
      local kind = id:find("cpu/", 1, true) and "cpu" or id:find("^/gpu") and "gpu"
      local value = number(node.Value)
      if kind and value then
        local list = found[kind]
        list[#list + 1] = { name = node.Text or "", value = value, hardware = hardware }
      end
    end
    local image = node.ImageURL or ""
    if image:find("cpu", 1, true) or image:find("nvidia", 1, true) or image:find("ati", 1, true) or image:find("intel", 1, true) then
      hardware = node.Text
    end
    for _, child in ipairs(node.Children or {}) do
      walk(child, hardware)
    end
  end
  walk(tree, nil)

  -- The sensor that stands for the whole chip, else the hottest one.
  local function pick(list, preferred)
    for _, want in ipairs(preferred) do
      for _, s in ipairs(list) do
        if s.name == want then return s end
      end
    end
    local best
    for _, s in ipairs(list) do
      if not best or s.value > best.value then best = s end
    end
    return best
  end
  return pick(found.cpu, { "CPU Package", "Core (Tctl/Tdie)", "Core (Tdie)", "Core (Tctl)" }),
         pick(found.gpu, { "GPU Core" })
end

beacle.every(10, function()
  local body, err = beacle.http.get(LHM)
  local tree = body and beacle.json.decode(body)
  if not tree then
    pc = { error = body and "LibreHardwareMonitor sent something that is not JSON" or ("LibreHardwareMonitor: " .. tostring(err)) }
    return
  end
  local cpu, gpu = read_lhm(tree)
  pc = { cpu = cpu, gpu = gpu }
end)

-- Before Beacle 2.2.5 a device that is switched off held the request until
-- this task's 10 s ran out, which counted as a failure, and five in a row
-- stopped the plugin. So after a request that did not come back, one tick
-- is skipped.
local resting = false
if DEVICE ~= "" then
  beacle.every(10, function()
    if resting then
      resting = false
      return
    end
    resting = true
    local body, err = beacle.http.get(DEVICE)
    resting = false
    local data = body and beacle.json.decode(body)
    if type(data) == "table" then
      device = { data = data }
    else
      device = { error = body and "not JSON" or tostring(err) }
    end
  end)
end

local function uptime(seconds)
  seconds = math.floor(seconds)
  local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
  if d > 0 then return d .. "d " .. h .. "h" end
  if h > 0 then return h .. "h " .. m .. "m" end
  return m .. "m"
end

local function kib(bytes) return math.floor(bytes / 1024) .. " KiB" end

-- Below -75 dBm Wi-Fi starts dropping packets.
local function rssi_tone(dbm)
  if dbm >= -60 then return "ok" end
  if dbm >= -75 then return "warn" end
  return "err"
end

local function temp_tone(c, warn, crit)
  if c >= crit then return "err" end
  if c >= warn then return "warn" end
  return nil
end

local function pc_tile()
  if pc.error then
    return card{ title = "This computer",
      ui.label{ text = pc.error, tone = "err" },
      ui.label{ text = "Start LibreHardwareMonitor as administrator and turn on Options → Remote Web Server → Run.", tone = "dim" } }
  end
  local stats, names = {}, {}
  if pc.cpu then
    stats[#stats + 1] = ui.stat{ value = pc.cpu.value, label = "CPU", unit = "°C", tone = temp_tone(pc.cpu.value, 80, 90) }
    names[#names + 1] = ui.label{ text = (pc.cpu.hardware or "CPU") .. " · " .. pc.cpu.name, tone = "dim" }
  end
  if pc.gpu then
    stats[#stats + 1] = ui.stat{ value = pc.gpu.value, label = "GPU", unit = "°C", tone = temp_tone(pc.gpu.value, 80, 90) }
    names[#names + 1] = ui.label{ text = (pc.gpu.hardware or "GPU") .. " · " .. pc.gpu.name, tone = "dim" }
  end
  if #stats == 0 then
    return card{ title = "This computer",
      ui.label{ text = "LibreHardwareMonitor answers but shows no CPU or GPU temperature. Is it running as administrator?", tone = "warn" } }
  end
  local tile = { title = "This computer", ui.row(stats) }
  for _, n in ipairs(names) do tile[#tile + 1] = n end
  return card(tile)
end

-- The fields a Pico W status page has; anything else is listed below them.
local KNOWN = { temp_c = true, rssi = true, uptime_s = true, mem_free = true, mem_total = true, flash_free = true, flash_total = true }

local function device_tile()
  if device.error then
    return card{ title = DEVICE_NAME, ui.label{ text = device.error, tone = "err" }, ui.label{ text = DEVICE, tone = "dim" } }
  end
  local d = device.data
  local stats = {}
  if d.temp_c then stats[#stats + 1] = ui.stat{ value = d.temp_c, label = "Chip", unit = "°C", tone = temp_tone(d.temp_c, 60, 70) } end
  if d.rssi then stats[#stats + 1] = ui.stat{ value = d.rssi, label = "Wi-Fi", unit = "dBm", tone = rssi_tone(d.rssi) } end
  local tile = { title = DEVICE_NAME, ui.row(stats) }
  if d.uptime_s then tile[#tile + 1] = ui.label{ text = "Up " .. uptime(d.uptime_s), tone = "dim" } end
  if d.mem_free and d.mem_total then
    tile[#tile + 1] = ui.bar{ value = 100 * (1 - d.mem_free / d.mem_total), label = "RAM used", detail = kib(d.mem_free) .. " free" }
  end
  if d.flash_free and d.flash_total then
    tile[#tile + 1] = ui.bar{ value = 100 * (1 - d.flash_free / d.flash_total), label = "Flash used", detail = kib(d.flash_free) .. " free" }
  end
  local rows = {}
  for key, value in pairs(d) do
    if not KNOWN[key] then rows[#rows + 1] = { key, tostring(value) } end
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  if #rows > 0 then tile[#tile + 1] = ui.table{ rows = rows } end
  return card(tile)
end

local function server_tile(s, cpu, gpu)
  local tile = { title = s.name }
  if not s.online then
    tile[#tile + 1] = ui.label{ text = "Offline", tone = "err" }
  elseif not cpu and not gpu then
    tile[#tile + 1] = ui.label{ text = "No temperature sensor — usual for a VPS.", tone = "dim" }
  end
  local now = {}
  if cpu then now[#now + 1] = ui.stat{ metric = "cpu_temp", server = s.id } end
  if gpu then now[#now + 1] = ui.stat{ metric = "gpu_temp", server = s.id } end
  if #now > 0 then tile[#tile + 1] = ui.row(now) end
  if cpu then tile[#tile + 1] = ui.chart{ metric = "cpu_temp", server = s.id, hours = 24 } end
  return card(tile)
end

-- Tiles in rows; a short last row is padded so its tiles keep their width.
local function grid(tiles, per_row)
  local rows = {}
  for i = 1, #tiles, per_row do
    local row = {}
    for j = i, i + per_row - 1 do
      row[#row + 1] = tiles[j] or ui.column{}
    end
    rows[#rows + 1] = ui.row(row)
  end
  return rows
end

beacle.slot("nav.tab", { id = "temp", title = "Temp", icon = "thermostat" }, function()
  local top = { pc_tile() }
  if DEVICE ~= "" then top[#top + 1] = device_tile() end

  -- Servers with a sensor first, then by name.
  local servers = {}
  for _, s in ipairs(beacle.servers()) do
    servers[#servers + 1] = { s = s, cpu = beacle.value(s.id, "cpu_temp"), gpu = beacle.value(s.id, "gpu_temp") }
  end
  table.sort(servers, function(a, b)
    local sa, sb = (a.cpu or a.gpu) and 1 or 0, (b.cpu or b.gpu) and 1 or 0
    if sa ~= sb then return sa > sb end
    return a.s.name < b.s.name
  end)
  local tiles = {}
  for _, r in ipairs(servers) do tiles[#tiles + 1] = server_tile(r.s, r.cpu, r.gpu) end

  local blocks = grid(top, #top)
  for _, row in ipairs(grid(tiles, TILES_PER_ROW)) do blocks[#blocks + 1] = row end
  return blocks
end)
