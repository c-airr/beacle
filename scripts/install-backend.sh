#!/usr/bin/env bash
# Deploy the Beacle backend on a Linux VPS (control plane).
# Run once on YOUR server (Oracle, Hetzner, …). Desktop users only open the panel app.
#
#   curl -sSL https://raw.githubusercontent.com/YOU/beacle/main/scripts/install-backend.sh | sudo bash
#   # or after git clone:
#   sudo BEACLE_PUBLIC_URL=https://panel.example.com bash scripts/install-backend.sh
#
set -euo pipefail

INSTALL_DIR=/opt/beacle-backend
DATA_DIR="$INSTALL_DIR/data"
SERVICE=/etc/systemd/system/beacle-backend.service

if [ "$(id -u)" -ne 0 ]; then
  echo "beacle: run as root (sudo)" >&2
  exit 1
fi

if [ -z "${BEACLE_PUBLIC_URL:-}" ]; then
  echo "beacle: set BEACLE_PUBLIC_URL (public URL of this backend, e.g. https://beacle.example.com)" >&2
  echo "  export BEACLE_PUBLIC_URL=https://your-domain-or-ip:8930" >&2
  exit 1
fi
BEACLE_PUBLIC_URL="${BEACLE_PUBLIC_URL%/}"

echo "[beacle] installing backend to $INSTALL_DIR"
mkdir -p "$DATA_DIR/bin"

# Binary: use repo build if present, else expect pre-built next to script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT/backend/beacle-backend"
if [ ! -f "$SRC_BIN" ] && [ -f "$ROOT/backend/beacle-backend.exe" ]; then
  echo "beacle: Linux binary not found — build on Linux: cd backend && go build -o beacle-backend ." >&2
  exit 1
fi
if [ -f "$SRC_BIN" ]; then
  cp -f "$SRC_BIN" "$INSTALL_DIR/beacle-backend"
else
  echo "beacle: place beacle-backend binary in $ROOT/backend/ or build from source" >&2
  exit 1
fi
chmod +x "$INSTALL_DIR/beacle-backend"

# Agent binaries for /download/agent (build if missing)
if [ ! -f "$DATA_DIR/bin/beacle-agent-linux-amd64" ]; then
  echo "[beacle] building agent binaries for distribution…"
  (cd "$ROOT/agent" && GOOS=linux GOARCH=amd64 go build -o "$DATA_DIR/bin/beacle-agent-linux-amd64" .)
  (cd "$ROOT/agent" && GOOS=linux GOARCH=arm64 go build -o "$DATA_DIR/bin/beacle-agent-linux-arm64" .)
  echo "0.1.0" > "$DATA_DIR/bin/VERSION"
fi

echo "[beacle] writing systemd unit"
cat > "$SERVICE" <<EOF
[Unit]
Description=Beacle Backend (control plane)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
Environment=BEACLE_PUBLIC_URL=$BEACLE_PUBLIC_URL
ExecStart=$INSTALL_DIR/beacle-backend -addr :8930 -data $DATA_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable beacle-backend
systemctl restart beacle-backend

echo ""
echo "[beacle] backend running at $BEACLE_PUBLIC_URL"
echo "[beacle] health: curl -s $BEACLE_PUBLIC_URL/api/health"
echo "[beacle] add VPS (on each managed server): curl -sSL $BEACLE_PUBLIC_URL/install | sudo bash"
echo "[beacle] desktop panel: set beacle.config.json -> {\"backend_url\": \"$BEACLE_PUBLIC_URL\"}"
