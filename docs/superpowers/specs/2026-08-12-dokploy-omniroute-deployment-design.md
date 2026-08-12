# Symphony Dokploy and OmniRoute Deployment Design

**Date:** 2026-08-12
**Status:** Approved
**Target:** `instance-20260804-153230-eu`, Ubuntu 24.04 LTS x86_64, GCE Spot
**Production profile:** Linear tracker + Codex app-server + private OmniRoute

## Objective

Deploy Symphony as a Dokploy-managed application that survives abrupt Spot VM shutdowns without
duplicating agent work or losing active workspaces. Codex remains the coding harness, while the
selected model and OpenAI-compatible Responses endpoint remain deployment configuration so the
service can use private OmniRoute aliases without application changes.

Activate the official Dokploy MCP server on the current OmniRoute host for future operator use,
without exposing the Dokploy API or its credential publicly and without granting infrastructure
tools to ordinary Symphony issue workers.

This document is a target-specific addendum to
`docs/superpowers/specs/2026-08-11-vps-production-readiness-design.md`. It supersedes that document's
systemd, Caddy, localhost-SSH-worker, and host-filesystem packaging topology for this deployment.
Its application safety, bounded execution, durable state, graceful drain, preflight, readiness,
testing, secret-handling, and rollback requirements remain in force.

## Selected Approach

Use one standard Dokploy Docker Compose application containing:

1. a Symphony container with the Elixir release, Codex CLI, Git, OpenSSH client, and shell runtime;
2. a Tailscale sidecar whose network namespace is shared by Symphony;
3. Docker named volumes for scheduler state, workspaces, Codex state, and Tailscale state.

The sidecar is the only container that receives `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun`.
Symphony receives no additional Linux capabilities. The Symphony dashboard is available only on
the sidecar's tailnet address; this deployment creates no Dokploy domain or public Traefik route.
Dokploy's existing Traefik, Postgres, certificate, and admin-panel configuration remain untouched.

Alternatives rejected:

- Host-installed Tailscale was smaller on paper but would make the Dokploy application depend on
  machine-local routing and firewall configuration outside its deployment definition.
- A public model route or public Dokploy MCP endpoint would weaken the established private routing
  boundary.
- A managed instance group or external database would automate more of the Spot lifecycle but add
  migration risk and infrastructure that this single-instance deployment does not need.

## Runtime Topology

```text
Linear HTTPS
    |
    v
Dokploy Compose on Spot VM
    |
    +-- tailscale sidecar (persistent tailnet identity)
    |      |-- private dashboard :4021
    |      `-- private egress to ai-router-main.tail31b2b0.ts.net
    |
    `-- symphony (shares sidecar network namespace)
           |-- Elixir/OTP orchestrator
           |-- Codex app-server child processes
           |-- durable scheduler checkpoint volume
           |-- durable per-issue workspace volume
           `-- durable Codex home volume

Current OmniRoute VM
    |
    +-- OmniRoute private Responses API
    `-- official Dokploy MCP, loopback origin + private Tailscale publication
             `-- private GCP VPC request to Dokploy :3000
```

## Components

### 1. Reproducible Symphony image

The repository owns a multi-stage Dockerfile. The build stage pins Elixir 1.19, OTP 28, dependency
locks, and the Codex CLI version. It builds production assets and a production Elixir release. The
runtime stage contains only the release plus the tools required by `SPEC.md` and the repository
workflow: Codex, Git, OpenSSH client, Bash, certificates, and minimal process utilities.

The image runs as a non-root user. The Compose service uses an init process, a read-only root
filesystem where practical, a restricted temporary filesystem, dropped capabilities, resource
limits, and `restart: unless-stopped`. A synchronous health check calls the cheap liveness endpoint;
Dokploy readiness additionally checks the real readiness endpoint before a deployment is accepted.

### 2. Dokploy Compose application

Dokploy uses standard Compose mode, not Swarm Stack mode. The deployment is created in a dedicated
`Symphony` project and `production` environment. It builds from the verified repository and branch
with the repository-owned Compose file.

Named volumes are mandatory because Dokploy can back them up and preserves them across rebuilds:

- `symphony-state` -> `/var/lib/symphony/state`
- `symphony-workspaces` -> `/var/lib/symphony/workspaces`
- `symphony-codex` -> `/var/lib/symphony/codex`
- `symphony-tailscale` -> `/var/lib/tailscale`

The deployment begins with one concurrent agent and one required opt-in Linear label. It has no
public domain. Dokploy stores all environment values and secrets; repository files contain names
and validation rules only.

### 3. Private Tailscale connection

The Tailscale sidecar uses a tagged auth key only for first enrollment and persists its node state
in `symphony-tailscale`. Symphony shares the sidecar network namespace, so both its private
dashboard and every Codex request use the sidecar's tailnet identity. The tailnet ACL permits this
tag to reach only the OmniRoute HTTPS service and permits operator devices to reach Symphony's
dashboard port.

Startup ordering requires a healthy Tailscale sidecar before Symphony becomes ready. Loss of
tailnet connectivity makes OmniRoute preflight/readiness fail and stops new dispatch; it does not
delete workspaces or release durable claims.

### 4. Model-agnostic Codex provider

`CODEX_HOME` is `/var/lib/symphony/codex`. A deployment-owned config defines one custom provider:

- provider ID: `omniroute`
- wire API: `responses`
- base URL: `OMNIROUTE_BASE_URL`, including `/v1`
- credential source: `OMNIROUTE_API_KEY`
- selected model: `SYMPHONY_MODEL`

The default deployment model is an existing OmniRoute alias selected during provisioning, not an
OpenAI model hard-coded in Elixir. Changing the model alias or private endpoint is a Dokploy
configuration change followed by preflight and redeploy; it does not require a source rebuild.

The Codex child environment is an allowlist. It includes the model-router credential because that
is a required worker credential, but excludes `LINEAR_API_KEY`, Dokploy credentials, GCP
credentials, Tailscale auth keys, and unrelated host/controller secrets. Provider credentials are
never written into `WORKFLOW.md`, a workspace, logs, checkpoints, or MCP responses.

### 5. Linear profile

The controller keeps the Linear credential and uses the existing Linear adapter. The production
workflow configures exactly one project scope, explicit active and terminal states, and one required
opt-in label. Concurrency begins at one. The agent's provider-native Linear tool remains scoped by
the controller and receives no raw Linear token.

Repository checkout settings, branch behavior, validation, and handoff remain in repository-owned
`WORKFLOW.md`. Deployment-specific values are environment references.

### 6. Efficient durable checkpoints

The scheduler owns one schema-versioned JSON snapshot on `symphony-state`. Correctness transitions
are written before their side effects using same-directory temporary files, file flush, `fsync`,
atomic rename, and directory `fsync`.

The snapshot includes:

- durable claims and status (`running`, `retrying`, `interrupted`, `blocked`);
- retry attempt and absolute due time;
- attempt, turn, wall-time, token, and abnormal-failure budgets;
- workspace key/path and selected harness;
- last thread/turn identifiers for audit, not process resurrection;
- last successful tracker poll, normalized error codes, and drain state.

The orchestrator checkpoints before dispatch, retry scheduling, blocking, claim release, and
cleanup, and after every completed Codex turn. High-frequency progress messages remain in memory;
token/session telemetry may be coalesced to at most one checkpoint per second because it is not a
dispatch authority.

A checkpoint write failure immediately disables polling and new dispatch, makes readiness fail,
and preserves the prior valid snapshot.

### 7. Abrupt Spot shutdown recovery

The design does not rely on receiving SIGTERM. Docker volumes live on the persistent boot disk, so
the last atomic snapshot and issue workspaces survive a sudden power loss or GCE preemption.

On startup Symphony:

1. obtains the exclusive state lock;
2. loads the last valid snapshot;
3. converts prior `running` claims to `interrupted` without releasing them;
4. verifies the preserved workspace is below the configured root;
5. refreshes the issue from Linear;
6. keeps terminal/ineligible work stopped and performs only guarded cleanup;
7. waits the configured recovery backoff, then starts a fresh Codex app-server thread in the same
   workspace for an eligible issue.

Codex app-server processes and BEAM PIDs are never resurrected. The durable workspace plus the
Linear workpad are the continuation checkpoint. A fresh thread avoids depending on unstable
cross-process session-resume behavior while retaining the code, commits, workpad, and scheduler
budgets that matter.

Graceful Dokploy redeploys still drain workers, flush state/logs, and stop within the configured
deadline. The forced-shutdown path is tested separately.

The VM's current Spot policy stops the instance on preemption and does not automatically restart
it. This design guarantees application recovery after the VM is started; it does not add a managed
instance group or external VM-start automation.

### 8. Dokploy MCP for operator access

The official `@dokploy/mcp` server runs on the current OmniRoute VM under the existing rootless
`airouter` service model. Its upstream is Dokploy's private GCP address on port 3000. Firewall rules
allow that connection only from the current OmniRoute VM's private address.

The service configuration is:

- loopback listener on `127.0.0.1:3001`;
- private Tailscale publication for operator clients only;
- `DOKPLOY_REDACT_ENV=true`;
- `DOKPLOY_ENABLED_TAGS=project,application,compose,deployment,domain`;
- a dedicated Dokploy API token stored only in a mode-`0600` environment file;
- bounded timeouts/retries and restart-on-failure;
- Codex MCP default approval mode `writes`.

The private publication preserves every existing OmniRoute dashboard/API route. It is not exposed
through public ingress. A read-only tool call is used for initial acceptance; one explicitly
approved benign write/redeploy call proves mutation wiring. Symphony ticket workers do not receive
this MCP server by default.

## Data Flow

1. Dokploy starts the persistent Tailscale sidecar and waits for tailnet health.
2. Symphony validates workflow, volumes, Codex version/protocol, Linear scope, and OmniRoute
   `/v1/models`/Responses reachability.
3. Symphony locks and restores the durable scheduler snapshot.
4. The orchestrator polls Linear and persists a claim before launching any worker.
5. Codex runs in the issue workspace using the OmniRoute provider and deployment-selected alias.
6. Linear tool calls return to the controller; the Linear token never enters the Codex process.
7. Turn completion updates budgets and persists the checkpoint before continuation or release.
8. Dokploy records health, readiness, logs, deployment history, and resource use.

## Error Handling

- Invalid/missing Linear, OmniRoute, Tailscale, or workflow configuration fails preflight without
  dispatching work or printing secret values.
- Tailnet or OmniRoute loss pauses dispatch and preserves claims/workspaces for retry.
- Tracker authentication errors pause dispatch; rate limits use bounded persisted backoff.
- Persistence failure is fail-closed. No claim-changing side effect proceeds without a successful
  checkpoint.
- Container crash/redeploy restarts through Dokploy; Spot power loss recovers from named volumes
  after the VM returns.
- Workspace containment or ambiguous recovery state creates an operator-visible block instead of
  deleting or redispatching work.
- Dokploy MCP startup fails if its token is missing. It never falls back to an unauthenticated
  public endpoint or returns secret-bearing environment/Compose fields to a model.

## Deployment and Rollback

Before mutation, create and verify a GCE machine-image rollback artifact and export Dokploy's
current configuration/database backup. Keep the original VM disk and existing Dokploy services.

Deployment order:

1. start the preempted Spot VM and verify Docker/Dokploy health;
2. back up GCE and Dokploy state;
3. build and verify the Symphony image locally/CI;
4. create the Dokploy project, Compose application, named volumes, secrets, and limits;
5. enroll the sidecar and validate private OmniRoute connectivity;
6. deploy with no eligible Linear issue and verify health/readiness;
7. run one disposable opt-in issue and restart-recovery drill;
8. install and validate Dokploy MCP on the current OmniRoute VM;
9. enable the intended production label only after acceptance passes.

Application rollback selects the prior verified image/deployment while preserving named volumes.
Infrastructure rollback restores the verified machine image only if Dokploy or its existing services
cannot be recovered in place. Destructive cleanup is deferred until application, model, tracker,
MCP, restart, and rollback checks pass.

## Verification

Required deterministic checks:

- format, compile-with-warnings-as-errors, specs, Credo, ExUnit, coverage, Dialyzer, and dependency
  audit on Linux;
- container build, non-root execution, immutable filesystem, health/readiness, and secret scan;
- model-provider config with two distinct OmniRoute aliases and no Elixir source change;
- child environment proves Linear/Dokploy/GCP/Tailscale secrets are absent and only the required
  OmniRoute worker credential is present;
- atomic checkpoint failure preserves the previous snapshot and stops dispatch;
- forced container kill during an active issue preserves the workspace, claim, and budgets and
  does not start a duplicate after restart;
- actual Spot VM stop/start restores Dokploy, the tailnet identity, Symphony readiness, state, and
  workspaces;
- live Linear + Codex canary reaches OmniRoute `/v1/responses` and completes the exact harness
  acceptance flow;
- Dokploy MCP lists only approved categories, redacts environment/Compose secrets, passes a
  read-only tool call, and requires approval for a benign write.

## Definition of Done

- Symphony is a healthy Dokploy Compose application on the named Spot VM with no public route.
- Linear + Codex is the supported production profile and concurrency starts at one.
- The model provider is private OmniRoute, uses the Responses API, and accepts a deployment-selected
  model alias without source changes.
- Abrupt container and VM shutdown tests preserve claims, budgets, workspaces, and exact-once
  dispatch behavior after restart.
- Checkpoint or dependency failures stop new work without deleting recoverable state.
- A verified backup and application rollback are retained until all acceptance checks pass.
- Dokploy MCP is active on the current OmniRoute VM, private, redacted, narrowly filtered, and
  usable from an operator Codex client with write approvals.
- No credential, auth key, token, machine-local secret, or resolved secret-bearing configuration is
  committed to Git or exposed in logs, API responses, checkpoints, or model context.
