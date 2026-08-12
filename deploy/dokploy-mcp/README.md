# Private Dokploy MCP

This package installs official `@dokploy/mcp` 0.29.3 as a rootless Podman
Quadlet under the existing `airouter` user. The container listens only on
`127.0.0.1:3001`; Tailscale Serve publishes it privately at
`https://ai-router-main.tail31b2b0.ts.net:3001/mcp`. Do not enable Funnel.

Before installation, create a dedicated Dokploy API key and ensure the Dokploy
VM firewall allows TCP `3000` only from the OmniRoute VM private address
`10.226.0.2/32`. Copy `env.example` to
`~/.config/dokploy-mcp/env`, put the token after `DOKPLOY_API_KEY=`, and keep
the file mode `0600`. The response redactor and five-category tool filter are
mandatory.

Run `install.sh` and then `verify.sh` as `airouter`. Apply a tailnet grant that
allows only operator users/devices to reach `ai-router-main:3001`. Add the
contents of `operator-codex.toml.example` to the operator's user-level Codex
`config.toml`; the `writes` policy prompts for tools not marked read-only.
Never copy this MCP entry into Symphony's worker `CODEX_HOME`.
