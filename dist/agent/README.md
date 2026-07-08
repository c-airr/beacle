# Beacle agent (Linux)

Install on a VPS in your Tailscale tailnet:

```bash
curl -fsSL http://<desktop-tailscale-ip>:8930/install | sudo bash
```

The install script and agent binary are served by the Beacle desktop backend.
No GitHub release required.

After install:

```bash
systemctl status beacle-agent
journalctl -u beacle-agent -f
```

Agent config: `/opt/beacle-agent/config.json`
