#!/usr/bin/env bash
# Beacle desktop app installer for Linux.
# Detects arch and pulls the matching payload from releases/latest.
# (Flutter needs a whole bundle — not a single binary — so this is a tar.gz.)
#
# Usage:
#   curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install_app.sh | bash
#   sudo bash install_app.sh --system     # /opt, all users
set -euo pipefail

REPO="c-airr/beacle"
APP_ID="beacle"
SYSTEM_WIDE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --system) SYSTEM_WIDE=1 ;;
    -h|--help)
      echo "usage: install_app.sh [--system]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ASSET="beacle-linux-x64.tar.gz" ;;
  aarch64|arm64) ASSET="beacle-linux-arm64.tar.gz" ;;
  *)
    echo "beacle: unsupported arch '$ARCH' (need x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

if [ "$SYSTEM_WIDE" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "beacle: --system needs root" >&2; exit 1; }
  PREFIX=/opt/beacle
  DESKTOP_DIR=/usr/share/applications
else
  PREFIX="$HOME/.local/share/beacle"
  DESKTOP_DIR="$HOME/.local/share/applications"
fi

URL="https://github.com/$REPO/releases/latest/download/$ASSET"

echo "[beacle] downloading $ASSET ($ARCH)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! curl -fL --progress-bar "$URL" -o "$TMP/$ASSET"; then
  echo "beacle: could not download $ASSET from latest release." >&2
  echo "        Upload that asset (app + backend, no agents) to the Latest release." >&2
  exit 1
fi

echo "[beacle] installing to $PREFIX"
mkdir -p "$PREFIX"
tar -xzf "$TMP/$ASSET" -C "$PREFIX" --strip-components=1
chmod +x "$PREFIX/beacle" "$PREFIX/beacle-backend" 2>/dev/null || true

echo "[beacle] registering the application entry"
mkdir -p "$DESKTOP_DIR"
sed -e "s|^Exec=/opt/beacle/beacle|Exec=$PREFIX/beacle|" \
    -e "s|^Exec=/opt/beacle/beacle --minimised|Exec=$PREFIX/beacle --minimised|" \
    "$(dirname "$0")/beacle.desktop" > "$DESKTOP_DIR/$APP_ID.desktop" 2>/dev/null \
  || curl -fsSL "https://raw.githubusercontent.com/$REPO/main/installer/linux/beacle.desktop" \
     | sed "s|/opt/beacle/beacle|$PREFIX/beacle|g" > "$DESKTOP_DIR/$APP_ID.desktop"
chmod 644 "$DESKTOP_DIR/$APP_ID.desktop"

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

echo
echo "[beacle] installed to $PREFIX"
echo "         press Super and type 'beacle', or run $PREFIX/beacle"
echo "         VPS agent (separate): curl -fsSL .../agentbeta/install_agent.sh | sudo bash -s http://<ip>:9930"
