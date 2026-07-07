package main

import "fmt"

const (
	agentBinaryURL   = "https://github.com/c-airr/beacle/releases/download/BETA/beacle-agent-amd"
	installScriptURL = "https://github.com/c-airr/beacle/releases/download/BETA/install.sh"
)

// vpsInstallCommand — curl from GitHub only; backend URL is just config for the agent.
func vpsInstallCommand(backendURL string) string {
	return fmt.Sprintf("curl -fsSL %s | sudo bash -s %s", installScriptURL, backendURL)
}

func installScript(backendURL string) string {
	return fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
exec bash -s %q <<'INNER'
%s
INNER
`, backendURL, installScriptBody(backendURL))
}

func installScriptBody(backendURL string) string {
	return fmt.Sprintf(`BACKEND_URL=%q
AGENT_BIN=%q
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"
mkdir -p "$INSTALL_DIR/versions"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
[ -f "$BIN" ] && cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
if [ ! -f "$CONFIG" ]; then
  printf '%%s\n' "{\"backend_url\":\"$BACKEND_URL\",\"report_interval_seconds\":5}" > "$CONFIG"
  chmod 600 "$CONFIG"
fi
cat > /etc/systemd/system/beacle-agent.service <<'SVCEOF'
[Unit]
Description=Beacle VPS Agent
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/beacle-agent/beacle-agent -config /opt/beacle-agent/config.json
Restart=always
RestartSec=3
User=root
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable beacle-agent
systemctl restart beacle-agent
echo "[beacle] agent running"
`, backendURL, agentBinaryURL)
}
