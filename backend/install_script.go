package main

import (
	"fmt"
	"net/http"
	"strings"

	"beacle/shared"
)

// vpsInstallCommand is the Tailscale one-liner. WireGuard installs use
// wireGuardInstallCommand (the same GitHub script with --wg <token>).
func vpsInstallCommand(backendURL string) string {
	return fmt.Sprintf("curl -fsSL %s | sudo bash -s -- %s", shared.AgentGitHubInstallURL(), backendURL)
}

// installScript keeps GET /install as a fallback mirror of dist/agent/install_agent.sh
// (Tailscale and --wg). The panel's primary install URLs still point at GitHub;
// this path is for when Latest is unreachable or someone curls the local panel.
func installScript(backendURL string) string {
	return fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
exec bash -s -- %q <<'INNER'
%s
INNER
`, backendURL, installScriptBody())
}

func installScriptWG(join string) string {
	return fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
exec bash -s -- --wg %q <<'INNER'
%s
INNER
`, join, installScriptBody())
}

func installScriptBody() string {
	amd := shared.AgentGitHubLatestBinaryURL("amd64")
	arm := shared.AgentGitHubLatestBinaryURL("arm64")
	// Keep in sync with dist/agent/install_agent.sh — same modes, port check,
	// firewall allow and GOMEMLIMIT unit. AMD/ARM URLs are baked in so the
	// mirror still works if GitHub Latest redirects change.
	return fmt.Sprintf(`AMD_URL=%q
ARM_URL=%q
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
INSTALL_DIR=/opt/beacle-agent
CONFIG="$INSTALL_DIR/config.json"
BIN="$INSTALL_DIR/beacle-agent"

if [ "$MODE" = tailscale ] && [ -z "$BACKEND_URL" ]; then
  echo "beacle: pass backend URL: curl -fsSL .../install | sudo bash -s -- http://100.x.x.x:9930" >&2
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

echo "[beacle] downloading agent ($ARCH)"
curl -fsSL "$AGENT_BIN" -o "$INSTALL_DIR/beacle-agent.new"
chmod +x "$INSTALL_DIR/beacle-agent.new"
if [ -f "$BIN" ]; then
  cp -f "$BIN" "$INSTALL_DIR/versions/beacle-agent.prev"
fi
mv -f "$INSTALL_DIR/beacle-agent.new" "$BIN"
rm -f "$INSTALL_DIR/versions/github.stamp"

if [ "$MODE" = wireguard ]; then
  systemctl stop beacle-agent 2>/dev/null || true
  if ! WG_PORT="$("$BIN" -config "$CONFIG" -join "$JOIN")"; then
    echo "beacle: could not apply the join token (copy the whole command again from Beacle)" >&2
    systemctl start beacle-agent 2>/dev/null || true
    exit 1
  fi
  if command -v ss >/dev/null 2>&1 && ss -uln | awk '{print $4}' | grep -Eq "[:.]$WG_PORT\$"; then
    echo "beacle: UDP port $WG_PORT is already in use:" >&2
    ss -ulnp 2>/dev/null | grep -E "[:.]$WG_PORT[[:space:]]" >&2 || true
    echo "beacle: free it, or add the server again in Beacle with another port" >&2
    exit 1
  fi
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
  if ! grep -Fq "\"backend_url\": \"$BACKEND_URL\"" "$CONFIG"; then
    echo "beacle: backend_url verification failed; refusing to start with stale config" >&2
    exit 1
  fi
  AFTER="network-online.target tailscaled.service"
fi

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
`, amd, arm)
}

// handleInstallScript serves the mirrored installer. Default = Tailscale with
// the panel's backend URL baked as $1. ?wg=<join> = WireGuard mode.
func (s *Server) handleInstallScript(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/x-shellscript")
	if join := strings.TrimSpace(r.URL.Query().Get("wg")); join != "" {
		_, _ = w.Write([]byte(installScriptWG(join)))
		return
	}
	_, _ = w.Write([]byte(installScript(s.backendURL())))
}
