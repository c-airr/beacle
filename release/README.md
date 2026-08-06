# Release staging

Local folder with everything that goes on a GitHub Release.
Rebuild with: `powershell -File scripts/assemble-release.ps1`

## Upload checklist

### Desktop release (tag `v0.9.0` / branch `0.9-beta`)

Installer always fetches from `releases/latest` — upload these assets
so that latest points at this release:

| File | Upload as |
|---|---|
| `windows/beacle-windows-x64.zip` | `beacle-windows-x64.zip` |
| `windows/beacle-setup-0.9.0.exe` | `beacle-setup-0.9.0.exe` |
| `linux/install.sh` | `install.sh` (desktop) |
| `linux/uninstall.sh` | `uninstall.sh` |
| `linux/beacle-linux-x64.tar.gz` | **not built on Windows** — needs Linux or CI |

The Windows `.exe` installer downloads `beacle-windows-x64.zip` from
`releases/latest`. The zip already contains frontend + backend + Flutter
runtime + agent binaries under `data/bin/`.

### Agent release (tag `agentbeta`, separate)

| File | Upload as |
|---|---|
| `agent/beacle-agent-amd64` | `beacle-agent-amd64` |
| `agent/beacle-agent-arm64` | `beacle-agent-arm64` |
| `agent/install.sh` | `install.sh` (VPS) |

## Linux desktop status

The Flutter Linux port **exists** (`app/linux/`) and CI can build it, but it
is roughly **~60%** of a polished Windows peer:

Works: GTK window, core panel UI, backend binary name, CI packaging, GNOME
`.desktop` install/uninstall scripts.

Missing / unfinished:
- tray (Windows-only)
- autostart (Windows-only)
- config paths (`$HOME/Beacle` instead of XDG `~/.config/beacle`)
- app icon PNG
- alert sound
- in-app self-update apply (`.bat` / `robocopy` — Windows-only)
- `APPLICATION_ID` still `com.example.beacle`

You **cannot** build `beacle-linux-x64.tar.gz` on this Windows machine.
Use GitHub Actions (`.github/workflows/build-installers.yml`) or a Linux box
with Flutter + `ninja` + `libgtk-3-dev`.
