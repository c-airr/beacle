# Changelog

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
