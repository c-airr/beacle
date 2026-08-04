# Installer — groundwork

Nothing here is wired up. `scripts/build.ps1` does not know this directory
exists, no workflow runs it, and no application code imports it. It is a draft
of how installing Beacle should work, written so the shape can be argued with
before any of it goes live.

## What is here

| File | What it does |
|---|---|
| `windows/beacle.iss` | Inno Setup script. Downloads the payload from the GitHub release, installs per user, creates the Start Menu entry. |
| `linux/beacle.desktop` | Application entry. This is the file that makes GNOME find the app. |
| `linux/install.sh` | Downloads the payload, installs to `~/.local/share/beacle` or `/opt/beacle`, registers the entry and icons. |
| `linux/uninstall.sh` | Removes it again, keeping config unless `--purge`. |
| `ci/build-installers.yml.draft` | GitHub Actions draft. Deliberately **not** in `.github/workflows/`, so it does not run. |

## How it is meant to work

The installer people download is small and fetches the real payload from the
GitHub release. Two assets per release:

- `beacle-windows-x64.zip` — `beacle.exe`, `beacle-backend.exe`,
  `flutter_windows.dll`, `data/` including the agent binaries
- `beacle-linux-x64.tar.gz` — the same for Linux

That split means shipping a new build is uploading a new asset, not rebuilding
and re-signing an installer.

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

## Open questions — answer these before activating anything

1. **Icons for Linux.** `install.sh` copies PNGs from `icons/` in the payload
   at sizes 16–512. Those files do not exist; there is only
   `app/windows/runner/resources/app_icon.ico`. Either export a set of PNGs or
   drop the icon step and accept a generic icon in the dash.

2. **`StartupWMClass`.** Set to `beacle` as a guess. It has to be checked
   against what the built Linux app actually reports (`xprop WM_CLASS`) or
   pinning misbehaves in exactly the way described above.

3. **`--minimised` on Linux.** The desktop entry offers a "Start in the
   background" action, but the flag is only handled in the Windows runner. On
   Linux it is currently ignored, and the tray it implies does not exist there
   either — see the tray note in `app/lib/tray.dart`.

4. **Config paths on Linux.** `uninstall.sh` removes `~/.config/beacle`, but
   `app/lib/paths.dart` derives its directory from `APPDATA` and falls back to
   `$HOME/Beacle`. One of the two has to move; `~/.config/beacle` is the
   convention.

5. **Versioning.** `beacle.iss` hardcodes `0.1.0` and the tag `v0.1.0` in three
   places. It should read them from `app/pubspec.yaml`, or CI should pass them
   in with `iscc /DAppVersion=...`.

6. **Signing.** Unsigned, so Windows SmartScreen will warn on every download
   until the binary builds reputation. A certificate is the only real fix and
   costs money; worth deciding before the first public release rather than
   after people start reporting it as a virus.

## Trying it by hand

```
# Windows — needs Inno Setup installed
iscc installer\windows\beacle.iss

# Linux
bash installer/linux/install.sh
```

Both expect release assets that do not exist yet, so both will fail at the
download step. That is the next piece of work, not a bug.
