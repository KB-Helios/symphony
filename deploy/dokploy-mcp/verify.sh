#!/usr/bin/env bash
set -euo pipefail

systemctl --user is-active --quiet dokploy-mcp.service
curl --fail --silent --show-error http://127.0.0.1:3003/health >/dev/null

published=$(sudo tailscale serve status --json)
if ! grep -q '3003' <<<"$published"; then
  echo "Tailscale Serve is not publishing Dokploy MCP port 3003" >&2
  exit 1
fi

if ss -ltnH 'sport = :3003' | grep -vq '127.0.0.1:3003'; then
  echo "Dokploy MCP has a non-loopback listener" >&2
  exit 1
fi

podman healthcheck run dokploy-mcp >/dev/null
echo "Dokploy MCP is healthy, loopback-only, and privately published"
