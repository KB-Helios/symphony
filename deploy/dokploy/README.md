# Dokploy deployment

Create one Dokploy Compose application from `deploy/dokploy/compose.yaml` and set
the variables listed in `.env.example` in Dokploy's environment editor. Use the
Tailscale auth key only for the first enrollment, then remove it after the
`symphony-tailscale` volume contains the node state. Do not
publish a domain or host port: the dashboard is intentionally reachable only as
`http://symphony-prod:4021` from the tailnet.

The four named volumes are the recovery boundary. Back up
`symphony-state`, `symphony-workspaces`, `symphony-codex`, and
`symphony-tailscale` before replacing the VM. The state checkpoint is
written before a Linear issue is dispatched; interrupted claims are revalidated
and resumed after the configured recovery backoff.

Dokploy should stop the Compose application with its normal stop action. The
two-minute Compose grace period gives the orchestrator time to enter drain mode
and checkpoint running issues. The `flock` in `entrypoint.sh` prevents two
controllers from using the same state volume.

For live operations, run `deploy.ps1 -Prepare` first. It target-locks the GCP
project/zone/instance, verifies the Spot policy, exports Dokploy PostgreSQL and
`/etc/dokploy`, stops the VM, creates a `READY` machine image, and starts it
again. It writes a local, ignored `.prepared.json` proof. Only after that
succeeds, set `DOKPLOY_URL`, `DOKPLOY_API_KEY`, and the application environment
variables in the current process and run
`deploy.ps1 -Deploy`. The deploy path creates or updates only
`Symphony/production/symphony`, uses the public Git source at the requested
branch, and creates no domain. Before changing Dokploy it revalidates both
rollback artifacts and confirms that the configured model alias is present in
the private OmniRoute `/models` catalog.

Run `verify.ps1` from a tailnet-connected operator machine after Dokploy reports
the deployment complete. It proves private health/readiness, non-root execution,
the four volumes, no host/public listener, and a live OmniRoute Responses call.
