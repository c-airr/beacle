#!/usr/bin/env bash
# Beacle VPS agent installer — downloads agent from the Beacle backend (local-first).
# Usage:
#   curl -fsSL http://<desktop-tailscale-ip>:8930/install | sudo bash
#   curl -fsSL http://<desktop-tailscale-ip>:8930/install | sudo bash -s http://<desktop-tailscale-ip>:8930
set -euo pipefail

BACKEND_URL="${1:-${BEACLE_BACKEND_URL:-}}"
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ -z "$BACKEND_URL" ]; then
  echo "beacle: pass backend URL: curl -fsSL http://100.x.x.x:8930/install | sudo bash -s http://100.x.x.x:8930" >&2
  exit 1
fi

BACKEND_URL="${BACKEND_URL%/}"

if [ "$(id -u)" -ne 0 ]; then
  echo "beacle: run as root (sudo)" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) AGENT_ARCH=amd64 ;;
  aarch64|arm64) AGENT_ARCH=arm64 ;;
  *)
    echo "beacle: unsupported CPU architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "[beacle] installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/versions"

echo "[beacle] downloading agent from $BACKEND_URL/download/agent?arch=$AGENT_ARCH"
curl -fsSL "$BACKEND_URL/download/agent?arch=$AGENT_ARCH" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"

echo "[beacle] writing config ($BACKEND_URL)"
cat > "$CONFIG" <<EOF
{
  "backend_url": "$BACKEND_URL"
}
EOF
chmod 600 "$CONFIG"

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

sleep 1
if systemctl is-active --quiet beacle-agent; then
  echo "[beacle] agent running — backend $BACKEND_URL"
  echo "[beacle] logs: journalctl -u beacle-agent -f"
else
  echo "[beacle] agent failed to start — check: journalctl -u beacle-agent -n 50 --no-pager" >&2
  exit 1
fi
