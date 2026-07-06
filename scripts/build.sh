#!/usr/bin/env bash
# Builds the full Beacle stack on Linux.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

echo '[1/4] backend'
(cd "$root/backend" && go build -o beacle-backend .)

echo '[2/4] agent (linux, native)'
(cd "$root/agent" && go build -o beacle-agent .)

echo '[3/4] agent (distribution binaries)'
mkdir -p "$root/backend/data/bin"
for arch in amd64 arm64; do
  (cd "$root/agent" && GOOS=linux GOARCH=$arch go build -o "$root/backend/data/bin/beacle-agent-linux-$arch" .)
done
"$root/agent/beacle-agent" -version > "$root/backend/data/bin/VERSION" 2>/dev/null || echo "0.1.0" > "$root/backend/data/bin/VERSION"

echo '[4/4] flutter desktop app'
(cd "$root/app" && flutter build linux --release)

echo "Done. Backend: backend/beacle-backend, app: app/build/linux/x64/release/bundle/beacle"
