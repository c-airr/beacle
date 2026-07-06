package main

import (
	"fmt"

	"beacle/shared"
)

func installScriptWithToken(baseURL, pairingToken string) string {
	return fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail

BACKEND_URL=%q
PAIRING_TOKEN=%q
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ "$(id -u)" -ne 0 ]; then
  echo "beacle: run as root (sudo)" >&2
  exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "beacle: unsupported arch $ARCH" >&2; exit 1 ;;
esac

echo "[beacle] installing agent to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/versions"

echo "[beacle] downloading agent ($ARCH)"
curl -fsSL "$BACKEND_URL/download/agent?arch=$ARCH" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"

if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<EOF
{
  "backend_url": "$BACKEND_URL",
  "pairing_token": "$PAIRING_TOKEN",
  "report_interval_seconds": 5
}
EOF
  chmod 600 "$CONFIG"
else
  echo "[beacle] config exists - keeping untouched"
fi

echo "[beacle] writing pairing config..."
"$BIN" set "$PAIRING_TOKEN" --backend "$BACKEND_URL" --write-only

echo "[beacle] creating systemd service"
cat > /etc/systemd/system/beacle-agent.service <<'SVCEOF'
[Unit]
Description=Beacle VPS Agent
After=network-online.target
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

echo "[beacle] agent running — VPS will appear in your panel."
`, baseURL, pairingToken)
}

func (s *Server) checkHubAlert() {
	hubID, _ := s.store.HubInfo()
	if hubID != "" {
		return
	}
	a := s.store.AddAlert(shared.Alert{
		Type:     shared.AlertHubMissing,
		Severity: shared.SeverityWarning,
		Message:  "No hub node with public IP. Add a cloud VPS to enable agent networking.",
		VPSName:  "network",
	})
	s.hub.Broadcast(shared.WSAlert, a)
}
