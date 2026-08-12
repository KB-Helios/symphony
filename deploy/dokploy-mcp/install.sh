#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -un)" != "airouter" ]]; then
  echo "run this installer as the existing airouter user" >&2
  exit 64
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_root="$HOME/.config/dokploy-mcp"
quadlet_root="$HOME/.config/containers/systemd"
env_file="$config_root/env"

install -d -m 700 "$config_root"
install -d -m 700 "$quadlet_root"

podman build \
  --file "$root/Containerfile" \
  --tag localhost/dokploy-mcp:0.29.3 \
  "$root"

install -m 644 "$root/dokploy-mcp.container" "$quadlet_root/dokploy-mcp.container"

if [[ ! -e "$env_file" ]]; then
  install -m 600 "$root/env.example" "$env_file"
  echo "created $env_file; set the dedicated DOKPLOY_API_KEY, then rerun" >&2
  exit 78
fi

chmod 600 "$env_file"

if ! grep -Eq '^DOKPLOY_API_KEY=.+$' "$env_file"; then
  echo "DOKPLOY_API_KEY is empty in $env_file" >&2
  exit 78
fi

systemctl --user daemon-reload
systemctl --user enable --now dokploy-mcp.service

if sudo -n true 2>/dev/null; then
  sudo tailscale serve --bg --yes --https=3001 http://127.0.0.1:3001
else
  echo "service is active on loopback; an operator must publish it once with:" >&2
  echo "sudo tailscale serve --bg --yes --https=3001 http://127.0.0.1:3001" >&2
  exit 77
fi
