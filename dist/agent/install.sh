#!/usr/bin/env bash
# Beacle VPS agent installer — host on GitHub Releases (BETA/install.sh).
# Usage: curl -fsSL https://github.com/c-airr/beacle/releases/download/BETA/install.sh | sudo bash -s http://<desktop-tailscale-ip>:8930
set -euo pipefail

BACKEND_URL="${1:-${BEACLE_BACKEND_URL:-}}"
AGENT_BIN="https://github.com/c-airr/beacle/releases/download/BETA/beacle-agent-amd"
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ -z "$BACKEND_URL" ]; then
  echo "beacle: pass backend URL: curl -fsSL .../install.sh | sudo bash -s http://100.x.x.x:8930" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "beacle: run as root (sudo)" >&2
  exit 1
fi

echo "[beacle] installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/versions"

echo "[beacle] downloading agent from GitHub"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"

if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<EOF
{
  "backend_url": "$BACKEND_URL",
  "report_interval_seconds": 5
}
EOF
  chmod 600 "$CONFIG"
else
  echo "[beacle] keeping existing config"
fi

cat > /etc/systemd/system/beacle-agent.service <<'EOF'
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
EOF

systemctl daemon-reload
systemctl enable beacle-agent
systemctl restart beacle-agent

echo "[beacle] agent running — backend $BACKEND_URL"
