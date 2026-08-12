# Dokploy deployment

Create one Dokploy Compose application from `deploy/dokploy/compose.yaml` and set
the variables listed in `.env.example` in Dokploy's environment editor. Do not
publish a domain or host port: the dashboard is intentionally reachable only as
`http://symphony-prod:4021` from the tailnet.

The four named volumes are the recovery boundary. Back up
`symphony_runtime_state`, `symphony_workspaces`, `symphony_codex_home`, and
`symphony_tailscale_state` before replacing the VM. The state checkpoint is
written before a Linear issue is dispatched; interrupted claims are revalidated
and resumed after the configured recovery backoff.

Dokploy should stop the Compose application with its normal stop action. The
two-minute Compose grace period gives the orchestrator time to enter drain mode
and checkpoint running issues. The `flock` in `entrypoint.sh` prevents two
controllers from using the same state volume.
