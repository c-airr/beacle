#!/usr/bin/env bash
# Removes a Beacle desktop install. NOT WIRED UP YET — see installer/README.md.
#
# Config is kept unless --purge is passed: ~/.config/beacle holds the VPS
# registry and the agent tokens, and reinstalling to find those gone would be
# a worse surprise than a leftover directory.
set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

for prefix in "/opt/beacle" "$HOME/.local/share/beacle"; do
  [ -d "$prefix" ] || continue
  echo "[beacle] removing $prefix"
  rm -rf "$prefix"
done

for dir in "/usr/share/applications" "$HOME/.local/share/applications"; do
  [ -f "$dir/beacle.desktop" ] || continue
  echo "[beacle] removing $dir/beacle.desktop"
  rm -f "$dir/beacle.desktop"
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$dir" 2>/dev/null || true
done

for theme in "/usr/share/icons/hicolor" "$HOME/.local/share/icons/hicolor"; do
  [ -d "$theme" ] || continue
  find "$theme" -name 'beacle.png' -delete 2>/dev/null || true
done

if [ "$PURGE" -eq 1 ]; then
  echo "[beacle] removing configuration"
  rm -rf "$HOME/.config/beacle" "$HOME/.local/state/beacle"
else
  echo "[beacle] configuration kept in ~/.config/beacle (use --purge to remove)"
fi

echo "[beacle] done"
