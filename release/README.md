# Release staging

Local folder with everything that goes on a GitHub Release.
Rebuild with: `powershell -File scripts/assemble-release.ps1`

## Upload checklist

Prefer the **Release** GitHub Action (`.github/workflows/release.yml`) over
hand-uploaded binaries. It builds on GitHub runners, writes `SHA256SUMS.txt`,
and attaches build-provenance attestations so downloads can be verified with
`gh attestation verify`.

### Desktop release (tag `0.9.1`)

| File | Upload as |
|---|---|
| `windows/beacle-windows-x64.zip` | `beacle-windows-x64.zip` |
| `windows/beacle-setup-0.9.1.exe` | `beacle-setup-0.9.1.exe` |
| `linux/install.sh` | `install.sh` (desktop) |
| `linux/uninstall.sh` | `uninstall.sh` |
| `linux/beacle-linux-x64.tar.gz` | **not built on Windows** — needs Linux or CI |

The Windows `.exe` installer downloads `beacle-windows-x64.zip` from
`releases/latest`. The zip contains frontend + backend + Flutter runtime.
VPS agents stay as separate release assets.

### VPS agent assets (on the same Latest release)

| File | Upload as |
|---|---|
| `agent/beacle-agent-amd64` | `beacle-agent-amd64` |
| `agent/beacle-agent-arm64` | `beacle-agent-arm64` |
| `agent/install_agent.sh` | `install_agent.sh` (VPS) |
| `agent/VERSION` | `VERSION` |

The Add VPS command always downloads `install_agent.sh` from
`releases/latest`; omitting it from the release breaks installation even when
both architecture binaries are present.

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
Use GitHub Actions (`.github/workflows/release.yml`) or a Linux box
with Flutter + `ninja` + `libgtk-3-dev`.
