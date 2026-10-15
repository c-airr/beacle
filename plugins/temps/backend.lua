-- Runs in the panel's backend. Puts the temperatures in three places:
-- the server list, each server's page and a tab of their own.

-- A small value beside each server in the list. No reading, no cell.
beacle.slot("servers.column", { title = "CPU °C" }, function(server)
  if beacle.value(server.id, "cpu_temp") == nil then return nil end
  return ui.stat{ metric = "cpu_temp", label = "" }
end)

-- A card on the server's page: both readings now, and the CPU over a day.
beacle.slot("server.section", { title = "Temperatures" }, function(server)
  local cpu = beacle.value(server.id, "cpu_temp")
  local gpu = beacle.value(server.id, "gpu_temp")
  if cpu == nil and gpu == nil then
    return { ui.label{ text = "No temperature sensor found on this server.", tone = "dim" } }
  end
  local now = {}
  if cpu then now[#now + 1] = ui.stat{ metric = "cpu_temp" } end
  if gpu then now[#now + 1] = ui.stat{ metric = "gpu_temp" } end
  local blocks = { ui.row(now) }
  if cpu then blocks[#blocks + 1] = ui.chart{ metric = "cpu_temp", hours = 24 } end
  return blocks
end)

local function fmt(v)
  if v == nil then return "—" end
  return string.format("%.1f °C", v)
end

-- The whole fleet at a glance, hottest first.
beacle.slot("nav.tab", { id = "temps", title = "Temperatures", icon = "thermostat" }, function()
  local list = {}
  for _, s in ipairs(beacle.servers()) do
    list[#list + 1] = { name = s.name, cpu = beacle.value(s.id, "cpu_temp"), gpu = beacle.value(s.id, "gpu_temp") }
  end
  table.sort(list, function(a, b) return (a.cpu or -1) > (b.cpu or -1) end)
  local rows = {}
  for _, r in ipairs(list) do
    rows[#rows + 1] = { r.name, fmt(r.cpu), fmt(r.gpu) }
  end
  return {
    ui.label("Hottest sensor per server. Alerts fire at the levels in manifest.json; a server's edit dialog can lower them."),
    ui.table{ columns = { "Server", "CPU", "GPU" }, rows = rows },
  }
end)
