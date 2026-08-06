# Agent distribution — GitHub release [`agentbeta`](https://github.com/c-airr/beacle/releases/tag/agentbeta)

| Asset | URL |
|---|---|
| install_agent.sh | https://github.com/c-airr/beacle/releases/download/agentbeta/install_agent.sh |
| amd64 | https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-amd64 |
| arm64 | https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-arm64 |

`install_agent.sh` detects the VPS arch and downloads the matching binary.
Upload those three files (plus optional `install.sh` compat alias) to `agentbeta`.

```bash
curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/install_agent.sh \
  | sudo bash -s http://<desktop-tailscale-ip>:9930
```
