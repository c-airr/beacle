-- Runs in the panel. Asks every server for its neofetch once a minute, shows
-- it on the server's page and, when "send" is on in its settings, posts it to
-- a collector at 192.168.1.50 (made up for this demo).
--
-- It is here to show the install dialog doing its job: a plugin that runs a
-- program on your servers and may send to an address outside them is shown
-- in red, as "can carry data off your servers", whatever its code says.

local COLLECTOR = "http://192.168.1.50/collect"
local SEND = beacle.config("send") == true

local info = {} -- server id -> { text = ..., at = ... } or { error = ... }
local last_send = "not sent yet"

local function collect()
  for _, s in ipairs(beacle.servers()) do
    if s.online then
      local r, err = beacle.call(s.id, "info")
      if not r then
        info[s.id] = { error = err }
      elseif r.error then
        info[s.id] = { error = r.error }
      else
        info[s.id] = { text = r.text, at = beacle.now() }
        if SEND then
          local _, status = beacle.http.post(COLLECTOR, beacle.json.encode{ server = s.name, neofetch = r.text })
          last_send = type(status) == "number" and ("HTTP " .. status) or tostring(status)
        end
      end
    end
  end
end

beacle.every(60, collect)

beacle.on("refresh", function()
  collect()
  return "Asked every server again"
end)

beacle.slot("server.section", { title = "Neofetch" }, function(server)
  local i = info[server.id]
  if not i then
    return { ui.label{ text = server.online and "Not read yet." or "Offline.", tone = "dim" } }
  end
  if i.error then
    return {
      ui.label{ text = i.error, tone = "err" },
      ui.label{ text = "Install neofetch on the server (apt install neofetch) to see it here.", tone = "dim" },
    }
  end
  return {
    ui.code{ text = i.text, height = 220 },
    ui.row{
      ui.label{ text = "read " .. beacle.date(i.at, "15:04:05"), tone = "dim" },
      ui.label{ text = SEND and ("sent to 192.168.1.50: " .. last_send) or "not sent anywhere", tone = SEND and "warn" or "dim" },
      ui.button{ label = "Read again", action = "refresh" },
    },
  }
end)
