#!/usr/bin/env bash
# Beacle VPS agent — everything from GitHub release agentbeta.
# Usage:
#   curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/install.sh | sudo bash -s http://<desktop-tailscale-ip>:9930
set -euo pipefail

BACKEND_URL="${1:-${BEACLE_BACKEND_URL:-}}"
AMD_URL="https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-amd64"
ARM_URL="https://github.com/c-airr/beacle/releases/download/agentbeta/beacle-agent-arm64"
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ -z "$BACKEND_URL" ]; then
  echo "beacle: pass backend URL: curl -fsSL .../install.sh | sudo bash -s http://100.x.x.x:9930" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "beacle: run as root (sudo)" >&2
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) AGENT_BIN="$ARM_URL" ;;
  *) AGENT_BIN="$AMD_URL" ;;
esac

echo "[beacle] installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/versions"

echo "[beacle] downloading agent from GitHub ($ARCH)"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
# clear update stamp so next in-app update compares against fresh GitHub asset
rm -f "$INSTALL_DIR/versions/github.stamp"

if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<EOF
{
  "backend_url": "$BACKEND_URL",
  "report_interval_seconds": 3
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
