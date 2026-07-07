# Agent binary (VPS, amd64)

**Agent download:**
```
https://github.com/c-airr/beacle/releases/download/BETA/beacle-agent-amd
```

**Install script:**
```
https://github.com/c-airr/beacle/releases/download/BETA/install.sh
```

Upload both to the GitHub **BETA** release.

## Install from Beacle app

After adding a VPS, copy the install command shown in the app:

```bash
curl -fsSL https://github.com/c-airr/beacle/releases/download/BETA/install.sh | sudo bash -s http://<your-tailscale-ip>:8930
```

Curl hits GitHub only. The Tailscale IP is just the agent's `backend_url` config (your desktop), not the download host.

Build local copy: `.\scripts\build.ps1`
