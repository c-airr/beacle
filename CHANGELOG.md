# Changelog

## Unreleased

### Added

- **Marketplace** — Settings → Plugins → *Marketplace* lists the plugins in
  this repository (`plugins/index.json`) and installs or updates one with a
  click, through the same "what it can do" dialog as a .zip. The list and
  the code come from GitHub at the commit the app was built from, so it is
  the code reviewed with that release.
- **Setup screens built by the plugin** — a plugin meant for anyone draws
  its own settings screen in the `plugin.setup` slot (where your service
  is, a key, which of the things found there to watch) and saves it with
  `beacle.configure{…}`. *Configure* on its card opens it, and it opens by
  itself after an install from the Marketplace. New blocks and helpers for
  it: `ui.checklist`, `ui.input{ secret = true, args }` (also committed
  when leaving the field) and `beacle.base64`.
- **A notice when the panel stops answering, if you want one** — Settings
  → Notifications → *When the panel stops answering*: after 15 min, 1 h or
  6 h without the panel, the watchers tell your webhooks, and again when
  it is back. Off by default, for a panel on a laptop. Not sent while
  another server still reaches the panel (then it is the watcher's own
  tunnel), nor by a watcher that is cut off itself.
- **Uptime Kuma plugin** — your Uptime Kuma's monitors in a tab, with
  response times, alerts while one is down and an Overview card. Reads
  `/metrics` with an API key or a public status page; set up on its own
  screen.

### Fixed

- **"VPS offline" on Discord when it was your own internet that dropped** —
  a watcher on the same line as the panel (a server at home) came back
  from the same outage and "confirmed" every other server as offline
  before its tunnel had found them again. A watcher that cannot reach any
  other server now says so instead, and the panel asks the other watcher.
  The panel itself holds alerts while not one server answers with the
  internet up (its own Tailscale coming back), and gives the rest a grace
  when the first one is back.
- **Watchers stopped supervising the fleet on their first check** — the
  loop waited for an answer from itself, so with the panel closed nobody
  was told about a server going down. It now runs, probes a server's agent
  before SSH and ping, and does not blame the fleet when it is the one cut
  off. It no longer sends "Beacle backend offline" when the panel is
  closed or this computer's internet drops, unless you ask for it (above).
- **A server waiting for its agent could be taken by another machine on
  the tailnet** — saying the server's name or IP in its register frame was
  enough to get its token and the commands meant for it. A waiting server
  is now matched by the address the agent connects from, or the name
  Tailscale gives that address.
- **After the panel's data was reset, any machine on the tailnet could join
  the fleet** — an agent with an ID and token the panel no longer knew was
  adopted on its word, and could be elected a watcher and get the webhook
  URLs. It now waits until you let it in: a banner lists the servers
  asking, with the address and Tailscale name the panel checked itself.
- **A plugin could take the agent or the panel down with memory** — a
  string doubled in a loop, a table grown without end or one `string.rep`
  call. A call that grows the heap past 32 MiB is stopped, a repeat stops
  the plugin, and so does a plugin keeping more than 32 MiB between calls.
- **The install dialog called some programs harmless that run anything**
  — `git`, `tar`, `sed`, `docker`, `systemd-run`, `timeout`, `nice` and
  the like take a command in their arguments, and `python3.11` slipped
  past `python3`. They are now in red as "any command", with the shells.
- **Demo plugins** — `uptime`: two pages on one host (a site and its
  `/health`) drew into one chart, and a page taken out of the settings
  while down kept its alert open for good. `temp`: one failed `nvidia-smi`
  switched the GPU reading off until the agent restarted, a board sending
  its readings as text broke the whole Temp tab, and this computer's GPU
  tile turned yellow and red at the CPU's levels instead of 85/95 °C.

## 2.2.5 — 2026-10-18

Plugins that can do what the panel does: its API, settings, alerts, events
and history of this computer, with the install dialog saying plainly what
a plugin may do. Demo plugins in `plugins/demo`, and a fix for agents that
could pass for another server.

### Added

- **Tiles for plugins** — `ui.card{ title, … }` frames its blocks like the
  panel's own cards; several in a `ui.row` sit side by side. A plugin
  that starts with `ui.card = ui.card or ui.column` also runs on an older
  panel, with tiles drawn unframed.
- **Plugins that do what the panel does** — a backend part can call the
  panel's own API (`beacle.api`), so start a container, read a server's
  snapshot or resolve an alert, for the routes its manifest lists under
  `permissions.api`. Plugins never reach the plugin routes, the
  terminals or shutdown.
- **Plugin settings** — a manifest's `config` becomes a form under the
  plugin in Settings → Plugins (text, secret, number, switch, URL, list);
  the plugin reads it with `beacle.config`. Secrets stay on this computer.
  A URL typed there may be called without listing its host.
- **Plugin alerts, events and history of this computer** —
  `beacle.alert`/`beacle.resolve` raise alerts like the panel's own, with
  notifications; `beacle.on("event:alert", …)` hears every alert; and
  `beacle.metric` in a backend part records history and alerts for things
  that are not a server (`server = "local"`).
- **More for plugins** — `beacle.now` and `beacle.date`;
  `beacle.http.request` with any method and headers (API tokens);
  `beacle.write` on agents under `permissions.write`; `beacle.exec` with
  stdin, environment, working directory, a timeout of its own and
  stderr; a manifest `timeout` up to 5 minutes; wildcard metrics
  (`"disk_*"`); more server fields and the panel's own CPU/RAM/disk in
  `beacle.value`; blocks `ui.link`, `ui.toggle`, `ui.select`, `ui.code`
  and buttons that ask first; slots `server.actions` and
  `settings.section`; 52 more tab icons.
- **Know what a plugin can do before installing it** — the install
  dialog and each plugin's card say it in plain words, worst first:
  where it can send data (any address is flagged), programs it runs (a
  shell or interpreter means any command), files it reads that can hold
  passwords or the agent's token, files it changes, what it does
  through the panel, and — in red — a plugin that runs or reads things on
  your servers and may send to an address outside them. Risky ones are
  in red with a warning, and *View code* shows its Lua before you say
  yes.
- **Demo plugins in `plugins/demo/`** — `temp` (this computer, a Raspberry Pi
  Pico and every server in one tab), `uptime` and `neofetch` (the one
  the install dialog shows in red), with a README. `temp` replaces the
  2.2.0 example `temps`.
- **Agents keep up with plugins** — an agent too old for what a plugin
  calls is updated by the panel when the plugin is pushed to it.

### Fixed

- **Another machine on the tailnet could pass for one of your servers** —
  an agent connecting with only a server's ID (which `/beacle/alive`
  gives to anyone), or with its Tailscale name and IP, was accepted as
  that server and even handed its token: it would then get the commands,
  shells and file uploads meant for it. A server is now opened only by
  its token. An agent that lost its token gets the server back only from
  the address that server connects from, while it is offline, and with a
  new token; and `X-Forwarded-For` counts only from `tailscale serve`.
- **Needs attention agreed with Alerts** — the Overview flagged CPU, RAM
  and disks at fixed levels of its own (85 % disk and so on), ignoring
  each server's alert thresholds: a disk could be listed under *Needs
  attention* while Alerts said all is well, and an alerted problem showed
  twice. It now lists the alerts, and an offline server once.
- **Notification settings could be lost** — `webhooks.json` was written
  in place and a failed write was ignored: a write cut short (power, full
  disk) left a file that loaded as no destinations at all, and the panel
  had said saved. It is written through a temporary file now, and a save
  that fails says so.
- **A plugin waiting on a host that does not answer** — `beacle.http` and
  `beacle.exec` now give up a moment before the task or handler they run
  in, and return `nil, err`. They used to use up the whole call, which
  then failed, and five of those in a row stopped the plugin: a device
  switched off for a minute took the plugin down with it.

## 2.2.0 — 2026-10-17

Plugins in Lua, SSH snippets, alerts checked by the fleet before they
page, and warnings for expiring certificates and filling disks.

### Added

- **Plugins** — extend Beacle in Lua without touching Beacle itself. A
  plugin is a .zip (or a folder) with a manifest and up to two scripts:
  `agent.lua` runs inside the agent on every server and reports metrics,
  `backend.lua` runs in the panel and decides what it shows. **Settings →
  Plugins** installs one with a click — showing first what files,
  programs and hosts it may touch — and the panel sends each part where it
  belongs, to every server, including ones that connect later. Plugin
  metrics are kept in history, charted, and alert at the levels the
  manifest declares (each server can set its own warning level in its edit
  dialog), through the same webhooks as everything else. On screen a
  plugin can add a tab to the sidebar, a card to a server's page or the
  Overview, and a value beside each server in the list — numbers, bars,
  charts, tables, buttons and fields that run code on a server — rename
  any text and hide parts of the panel. A linked folder reloads on every
  save while you write one. Scripts run sandboxed: no file, program or host
  the manifest does not name, and a time limit on every call. Comes with a
  temperature plugin (CPU and GPU, from hwmon, thermal zones and
  nvidia-smi) as an example; the guide and the full API are in
  `docs/plugins`. Needs the 2.2.0 agent; `disable_plugins` in an agent's
  `config.json` refuses plugins on that server.

- **Snippets in the SSH tab** — a panel beside the shells keeps commands
  you type often. Clicking one pastes it into the current tab without
  pressing Enter; ▶ runs it. **Run on…** sends one command, a snippet or
  typed in, to several servers and saved hosts at once: each opens in a
  tab of its own and the command runs there once the shell has finished
  its login message. Multi-line snippets arrive as one pasted block.
  Snippets are kept on this computer (settings.json); the panel can be
  closed and brought back with the bolt button.
- **Expiring certificates** — the agent reads the certificate the proxy
  (Caddy or Nginx Proxy Manager) serves for each domain, over a local TLS
  handshake, and checks it again every six hours. An alert goes out when
  one expires within 14 days (warning) or 3 days (critical), and again if
  it does expire; a renewal resolves it. Proxy shows the date on the SSL
  badge once it is that close, and in its tooltip always, with the issuer.
  Caddy renews with 30 days left, so this means a renewal has been failing
  for two weeks. Needs the 2.2.0 agent.
- **Senders checked from the fleet, and chosen by hand** — an "agent
  down" or "VPS offline" alert is no longer sent the moment this computer
  loses sight of a server: the watcher sending it first asks that
  server's agent itself and pings the host, and sends nothing when the
  agent answers — a blink in the PC's connection used to page for every
  agent at once. When it does send, the message says what the watcher
  saw ("confirmed by …"). Nothing is ever sent from this computer any
  more: with neither watcher reachable the alert stays in the panel and
  the watchers' own supervision takes over. The automatic pick keeps the
  two senders in different networks (two servers behind the same home
  router never hold both seats unless there is nothing else), and
  **Settings → Notifications** can pin either seat to a chosen server; an
  offline pin is stood in for by the automatic pick. The check needs the
  2.2.0 agent on the watched server — it answers on its Tailscale address,
  port 8931 — older agents are reported as before.
- **When a disk will be full** — a disk that keeps filling shows "full in
  ~4 days at the current rate" under its bar on the server's page (hours
  when it is under two days). The rate is a straight line through the
  last three days of history, started over after a cleanup; it appears
  after half a day of data and only when the disk would run out within a
  month.

## 2.1.5 — 2026-10-11

An SSH tab you can actually type in, laid out like Termius, with saved
hosts that need no agent and the server's login message on connect.

### Added

- **Saved SSH hosts** — the "+" tile in the SSH tab opens a panel beside
  it to add any machine reachable over SSH: host, port, user, and a
  password, a private key (pasted or loaded from a file, with its
  passphrase) or both. The backend dials it with its own SSH client, so
  no agent is needed there. Passwords and keys never reach the app; on
  Windows they are encrypted for your account (DPAPI). A host's key is
  remembered the first time, and a changed key is refused.
- **Login message** — a shell opened through the agent prints the server's
  MOTD first ("Welcome to Ubuntu ...", system information), as an SSH
  login does; `~/.hushlogin` turns it off. Needs the 2.1.5 agent.

### Changed

- **SSH tab like Termius** — the title on top, below it every server and
  saved host as a tile in a grid, and a "+" tile to add one. The terminal
  is green on near-black.
- **SSH and Files open full screen by default** — on a fresh setup both
  tools now start in the main content area instead of their own window.
  A choice already made in setup or Settings stays as it was.

### Fixed

- **Typing in the SSH terminal** — on Windows no key reached the shell:
  the terminal's text input was rejected by Flutter ("view ID is null"),
  so a tab showed the prompt and nothing else happened. Keys now come
  straight from the keyboard.

## 2.1.0 — 2026-10-06

Eight languages across the whole panel, a light theme that is easy on the
eyes, search for everything behind Ctrl+K, and one "no internet" banner
instead of an offline alert per server when this computer loses its line.

### License

- **GPLv3** — Beacle 2.0 and later is licensed under the GNU General
  Public License v3.0. Releases before 2.0 stay under the MIT License.
  2.0.0–2.0.5 shipped with the MIT License; copies obtained under it keep
  the rights it granted.

### Added

- **Search (Ctrl+K)** — Ctrl+K (⌘K on macOS), or the search field in the
  top bar, opens a palette that finds servers by name, address, location or
  tag; Docker containers by name, image or compose project; systemd
  services; screen sessions; proxy sites; active alerts and the pages
  themselves. Enter opens the result where it lives: a container opens the
  Docker tab filtered to it, a service the Services tab on its server, a
  site the Proxy tab. It also has a few actions — add a server, open SSH on
  one, switch the theme. Arrow keys move, Esc closes. Inside an SSH shell
  Ctrl+K stays the shell's.
- **Light theme** — Settings → General → Theme: Dark, Light or System.
  Light is a cool paper grey with cards a shade lighter and soft near-black
  text, never white, so it does not glare; status colours are a step darker
  to keep their contrast, and the map and the SSH terminal have light
  palettes of their own. System follows the OS and switches with it.
  Switching is instant and keeps open tabs, shells and scroll positions;
  SSH and Files windows follow the main window.
- **Six more languages** — German, Spanish, French, Italian, Portuguese
  (Brazil) and Simplified Chinese, next to English and Polish. Each
  language is listed under its own name, so it can be found by someone who
  does not read the current one.
- **"No internet" instead of a wall of offline alerts** — when the computer
  running Beacle loses its own internet (Wi-Fi drops, cable out, the line
  still coming up after sleep), every server goes out of reach at once.
  Before raising an offline alert the panel now checks its own line
  (1.1.1.1 and 8.8.8.8, then a ping); if that is down too, a banner at the
  top says so and no offline alerts, sounds or webhooks go out. Servers
  still read offline and keep their last data. Once the line is back, and
  after waking from sleep, alerts wait 45 s for the agents to reconnect.

### Changed

- **Every screen is translated** — Overview, Servers, Proxy, Map, Alerts
  and the dialogs behind them were still English with Polish selected.
  Alert messages, which the backend writes in English (webhooks use them
  too), are shown in the interface language as well.
- **Settings and language reach tool windows** — an SSH or Files window
  open in its own window picks up a language or theme change at once
  instead of at its next start.

### Fixed

- **Stopping a session could kill Docker.** The agent remembered nohup
  jobs by PID only. Once a job ended — or the server rebooted — the number
  went to whatever started next, often dockerd or containerd, so the
  Services → nohup tab showed the old job as still running, and Stop sent
  SIGTERM and then SIGKILL to that process and its whole process group.
  Jobs are now pinned to their start time (older records: to their log
  file), a stranger with the same number is left alone and the record shows
  as exited.
- Closing an SSH tab sent a SIGKILL to the shell's group number three
  seconds later, by which time the number could belong to a freshly started
  container. It now goes only to the processes that were in that shell's
  session, each checked to still be the same process.
- screen commands name the session exactly (`pid.name`); a bare name is
  matched as a prefix, so "web" could hit "webapp".

**Update the agents** (Settings → Updates): the fix is in the agent.

## 2.0.5 — 2026-10-04

Log in to the terminal as the server's own account, a folder tree in Files,
steady tabs in Services, and the fixes that made 2.0.0 feel stuck.

**Update the agents too** (Settings → Updates, or "Update agent" on a
server's page): the account picker and the faster answers come from the
agent.

### Added

- **SSH terminal as ubuntu, opc, debian...** — the SSH tab offers, per
  server, the account to log in as: the server's own account by default, or
  root. No password is asked for: the agent starts the shell with that
  account's uid, groups and home, on a terminal it owns. The choice is
  remembered and tabs read `ubuntu@server`.
- **Folder tree in Files** — on the left, as in VS Code. It opens the way to
  the folder you are in; the arrows expand a folder without leaving the
  current one, the edge drags wider, and the tree button hides it.
- **Rebuilds are offered as updates** — the app knows the commit it was
  built from, so a fix republished under the same version number shows up
  in the update banner and Settings as e.g. "2.0.5 (4c235d8)" instead of
  going unnoticed. Builds from before this change do not know their commit
  and have to be reinstalled once by hand.

### Fixed

- The agent never answered a request for something it does not have (a
  route from a newer panel): the plain-text "404 page not found" could not
  be packed into a reply, so the reply was dropped and the panel waited 30
  seconds for a 502. Files froze like that on older agents. It answers at
  once now, and the app says the agent needs an update.
- Every server's process table showed `ps -eo pid,user,pcpu,...` at close to
  100% CPU. That was the agent's own listing: a process 20 ms old that spent
  them all working averages ~100%, and with no earlier sample to compare it
  fell back to that average. It is left out now; the server was never busy.
  The process tab also no longer starts a new listing while the last one is
  still on its way.
- Services: the tabs jumped and changed size at every click and every
  refresh. They sit in their own row now and keep their width whatever is
  selected, loading or counted; the same goes for the Docker tabs.

## 2.0.0 — 2026-10-03

SSH terminal and file explorer, a built-in WireGuard transport so servers no
longer need Tailscale, and admin tools: firewall, OS updates, cron,
reboot-and-restore, system logs, webhooks, tags and per-server thresholds.

**After updating the app, update your agents** (Settings → Updates, or
"Update agent" on a server's page). The terminal, the file explorer and the
other 2.0 tools need a 2.0 agent; older agents keep reporting as before.

### Added

- **Temporary SSH logins** — "SSH login" on a server's page or in the SSH
  tab creates a throwaway account (`beacle-xxxxxx`) with a one-time password
  for your own SSH client, optionally with sudo, valid 15 min to 24 h. Root's
  credentials never leave the panel. The agent lets only those accounts in
  with a password, checks the sshd config before reloading it, and deletes
  the account, its files and its processes when the time runs out.
- **New look** — Beacle's own icon instead of Flutter's (window, taskbar,
  tray, installer, macOS); the content sits in one rounded panel beside the
  sidebar, with rounded cards, buttons, dialogs and fields and a larger page
  title. The server header's buttons wrap instead of running off the edge.
- **Move servers to WireGuard** — a banner (shown while any server is still
  on Tailscale, gone for good once closed) and Settings → WireGuard list
  every server with whether it can switch: offline, agent older than 2.0,
  behind carrier NAT, or behind the same router as this computer are
  explained instead of attempted. Tick servers and press Switch; each one is
  tested and goes straight back to Tailscale if the tunnel is not up within
  2 minutes. No address to type. Tailscale itself stays installed on the
  server — Beacle only stops using it. Servers on WireGuard are listed with
  "Switch back to Tailscale".
- **WireGuard port opens itself** — when a server is installed with
  WireGuard or switched to it from the panel, the agent allows UDP 51931 in
  the server's own firewall, whichever it uses: ufw, firewalld or iptables
  (inserted ahead of Oracle Cloud's default REJECT and saved). A provider
  firewall outside the server (Oracle security list, AWS security group,
  Hetzner Cloud Firewall) still has to be opened by hand.
- **Reinstall** — "Install a specific version" (app) and the agent version
  picker offer the installed version as a reinstall, to pick up a build
  republished under the same version.
- **Test releases** — a tag or release title with "test" (also beta, rc,
  alpha), e.g. `2.0.1-test1`, is published as a pre-release. The app's
  auto-update, GitHub's Latest and the agents' default update skip it; the
  agent version picker lists it as TEST BUILD so it can be put on one server
  on purpose.
- **SSH terminal** — a root shell on any server, in tabs, from the new SSH
  entry in the bottom-left corner or "Connect with SSH" on a server's page.
  It runs through the Beacle agent, so no SSH keys or open port 22 are
  needed and it works the same over Tailscale and WireGuard. Closing a tab
  ends the shell; shells also end when the panel disconnects or after 30
  minutes without input. Opt out per server with `"disable_terminal": true`.
- **File explorer** — browse any server's filesystem, edit config files in
  place (saves are atomic, keep owner and permissions, and refuse to clobber
  a file someone changed on the server meanwhile), download and upload with
  progress and resume, new folder / rename / delete. `/`, top-level system
  directories and the agent's own files cannot be deleted. Works the same
  over Tailscale and WireGuard; opt out per server with `"disable_files": true`.
- **Panel API refuses browsers** — the local API used to answer any web page
  (`Access-Control-Allow-Origin: *`), so a site open in your browser could
  drive your servers. Requests from browsers are now rejected.
- **WireGuard transport** — optional built-in tunnel so VPS hosts do not need
  Tailscale; connectivity probe, add-server flow, Tailscale→WireGuard migration
  with timed fallback, and switch-back from server settings.
- **Tags and per-server thresholds** — group servers with tags and filter by
  them; override CPU/RAM/disk alert thresholds per server.
- **System log viewer** — syslog, auth.log, dmesg and proxy logs with live
  grep filtering.
- **OS updates** — pending APT/DNF updates with a security count, one-click
  background upgrade, reboot-required flag.
- **Cron and timers** — view crontabs and systemd timers, add and edit cron
  entries without memorizing the syntax.
- **Firewall manager** — UFW, firewalld and iptables behind one panel
  (nftables-only hosts get a read-only listing), with an SSH guard that
  refuses to lock you out and a dry-run of every change.
- **Reboot and restore** — reboot/poweroff from the panel with automatic
  screen and nohup session restore afterwards; no false offline alerts
  while the box is gone.
- **Alert webhooks** — Discord, ntfy.sh and Telegram notifications sent by
  the two most stable servers, so they arrive even with the desktop off.

### Fixed

- A slow command (an apt check, a docker call) froze the whole connection to
  that server: the agent ran commands one at a time on the loop that reads
  from the panel, so pings went unanswered and the server dropped offline,
  while file listings and terminal keystrokes waited behind it. Commands run
  side by side now; changes to the same feature still run in order.
- The SSH terminal opened `/bin/sh` instead of the user's shell (systemd sets
  `SHELL=/bin/sh` for root): no history, arrow keys or tab completion. It
  uses the shell from `/etc/passwd` now.
- Files: a folder that does not exist was reported as "agent too old", and a
  slow listing could land on top of the folder clicked into after it.
- Files: Upload opens a dialog — pick files, choose the server from a list
  and click through to the destination folder.
- OS updates looped: after "Update now" the same packages were offered again.
  `apt-get upgrade` keeps back packages that need a new dependency (a new
  kernel) — it now runs with `--with-new-pkgs`, still never removing
  anything. Packages apt would still not install (phased Ubuntu rollouts,
  conflicts) are listed as held back and no longer count as pending.
- Applying an update could hang or leave a half-updated install: closing the
  window left the backend and any SSH/Files windows running, their files
  stayed locked, and the copy retried for hours. "Apply and restart",
  Rollback and the installer now stop every Beacle process first.
- A server switched to WireGuard whose tunnel could not come up (e.g. one
  behind the panel's own router) took the Tailscale fallback as success,
  dropped it, and went offline for good at the next panel restart. Only a
  connection through the tunnel confirms the switch now, and "Switch back
  to Tailscale" works even while the agent is offline.
- Settings were half in English with Polish selected; the General, Updates
  and Status tabs are translated now.
- Firewall tab failed with "iptables: exit status 2" on servers using plain
  iptables.

## 1.2.0 — 2026-09-28

Docker grows up, processes can be killed, and the panel speaks Polish.

### Added

- **Docker Exec** — run a one-shot command inside any container (`cat .env`,
  migrations, …) with output, exit code and a 10-command history. The old
  "not wired yet" placeholder is gone.
- **Docker Compose actions** — Restart, Pull, Down and Pull & Up per project,
  with a progress dialog and full CLI output.
- **Docker Prune** — reclaim disk space with a preview of what will be freed
  before anything is removed. Volumes stay opt-in, off by default.
- **Kill processes** — SIGTERM / SIGKILL straight from the processes table,
  with a confirmation showing PID and command. The agent refuses PID 1 and
  its own PID.
- **Polish language** — English + Polish for onboarding, navigation, Docker,
  Services and Settings. First-run setup asks for the language (English by
  default); switch anytime in Settings. Remaining screens still English.

### Fixed

- Backend proxy timeouts for long operations: compose actions get 6 min,
  prune 3 min, exec 45 s — no more 502 while the agent is still pulling
  images.

### Protocol

- New agent routes: `POST /api/docker/containers/{id}/exec`,
  `POST /api/docker/compose/{project}/{action}`,
  `GET /api/docker/prune/preview`, `POST /api/docker/prune`,
  `POST /api/system/processes/{pid}/kill`. See `shared/PROTOCOL.md`.

## 1.1.0

- Stable release: monitoring, Docker, systemd, reverse proxy, map, alerts.
- Builds for Windows, Linux and macOS, built and attested by CI.
