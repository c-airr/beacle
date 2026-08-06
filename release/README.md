# Release staging — split layout

Rebuild: `powershell -File scripts/assemble-release.ps1`

## Model

| What | Where | How it gets installed |
|---|---|---|
| Desktop app (Win) | Latest: `beacle-windows-x64.zip` | `beacle-setup-*.exe` downloads it |
| Desktop app (Linux) | Latest: `beacle-linux-*.tar.gz` | `install_app.sh` detects arch |
| VPS agent | **agentbeta**: `beacle-agent-amd64` / `arm64` | `install_agent.sh` detects arch |

Flutter cannot be a single `.exe` (needs DLLs + `data/`), so the desktop
payload is still a zip/tar — but **without** agent binaries. Agents are
only on `agentbeta`.

macOS is not built yet.

## Upload checklist

### Latest (desktop) — tag e.g. `v0.9.0`, mark as Latest (not Pre-release)

| Local file | Asset name on GitHub |
|---|---|
| `windows/beacle-windows-x64.zip` | `beacle-windows-x64.zip` |
| `windows/beacle-setup-0.9.0.exe` | `beacle-setup-0.9.0.exe` |
| `linux/install_app.sh` | `install_app.sh` |
| `linux/uninstall.sh` | `uninstall.sh` |
| `linux/beacle-linux-x64.tar.gz` | when built on Linux/CI |

### agentbeta (VPS) — separate release, rolling

| Local file | Asset name on GitHub |
|---|---|
| `agent/beacle-agent-amd64` | `beacle-agent-amd64` |
| `agent/beacle-agent-arm64` | `beacle-agent-arm64` |
| `agent/install_agent.sh` | `install_agent.sh` |
| `agent/install.sh` | `install.sh` (compat alias) |

## One-liners

```bash
# Desktop Linux
curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install_app.sh | bash

# VPS agent (amd64 or arm64 auto)
curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/install_agent.sh \
  | sudo bash -s http://<desktop-tailscale-ip>:9930
```
