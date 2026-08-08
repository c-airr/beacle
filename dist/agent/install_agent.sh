#!/usr/bin/env bash
# Beacle VPS agent installer.
# Detects amd64/arm64, downloads the matching binary from GitHub Latest,
# installs under /opt/beacle-agent and registers a systemd unit.
#
# Usage:
#   curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install_agent.sh \
#     | sudo bash -s -- http://<desktop-tailscale-ip>:9930
set -euo pipefail

BACKEND_URL="${1:-${BEACLE_BACKEND_URL:-}}"
BASE="https://github.com/c-airr/beacle/releases/latest/download"
AMD_URL="$BASE/beacle-agent-amd64"
ARM_URL="$BASE/beacle-agent-arm64"
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ -z "$BACKEND_URL" ]; then
  echo "beacle: pass backend URL: curl -fsSL .../install_agent.sh | sudo bash -s -- http://100.x.x.x:9930" >&2
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

echo "[beacle] downloading agent from GitHub Latest ($ARCH)"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
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
  # Reinstall means "use the URL the user just supplied". Keep credentials
  # assigned by the backend, but never silently keep an obsolete host/port.
  echo "[beacle] updating backend_url in existing config"
  if command -v python3 >/dev/null 2>&1; then
    BACKEND_URL="$BACKEND_URL" CONFIG="$CONFIG" python3 - <<'PY'
import json, os
path = os.environ["CONFIG"]
url = os.environ["BACKEND_URL"]
with open(path) as f:
    cfg = json.load(f)
cfg["backend_url"] = url
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  elif command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg url "$BACKEND_URL" '.backend_url = $url' "$CONFIG" > "$tmp"
    cat "$tmp" > "$CONFIG"
    rm -f "$tmp"
  else
    echo "beacle: cannot safely update existing config (python3 or jq required)" >&2
    echo "beacle: install python3, or remove $CONFIG and run this installer again" >&2
    exit 1
  fi
  chmod 600 "$CONFIG"
fi

# Do not print a successful install while the agent is still configured for
# another port. Both writers above produce this exact JSON key/value pair.
if ! grep -Fq "\"backend_url\": \"$BACKEND_URL\"" "$CONFIG"; then
  echo "beacle: backend_url verification failed; refusing to start with stale config" >&2
  exit 1
fi

cat > /etc/systemd/system/beacle-agent.service <<'EOF'
[Unit]
Description=Beacle VPS Agent
After=network-online.target tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=0

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

echo "[beacle] agent running — configured backend $BACKEND_URL"
