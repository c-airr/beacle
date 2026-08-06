#!/usr/bin/env bash
# Removes a Beacle desktop install. Uploaded next to install.sh on the release.
#
# Stops what is running first. The backend outlives the window on purpose (the
# panel adopts a running one on the next launch), so an uninstall that only
# deleted files would leave a headless backend holding port 9930 and every
# agent WebSocket, with nothing left on disk to stop it.
#
# Removes configuration as well, including the VPS registry and agent tokens.
# Pass --keep-config to leave those behind.
set -euo pipefail

KEEP_CONFIG=0
[ "${1:-}" = "--keep-config" ] && KEEP_CONFIG=1

echo "[beacle] stopping anything still running"
# SIGTERM first so the backend can close its sockets; the panel is a GUI app
# and will not be saving anything critical either way.
pkill -TERM -f '/beacle-backend' 2>/dev/null || true
pkill -TERM -x 'beacle' 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f '/beacle-backend' >/dev/null 2>&1 || pgrep -x 'beacle' >/dev/null 2>&1 || break
  sleep 0.3
done

pkill -KILL -f '/beacle-backend' 2>/dev/null || true
pkill -KILL -x 'beacle' 2>/dev/null || true

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

if [ "$KEEP_CONFIG" -eq 1 ]; then
  echo "[beacle] configuration kept"
else
  echo "[beacle] removing configuration and stored data"
  # Both spellings: the app derives its directory from APPDATA and falls back
  # to $HOME/Beacle, which is not where a Linux app belongs — see the note in
  # installer/README.md.
  rm -rf "$HOME/.config/beacle" "$HOME/.local/state/beacle" "$HOME/Beacle"
fi

echo "[beacle] done"
