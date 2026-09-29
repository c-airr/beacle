#!/usr/bin/env bash
# Beacle VPS agent installer.
# Detects amd64/arm64, downloads the matching binary from GitHub Latest,
# installs under /opt/beacle-agent and registers a systemd unit.
#
# Usage (Tailscale):
#   curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install_agent.sh \
#     | sudo bash -s -- http://<desktop-tailscale-ip>:9930
# Usage (WireGuard, token from the panel's Add server dialog):
#   curl -fsSL .../install_agent.sh | sudo bash -s -- --wg bcwg1.…
set -euo pipefail

MODE=tailscale
JOIN=""
BACKEND_URL=""
if [ "${1:-}" = "--wg" ]; then
  MODE=wireguard
  JOIN="${2:-}"
  if [ -z "$JOIN" ]; then
    echo "beacle: --wg needs the join token from the panel" >&2
    exit 1
  fi
else
  BACKEND_URL="${1:-${BEACLE_BACKEND_URL:-}}"
fi
BASE="https://github.com/c-airr/beacle/releases/latest/download"
AMD_URL="$BASE/beacle-agent-amd64"
ARM_URL="$BASE/beacle-agent-arm64"
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ "$MODE" = tailscale ] && [ -z "$BACKEND_URL" ]; then
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
chmod 700 "$INSTALL_DIR"

echo "[beacle] downloading agent from GitHub Latest ($ARCH)"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
rm -f "$INSTALL_DIR/versions/github.stamp"

if [ "$MODE" = wireguard ]; then
  # The running agent may hold the tunnel port from an earlier install.
  systemctl stop beacle-agent 2>/dev/null || true
  # The agent writes its own config from the token (0600, other settings
  # kept) and prints the UDP port it will listen on.
  if ! WG_PORT="$("$BIN" -config "$CONFIG" -join "$JOIN")"; then
    echo "beacle: could not apply the join token (copy the whole command again from Beacle)" >&2
    # The config was not touched; bring back whatever was running before.
    systemctl start beacle-agent 2>/dev/null || true
    exit 1
  fi
  if command -v ss >/dev/null 2>&1 && ss -uln | awk '{print $4}' | grep -Eq "[:.]$WG_PORT\$"; then
    echo "beacle: UDP port $WG_PORT is already in use:" >&2
    ss -ulnp 2>/dev/null | grep -E "[:.]$WG_PORT[[:space:]]" >&2 || true
    echo "beacle: free it, or add the server again in Beacle with another port" >&2
    exit 1
  fi
  # Only the handshake port is opened. It answers nothing to anyone who
  # does not hold the panel's key — not even a reply to a port scan.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "[beacle] ufw: allowing $WG_PORT/udp"
    ufw allow "$WG_PORT/udp" comment "beacle wireguard" >/dev/null
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "[beacle] firewalld: allowing $WG_PORT/udp"
    firewall-cmd --quiet --permanent --add-port="$WG_PORT/udp"
    firewall-cmd --quiet --reload
  fi
  AFTER="network-online.target"
else
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
    # Going back to Tailscale also drops the WireGuard section.
    echo "[beacle] updating backend_url in existing config"
    if command -v python3 >/dev/null 2>&1; then
      BACKEND_URL="$BACKEND_URL" CONFIG="$CONFIG" python3 - <<'PY'
import json, os
path = os.environ["CONFIG"]
url = os.environ["BACKEND_URL"]
with open(path) as f:
    cfg = json.load(f)
cfg["backend_url"] = url
for k in ("transport", "wireguard", "fallback_backend_url", "fallback_until"):
    cfg.pop(k, None)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
    elif command -v jq >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq --arg url "$BACKEND_URL" '.backend_url = $url | del(.transport, .wireguard, .fallback_backend_url, .fallback_until)' "$CONFIG" > "$tmp"
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
  AFTER="network-online.target tailscaled.service"
fi

# GOMEMLIMIT is a soft ceiling: the GC works harder near it instead of the
# heap growing into the memory a small VPS needs for its actual workload.
cat > /etc/systemd/system/beacle-agent.service <<EOF
[Unit]
Description=Beacle VPS Agent
After=$AFTER
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/beacle-agent/beacle-agent -config /opt/beacle-agent/config.json
Environment=GOMEMLIMIT=32MiB
Environment=GOGC=50
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable beacle-agent
systemctl restart beacle-agent

if [ "$MODE" = wireguard ]; then
  echo "[beacle] agent running — waiting for the panel on udp/$WG_PORT"
  echo "[beacle] if your provider has its own firewall (security group), allow UDP $WG_PORT there too"
else
  echo "[beacle] agent running — configured backend $BACKEND_URL"
fi
