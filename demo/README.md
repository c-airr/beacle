# Demo plugins

Three working Beacle plugins, to install as they are or to copy from. How
plugins work: [Writing Beacle plugins](../docs/plugins/README.md); every
function: [API reference](../docs/plugins/api.md). They need Beacle 2.2.5.

| Folder | What it shows | Runs on | Install dialog |
|---|---|---|---|
| [`temp`](temp) | One **Temp** tab of tiles: this computer, a Raspberry Pi Pico on the LAN, and every server | panel + every server | 🟡 |
| [`uptime`](uptime) | An **Uptime** tab: web pages checked from this computer, with response times and alerts | panel | 🔴 |
| [`neofetch`](neofetch) | A **Neofetch** card on every server's page, optionally posted to `192.168.1.50` | panel + every server | 🔴 |

## Installing

Settings → Plugins → **Install .zip** (zip the folder) or **Link a folder**
(pick the folder itself; every save there reloads the plugin, which is the
way to work on one). The panel sends the server part to every agent by
itself — nothing is installed on the servers by hand.

Before anything is installed the panel says what the plugin can do, worst
first, and **View code** shows its Lua. Beacle refuses whatever is not in
that list, so the list is the honest answer to "can this hurt me?"; what
the code does inside it is for you to read.

## temp

A tile per machine, three to a row (2–4 in its settings):

- **This computer** — CPU and GPU from
  [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor):
  run it as administrator and turn on *Options → Remote Web Server → Run*.
  A day of history; alerts at 80/90 °C (CPU) and 85/95 °C (GPU).
- **Raspberry Pi Pico** — any board that serves its state as JSON
  (`temp_c`, `rssi`, `uptime_s`, `mem_free`, …). Type its address in the
  plugin's settings, e.g. `http://192.168.1.123/status`; empty, no tile.
- **Every server** — CPU and GPU from the agent part, read from
  `/sys/class/hwmon`, `/sys/class/thermal` and `nvidia-smi`. A home server
  shows real readings; most VPSes have no sensor and say so.

The dialog shows it in yellow: it reads sensors and runs `nvidia-smi` on
servers, and talks only to `127.0.0.1` and the address you type in.

## uptime

Pages to check, how often and after how many failures to alert are in its
settings. Each page has a tile with its state, a 24 h response-time chart,
a switch to pause it and a link; a page that stays down raises an alert
(with your notifications), and the Overview gets a card while one is down.

Red in the dialog because of `"http": ["*"]`: it may connect anywhere,
which is what checking pages you type in needs. It runs nothing on your
servers and reads nothing there.

## neofetch

Asks every server for `neofetch --stdout` once a minute and shows it on the
server's page. With **Send to 192.168.1.50** on in its settings it also
posts each one there — the address is made up for this demo, and sending
is off until you turn it on.

It exists to be red: it runs a program on your servers *and* may send to
an address outside them, so whatever it runs could leave your servers. The
dialog says so whether or not the code sends anything. That is the
combination to look for in a plugin you did not write.

Needs `neofetch` on the servers (`apt install neofetch`); without it the
card says so.

## Editor

[`beacle.d.lua`](beacle.d.lua) describes the whole API for
[Lua Language Server](https://luals.github.io/) (VS Code's *Lua*
extension); [`.luarc.json`](.luarc.json) points it there, so opening this
folder gives completion and checks.
