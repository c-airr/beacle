-- Runs on every server. Reads the CPU and GPU temperature every 10 seconds
-- and reports the hottest sensor of each kind. A server without a sensor of
-- a kind reports nothing for it, so the panel shows no value rather than 0.

-- hwmon drivers that measure the CPU package (Intel, AMD, Raspberry Pi, ARM boards).
local CPU_HWMON = { coretemp = true, k10temp = true, zenpower = true, cpu_thermal = true, soc_thermal = true }
-- thermal zone types that are the CPU rather than the chipset or a battery.
local CPU_ZONE = { "x86_pkg_temp", "cpu", "soc", "coretemp" }

local function millidegrees(path)
  local raw = beacle.read(path)
  local n = raw and tonumber((raw:gsub("%s+", "")))
  if n then return n / 1000 end
end

local function hottest(a, b)
  if not a then return b end
  if not b then return a end
  return math.max(a, b)
end

-- /sys/class/hwmon/hwmonN/{name,tempM_input}: the most precise source.
local function from_hwmon(wanted)
  local best
  for _, dir in ipairs(beacle.list("/sys/class/hwmon") or {}) do
    local base = "/sys/class/hwmon/" .. dir
    local name = (beacle.read(base .. "/name") or ""):gsub("%s+", "")
    if wanted[name] then
      for _, file in ipairs(beacle.list(base) or {}) do
        if file:match("^temp%d+_input$") then
          best = hottest(best, millidegrees(base .. "/" .. file))
        end
      end
    end
  end
  return best
end

-- /sys/class/thermal/thermal_zoneN/{type,temp}: what VMs and small boards have.
local function from_thermal_zones()
  local best
  for _, zone in ipairs(beacle.list("/sys/class/thermal") or {}) do
    if zone:match("^thermal_zone") then
      local base = "/sys/class/thermal/" .. zone
      local kind = (beacle.read(base .. "/type") or ""):lower()
      for _, want in ipairs(CPU_ZONE) do
        if kind:find(want, 1, true) then
          best = hottest(best, millidegrees(base .. "/temp"))
          break
        end
      end
    end
  end
  return best
end

-- nvidia-smi prints one line per GPU. Once it is known to be missing, it is
-- not looked for again until the agent restarts; a run that fails (the
-- driver busy, a timeout) only skips this reading.
local has_nvidia = true
local function nvidia()
  if not has_nvidia then return nil end
  local out, code = beacle.exec("nvidia-smi", { "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits" })
  if not out then
    if tostring(code):find("not found", 1, true) then has_nvidia = false end
    return nil
  end
  if code ~= 0 then return nil end
  local best
  for line in out:gmatch("[^\n]+") do
    best = hottest(best, tonumber(line))
  end
  return best
end

beacle.every(10, function()
  local cpu = from_hwmon(CPU_HWMON) or from_thermal_zones()
  if cpu then beacle.metric("cpu_temp", cpu) end

  local gpu = hottest(nvidia(), from_hwmon({ amdgpu = true }))
  if gpu then beacle.metric("gpu_temp", gpu) end
end)
