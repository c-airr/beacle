# Installer

The installer is wired into the build. `scripts/build.ps1` runs the Inno
Setup script when Inno Setup is installed, and `.github/workflows/build-installers.yml`
builds both the Windows installer and the Linux install scripts in CI and
attaches them to the release.

## What is here

| File | What it does |
|---|---|
| `windows/beacle.iss` | Inno Setup. Downloads `beacle-windows-x64.zip` (app+backend) from latest. |
| `linux/beacle.desktop` | Application entry. This is the file that makes GNOME find the app. |
| `linux/install_app.sh` | Desktop Linux installer — detects arch, downloads tar.gz from latest. |
| `linux/install.sh` | Compat alias → `install_app.sh`. |
| `linux/uninstall.sh` | Stops the app and backend, then removes both the install and the config. |
| `ci/build-installers.yml.draft` | Left as a reference. The live workflow is `.github/workflows/build-installers.yml`. |

## How it is meant to work

The installer people download is small and fetches the real payload from the
GitHub release. Desktop assets (no agents inside):

- `beacle-windows-x64.zip` — `beacle.exe`, `beacle-backend.exe`, Flutter runtime
- `beacle-linux-x64.tar.gz` — the same for Linux

VPS agents are a separate release (`agentbeta`): `beacle-agent-amd64`,
`beacle-agent-arm64`, `install_agent.sh`.

## Making the app findable

This was the point of the exercise, so it is worth being precise about what
actually does the work.

**Windows.** Windows Search indexes the Start Menu. A shortcut under
`{group}` is the whole mechanism — typing "beacle" finds it, and the user can
pin it from there. The `AppUserModelID` on the shortcut matters more than it
looks: without it, a pinned shortcut and the running window can end up as two
separate taskbar buttons, and the pin appears to do nothing.

**GNOME.** Pressing Super opens the overview and searches `.desktop` entries.
It matches on `Name`, `Comment`, `GenericName` and `Keywords`, which is why
that file lists words like `docker` and `monitoring` rather than only the
product name. `StartupWMClass` must match the class the window reports, or a
running Beacle shows up as a second icon in the dash that cannot be pinned.
Pinning itself is the user's move: right-click → Add to Favourites.

## Decisions taken

- **Always the latest release.** Neither installer pins a tag. A pinned
  installer goes stale the moment the next version ships, and someone who
  downloads it later gets an old build without being told. The version in
  `beacle.iss` is cosmetic — it shows in Apps & Features and can be overridden
  with `iscc /DAppVersion=1.2.3` — and does not decide what is downloaded.

- **Uninstalling removes everything.** Both uninstallers stop the app and the
  backend first, then delete the install and the configuration. The backend
  outliving the window is deliberate (the panel adopts a running one on next
  launch), so an uninstall that only deleted files would leave it holding port
  9930 and every agent socket with nothing left to stop it. Removing config
  means the VPS registry and agent tokens go too, so a reinstall starts empty;
  `--keep-config` on Linux opts out.

- **No Linux icon.** There is only a Windows `.ico` in the repo, so the dash
  shows a generic placeholder. Exporting a PNG set later is a five-minute job
  and the install script would need three lines back.

- **No code signing.** Windows SmartScreen will warn on every download until
  the binary earns reputation on its own. The only real fix is a certificate,
  which costs money.

## Still open

1. **`StartupWMClass` is `com.example.beacle`.** That is the real value — it
   comes from `APPLICATION_ID` in `app/linux/CMakeLists.txt`, which
   `my_application.cc` hands to `g_set_prgname` — but it is still Flutter's
   placeholder. Renaming it to something real means changing both that and this
   line together, or GNOME stops matching the window to the entry.

2. **Config paths on Linux.** `app/lib/paths.dart` derives its directory from
   `APPDATA` and falls back to `$HOME/Beacle`, which is not where a Linux app
   keeps things. `uninstall.sh` clears both spellings for now;
   `~/.config/beacle` is the convention and the app should move to it.

3. **`--minimised` is Windows-only.** The flag is handled in the Windows
   runner. On Linux nothing reads it, and the tray it implies does not exist
   there either — see `app/lib/tray.dart`.

## Trying it by hand

```
# Windows — needs Inno Setup installed
iscc installer\windows\beacle.iss

# Linux desktop
bash installer/linux/install_app.sh
```

Both expect release assets that do not exist yet, so both will fail at the
download step. That is the next piece of work, not a bug.
