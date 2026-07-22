# Agent distribution — GitHub release [`agentbeta`](https://github.com/c-airr/beacle/releases/tag/agentbeta)

| Asset | URL |
|-------|-----|
| install.sh | https://github.com/c-airr/beacle/releases/download/agentbeta/install.sh |
| amd64 | https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-amd64 |
| arm64 | https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-arm64 |

Upload `install.sh`, `beacle-agent-amd64`, `beacle-agent-arm64` to that release.

## Install / reinstall (from GitHub only)

```bash
curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/install.sh | sudo bash -s http://<desktop-tailscale-ip>:9930
```

## Manual binary refresh (no in-app Update)

```bash
# amd64
sudo bash -c 'curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-amd64 -o /opt/beacle-agent/beacle-agent.new && chmod +x /opt/beacle-agent/beacle-agent.new && mkdir -p /opt/beacle-agent/versions && cp -f /opt/beacle-agent/beacle-agent /opt/beacle-agent/versions/beacle-agent.prev 2>/dev/null; mv -f /opt/beacle-agent/beacle-agent.new /opt/beacle-agent/beacle-agent && rm -f /opt/beacle-agent/versions/github.stamp && systemctl restart beacle-agent'
```
