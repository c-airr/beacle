#!/usr/bin/env bash
# Deprecated — use install_app.sh for the desktop app.
set -euo pipefail
echo "[beacle] note: install.sh is now install_app.sh" >&2
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$DIR/install_app.sh" ]; then
  exec bash "$DIR/install_app.sh" "$@"
fi
curl -fsSL "https://github.com/c-airr/beacle/releases/latest/download/install_app.sh" | bash -s -- "$@"
