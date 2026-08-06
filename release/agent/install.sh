#!/usr/bin/env bash
# Deprecated name — use install_agent.sh.
# Kept so old one-liners keep working for one release cycle.
set -euo pipefail
echo "[beacle] note: install.sh is now install_agent.sh" >&2
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$DIR/install_agent.sh" ]; then
  exec bash "$DIR/install_agent.sh" "$@"
fi
# When piped from curl there is no sibling file — re-fetch the new script.
curl -fsSL "https://github.com/c-airr/beacle/releases/download/agentbeta/install_agent.sh" | bash -s -- "$@"
