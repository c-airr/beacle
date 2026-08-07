# Agent distribution — GitHub [Latest](https://github.com/c-airr/beacle/releases/latest)

| Asset | URL |
|-------|-----|
| install_agent.sh | https://github.com/c-airr/beacle/releases/latest/download/install_agent.sh |
| amd64 | https://github.com/c-airr/beacle/releases/latest/download/beacle-agent-amd64 |
| arm64 | https://github.com/c-airr/beacle/releases/latest/download/beacle-agent-arm64 |

Upload `install_agent.sh` (and optionally the compat alias `install.sh`), `beacle-agent-amd64`, `beacle-agent-arm64` to the release marked Latest. The installer detects arch and pulls the matching binary.

## Install / reinstall

```bash
curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install_agent.sh | sudo bash -s http://<desktop-tailscale-ip>:9930
```
