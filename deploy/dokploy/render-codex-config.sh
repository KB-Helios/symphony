#!/usr/bin/env bash
set -euo pipefail

target=${1:?config path is required}
: "${OMNIROUTE_BASE_URL:?OMNIROUTE_BASE_URL is required}"
: "${SYMPHONY_MODEL:?SYMPHONY_MODEL is required}"

case "$OMNIROUTE_BASE_URL" in
  https://*) ;;
  *) echo "OMNIROUTE_BASE_URL must use https" >&2; exit 64 ;;
esac

toml_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

mkdir -p "$(dirname "$target")"
temporary="${target}.tmp"

cat >"$temporary" <<EOF
model_provider = "omniroute"
model = "$(toml_escape "$SYMPHONY_MODEL")"

[model_providers.omniroute]
name = "OmniRoute"
base_url = "$(toml_escape "$OMNIROUTE_BASE_URL")"
env_key = "OMNIROUTE_API_KEY"
wire_api = "responses"
request_max_retries = 4
stream_max_retries = 5
EOF

chmod 600 "$temporary"
mv -f "$temporary" "$target"
