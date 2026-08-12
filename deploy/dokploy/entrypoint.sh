#!/usr/bin/env bash
set -euo pipefail

: "${SECRET_KEY_BASE:?SECRET_KEY_BASE is required}"
: "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
: "${OMNIROUTE_API_KEY:?OMNIROUTE_API_KEY is required}"
: "${OMNIROUTE_BASE_URL:?OMNIROUTE_BASE_URL is required}"
: "${SYMPHONY_MODEL:?SYMPHONY_MODEL is required}"

if (( ${#SECRET_KEY_BASE} < 64 )); then
  echo "SECRET_KEY_BASE must be at least 64 characters" >&2
  exit 64
fi

install -d -m 700 \
  /var/lib/symphony/state \
  /var/lib/symphony/workspaces \
  "$CODEX_HOME"

/app/deploy/dokploy/render-codex-config.sh "$CODEX_HOME/config.toml"

exec flock --exclusive --nonblock \
  /var/lib/symphony/state/controller.lock \
  /app/bin/symphony start
