package main

import (
	"fmt"

	"beacle/shared"
)

// vpsInstallCommand — curl install.sh from GitHub; backend URL is only agent config.
func vpsInstallCommand(backendURL string) string {
	return fmt.Sprintf("curl -fsSL %s | sudo bash -s %s", shared.AgentGitHubInstallURL(), backendURL)
}

// installScript keeps GET /install as a fallback mirror of the GitHub script.
func installScript(backendURL string) string {
	return fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
exec bash -s %q <<'INNER'
%s
INNER
`, backendURL, installScriptBody(backendURL))
}

func installScriptBody(backendURL string) string {
	amd := shared.AgentGitHubBinaryURL("amd64")
	arm := shared.AgentGitHubBinaryURL("arm64")
	return fmt.Sprintf(`BACKEND_URL=%q
AMD_URL=%q
ARM_URL=%q
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"
mkdir -p "$INSTALL_DIR/versions"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) AGENT_BIN="$ARM_URL" ;;
  *) AGENT_BIN="$AMD_URL" ;;
esac
echo "[beacle] downloading $AGENT_BIN"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
[ -f "$BIN" ] && cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
if [ ! -f "$CONFIG" ]; then
  printf '%%s\n' "{\"backend_url\":\"$BACKEND_URL\",\"report_interval_seconds\":3}" > "$CONFIG"
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
echo "[beacle] agent running — backend $BACKEND_URL"
`, backendURL, amd, arm)
}
