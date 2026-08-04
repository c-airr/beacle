#!/usr/bin/env bash
# Beacle desktop installer for Linux.
#
# NOT WIRED UP YET. Nothing builds or publishes this; it is here so the shape
# of the Linux install can be reviewed before it goes live.
#
# Usage (once the release assets exist):
#   curl -fsSL https://github.com/c-airr/beacle/releases/latest/download/install-desktop.sh | bash
#   sudo ./install.sh --system     # /opt, all users
#
# Defaults to a per-user install under ~/.local, which needs no root and is
# what most people want on a workstation. Either way the app ends up in the
# GNOME overview: press Super, type "beacle", and it is there — that comes from
# the .desktop entry, not from anything the app does at runtime.
set -euo pipefail

REPO="c-airr/beacle"
ASSET="beacle-linux-x64.tar.gz"
APP_ID="beacle"

SYSTEM_WIDE=0
VERSION="latest"

while [ $# -gt 0 ]; do
  case "$1" in
    --system)  SYSTEM_WIDE=1 ;;
    --version) VERSION="${2:-latest}"; shift ;;
    -h|--help)
      echo "usage: install.sh [--system] [--version vX.Y.Z]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$SYSTEM_WIDE" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "beacle: --system needs root" >&2; exit 1; }
  PREFIX=/opt/beacle
  DESKTOP_DIR=/usr/share/applications
  ICON_DIR=/usr/share/icons/hicolor
else
  PREFIX="$HOME/.local/share/beacle"
  DESKTOP_DIR="$HOME/.local/share/applications"
  ICON_DIR="$HOME/.local/share/icons/hicolor"
fi

if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
fi

echo "[beacle] downloading $ASSET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar "$URL" -o "$TMP/$ASSET"

echo "[beacle] installing to $PREFIX"
mkdir -p "$PREFIX"
# --strip-components drops the archive's top-level folder so upgrades land on
# top of the previous install instead of nesting inside it.
tar -xzf "$TMP/$ASSET" -C "$PREFIX" --strip-components=1
chmod +x "$PREFIX/beacle" "$PREFIX/beacle-backend" 2>/dev/null || true

echo "[beacle] registering the application entry"
mkdir -p "$DESKTOP_DIR"
# Exec is rewritten because the prefix differs between the two install modes,
# and a .desktop file pointing at the wrong path is an icon that does nothing.
sed -e "s|^Exec=/opt/beacle/beacle|Exec=$PREFIX/beacle|" \
    -e "s|^Exec=/opt/beacle/beacle --minimised|Exec=$PREFIX/beacle --minimised|" \
    "$(dirname "$0")/beacle.desktop" > "$DESKTOP_DIR/$APP_ID.desktop" 2>/dev/null \
  || curl -fsSL "https://raw.githubusercontent.com/$REPO/main/installer/linux/beacle.desktop" \
     | sed "s|/opt/beacle/beacle|$PREFIX/beacle|g" > "$DESKTOP_DIR/$APP_ID.desktop"
chmod 644 "$DESKTOP_DIR/$APP_ID.desktop"

# Icons go in the hicolor theme at the sizes GNOME actually asks for. A single
# oversized PNG dumped in pixmaps renders blurry in the dash.
if [ -d "$PREFIX/icons" ]; then
  for size in 16 24 32 48 64 128 256 512; do
    src="$PREFIX/icons/${size}x${size}.png"
    [ -f "$src" ] || continue
    dest="$ICON_DIR/${size}x${size}/apps"
    mkdir -p "$dest"
    cp -f "$src" "$dest/$APP_ID.png"
  done
fi

# Without these the entry can take a logout to appear in search.
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

echo
echo "[beacle] installed to $PREFIX"
echo "         press Super and type 'beacle', or run $PREFIX/beacle"
echo "         to pin it: right-click the icon in the dash -> Add to Favourites"
