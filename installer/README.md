# Installer

The installer is wired into the build. `scripts/build.ps1` runs the Inno
Setup script when Inno Setup is installed, and `.github/workflows/release.yml`
builds Windows + Linux assets on GitHub runners, attaches build-provenance
attestations, and publishes the GitHub Release.

## What is here

| File | What it does |
|---|---|
| `windows/beacle.iss` | Inno Setup script. Downloads the payload from the GitHub release, installs per user, creates the Start Menu entry. |
| `linux/beacle.desktop` | Application entry. This is the file that makes GNOME find the app. |
| `linux/install.sh` | Downloads the payload, installs to `~/.local/share/beacle` or `/opt/beacle`, registers the entry and icons. |
| `linux/uninstall.sh` | Stops the app and backend, then removes both the install and the config. |
| `ci/build-installers.yml.draft` | Historical draft. The live workflow is `.github/workflows/release.yml`. |

## How it is meant to work

The installer people download is small and fetches the real payload from the
GitHub release. Desktop assets:

- `beacle-windows-x64.zip` — `beacle.exe`, `beacle-backend.exe`, Flutter runtime
- `beacle-linux-x64.tar.gz` — the same for Linux

VPS agents are **separate** release assets (`install_agent.sh`,
`beacle-agent-amd64`, `beacle-agent-arm64`), not baked into the desktop zip.

## Making the app findable

This was the point of the exercise, so it is worth being precise about what
actually does the work.

**Windows.** Windows Search indexes the Start Menu. A shortcut under
`{group}` is the whole mechanism — typing "beacle" finds it, and the user can
pin it from there. The `AppUserModelID` on the shortcut matters more than it
looks: without it, a pinned shortcut and the running window can end up as two
separate taskbar buttons, and the pin appears to do nothing.

**Linux.** The `.desktop` file is what GNOME / KDE / the application menu
indexes. `install.sh` installs it under `~/.local/share/applications` (or
`/usr/share/applications` with `--system`) and runs `update-desktop-database`.

## Uninstall

Uninstall stops `beacle` and `beacle-backend`, then removes the install dir and
the config dir. A reinstall therefore starts clean.

## Local build

```powershell
# Windows: needs Inno Setup 6
powershell -File scripts/build.ps1
powershell -File scripts/assemble-release.ps1
```

Prefer cutting a real release with a git tag so GitHub Actions builds and
attests the binaries:

```bash
git tag 0.9.1
git push origin 0.9.1
```
