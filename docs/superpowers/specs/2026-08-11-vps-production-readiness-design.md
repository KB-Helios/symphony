# Symphony VPS Production-Readiness Design

**Date:** 2026-08-11
**Status:** Approved direction
**Target:** Ubuntu 24.04 LTS x86_64 VPS
**Initial production profile:** Linear tracker + Codex app-server

## Objective

Turn the current Symphony Elixir engineering preview into a bounded, recoverable, testable service that can run unattended on one remote VPS without exposing its control plane or tracker credentials to repository code.

“Production-ready” in this design means:

- the supported Linear + Codex profile has a green, enforced build and test pipeline;
- known dependency advisories are resolved or explicitly blocked from release;
- unattended execution has finite resource and retry budgets;
- state needed for safe restart recovery is durable;
- the web surface is read-only, authenticated, origin-restricted, and never bound publicly by Symphony itself;
- agent code runs under a different operating-system identity from the control plane;
- installation, operation, upgrade, rollback, backup, and incident response are documented and tested;
- a clean release artifact boots successfully and passes readiness, asset, LiveView, and shutdown smoke tests.

Other tracker adapters and the Prime harness remain available but are labeled experimental until their provider-specific live canaries pass the same release criteria.

## Current Evidence and Release Blockers

The audit at commit `caccea86b57f0ae5000f5f0c02b53c095ab3229c` found:

- compilation with warnings-as-errors, escript build, and Dialyzer pass;
- the fork has no GitHub Actions runs and `main` is not protected;
- the native Windows checkout reports 328 tests, 71 failures, 6 skips, and 62.23% reported coverage; several failures are platform-specific, but there is no current clean Linux result;
- Credo reports 6 readability, 9 refactoring, and 74 line-ending findings;
- `mix hex.audit` reports 27 advisories, including 14 HIGH advisories;
- the dashboard and API have no authentication and include workflow-mutating routes;
- harness switching can rewrite YAML incorrectly, synchronously call `WorkflowStore` from itself, crash the process, and expose resolved settings in crash reports;
- the release workflow does not build static assets and only smoke-tests the refusal banner;
- documented start commands omit a mandatory acknowledgement flag;
- retries, continuations, wall time, and token use are not bounded across worker invocations;
- running, retrying, blocked, and budget state is volatile across restarts;
- `/api/v1/health` is liveness-only while appearing to be readiness;
- there is no production service unit, reverse-proxy configuration, upgrade/rollback procedure, or VPS runbook.

These are release blockers, not optional polish.

## Scope Decomposition and Order

The work is divided into four sequential workstreams. Each workstream must be independently green before the next one is considered releasable.

1. **Application release blockers:** remove unsafe mutation, prevent secret leakage, fix filesystem and harness correctness, update dependencies, restore a green Linux quality gate.
2. **Runtime resilience:** add finite budgets, durable recovery state, draining, preflight validation, and real readiness.
3. **Release and VPS packaging:** produce verified artifacts and tested systemd/Caddy/install/upgrade/rollback assets for the single-VPS topology.
4. **Production certification:** execute Linear + Codex canaries, failure injection, restart/rollback, and capacity validation on the target VPS image.

The workstreams are separate implementation plans because runtime state, web security, and host deployment have different failure domains. The final release requires all four.

## Production Topology

```text
Internet
   |
   v
Caddy :443 (TLS, authentication, rate and body-size limits)
   |
   v
Bandit 127.0.0.1:4021 (never publicly bound)
   |
   v
symphony-control Unix user
   |-- Linear credential and workflow
   |-- durable scheduler state and restricted logs
   `-- SSH to 127.0.0.1 as symphony-worker
          |
          v
      symphony-worker Unix user
       |-- Codex authentication
       |-- repository deploy credential
       `-- isolated workspaces
```

The controller and worker share a kernel but not a Unix identity, home directory, credential set, or writable data root. This is the strongest practical single-VPS boundary without adding a second VM. The existing SSH-worker mechanism is used even on localhost so the worker can later move behind WireGuard or another private network without changing application semantics.

### Network policy

- Public firewall ingress permits TCP 22, 80, and 443 only.
- SSH is restricted to the operator’s source network or VPN when available.
- Port 80 redirects to 443.
- Bandit listens only on `127.0.0.1:4021`; the application refuses a non-loopback production bind.
- Caddy authenticates every dashboard, LiveView, and API route and proxies WebSocket upgrades.
- Before a DNS name is available, the dashboard is accessed only through an SSH tunnel; it is not exposed over plaintext HTTP.
- The controller may reach Linear HTTPS and localhost SSH. The worker may reach Codex, git hosting, and workflow-approved package endpoints.

### Filesystem and identities

- `/opt/symphony/releases/<version>/symphony`: immutable verified release artifact.
- `/opt/symphony/current`: atomic symlink to the active release.
- `/etc/symphony/WORKFLOW.md`: root-owned, group-readable by `symphony-control`, mode `0640`.
- `/etc/symphony/symphony.env`: root-owned, mode `0600`.
- `/var/lib/symphony`: controller state, mode `0700`.
- `/var/log/symphony`: controller logs, mode `0750`; log files mode `0640`.
- `/srv/symphony-workspaces`: worker-owned, mode `0700`.
- Controller and worker homes are mutually unreadable.
- The controller has no repository deploy key or Codex credential. The worker has no tracker, proxy, service-management, or controller credential.

## Application Design

### 1. Read-only and fail-closed control plane

The production web surface is observability-only.

- Remove the dashboard harness selector.
- Remove `POST /api/v1/harness` and the associated runtime workflow rewriting path.
- Keep refresh only if it is protected by the authenticated proxy and rate limited; otherwise remove it and rely on normal polling.
- Configure allowed origins from an explicit production external URL.
- Enable secure session cookie attributes when the external scheme is HTTPS.
- Retain the safe loopback default and reject wildcard/public production hosts.
- Remove multipart parsing and method override from the read-only endpoint, reject request bodies above 64 KiB, keep the existing 15-second snapshot deadline, and configure Caddy API rate limits at 10 requests/second with a burst of 20 per authenticated client.
- Redact tracker tokens, secret-backed config fields, commands containing configured secret values, hook output, and child protocol diagnostics before logging.
- Ensure OTP crash reports never include the resolved workflow settings structure. Runtime processes store redacted metadata and secret references, while the provider client owns resolved credentials.

The workflow file is immutable at runtime. Operators change it through configuration management, validate it with preflight, and restart or explicitly reload only after validation.

### 2. Child environment and tracker-tool policy

Child processes receive an allowlisted environment rather than the controller’s environment minus a few known tracker keys.

The baseline allowlist is limited to values needed for process execution and the selected harness: `HOME`, `PATH`, locale variables, terminal variables when interactive output is required, `CODEX_HOME`, and workflow-declared non-secret additions. Controller secrets such as `SECRET_KEY_BASE`, tracker credentials, cloud credentials, SSH agent sockets, deployment keys, and proxy credentials are excluded.

Provider-native tools are disabled by default in the production profile. When enabled, the Linear tool is restricted to the configured Linear workspace/project scope where the API permits enforcement, uses a least-privilege service identity, and retains structured failure responses. Mutation-capable generic tools require an explicit trusted-workflow setting.

The shipped production example uses:

- one required opt-in label;
- concurrency `1` initially;
- the valid granular auto-reject approval policy;
- workspace-write sandboxing;
- network disabled unless the repository bootstrap or validation command needs it;
- no `shell_environment_policy.inherit=all`.

### 3. Workspace and harness correctness

All destructive local and remote workspace operations validate the canonical target against the configured workspace root immediately before execution.

The implementation refuses:

- the workspace root itself;
- absolute paths outside the root;
- traversal and separator variants;
- symlink escapes;
- remote paths that cannot be canonically proven below the remote root.

The harness selected from labels is carried consistently through AgentRunner execution, running metadata, blocked state, UI presentation, timeout selection, and logs. Tests exercise the real dispatch path instead of duplicating the private selection algorithm.

### 4. Finite execution budgets

The production defaults are deliberately conservative and configurable per workflow:

- maximum attempts per issue: `10`;
- maximum total turns per issue: `100`;
- maximum wall-clock time per issue: `4 hours`;
- maximum total input plus output tokens per issue: `2,000,000`;
- maximum consecutive abnormal failures: `5`;
- maximum graceful drain time during shutdown: `120 seconds`.

Counters span continuations and retries and survive restarts. Reaching any limit moves the issue into a persisted `budget_exhausted` blocked state, records the exact exhausted dimension, stops automatic dispatch, and surfaces an operator-visible alert. It never silently resets on restart. A dedicated administrative CLI command resets one issue only after displaying its current counters; the web API cannot reset budgets.

Global concurrency remains configurable, but the production example starts at one agent and increases only after the capacity test passes.

### 5. Durable recovery state

A single owner process persists a versioned runtime snapshot under `/var/lib/symphony/state` using write-to-temp, flush, fsync, and atomic rename semantics.

The persisted schema contains:

- schema version and controller instance identifier;
- retry attempts, due times, and last errors;
- blocked reasons and operator-input metadata with secrets removed;
- per-issue budget counters and first/last activity timestamps;
- claimed issue identifiers and last-known worker/session metadata;
- last successful tracker poll and last workflow validation error.

Live BEAM PIDs and ports are never treated as reusable runtime objects. Each worker writes a run marker containing its PID, process-group ID, worker boot ID, executable, and `/proc` start ticks. On startup, recorded running claims become `interrupted` recovery records. The controller refreshes the tracker issue, validates the preserved workspace, and inspects the marker through SSH. It cancels a process only when boot ID, start ticks, executable, and workspace all match; an unverifiable marker becomes operator-blocked. A verified clean interruption is eligible after a 30-second recovery backoff. The controller never immediately dispatches a duplicate.

The deployment uses an exclusive `flock` around the controller process so only one instance can use the state directory. Overlapping upgrades fail before polling.

### 6. Graceful shutdown

On `SIGTERM` the controller:

1. marks readiness false;
2. stops new polling and dispatch;
3. records current claims and counters;
4. requests cancellation of active harness sessions;
5. waits up to 120 seconds;
6. terminates remaining child process groups;
7. flushes state and logs;
8. exits with an outcome visible to systemd.

The systemd unit’s stop timeout is longer than the application drain deadline and uses control-group termination to prevent orphaned local processes.

### 7. Preflight, liveness, and readiness

A `symphony check <WORKFLOW.md>` command performs no dispatch and validates:

- workflow parsing, schema, prompt rendering, and production-safe settings;
- required explicit environment references without printing values;
- Linear authentication, project scope, configured states, and required label;
- workspace and state-directory ownership, writability, and containment;
- `bash`, `sh`, `git`, `ssh`, and selected harness executable availability;
- supported Codex app-server version/protocol;
- localhost SSH worker connectivity and worker workspace permissions;
- release static assets and configured external URL/origin;
- the single-instance lock.

`/api/v1/health` remains a cheap liveness endpoint. A separate `/api/v1/ready` returns 200 only when workflow configuration is valid, the state store is writable, the orchestrator responds, a recent tracker poll succeeded, and the service is not draining. Readiness errors are stable codes without secrets. Snapshot timeouts return 503, never a misleading 404.

## Release and CI Design

### Required source gate

A protected `main` branch requires an Ubuntu 24.04 job that runs from a clean checkout:

1. dependency installation;
2. format check;
3. public spec check;
4. Credo strict;
5. tests and honest coverage reporting;
6. Dialyzer;
7. dependency advisory audit;
8. production asset build;
9. release-binary smoke test.

The repository adds `.gitattributes` rules so Elixir and text source use LF consistently. Platform-specific tests explicitly declare supported operating systems rather than failing accidentally on Windows.

The coverage configuration stops excluding critical runtime modules merely to claim 100%. The gate uses meaningful module-level expectations for the orchestrator, workspace safety, workflow store, controller/presenter/router, app-server transports, budgets, and persistence. A lower honest global percentage is preferable to a nominal 100% that ignores production code.

### Artifact build and smoke

Before Burrito wraps the release, CI runs `mix assets.deploy`. Each native target smoke test:

- verifies the published checksum;
- starts the artifact with the mandatory acknowledgement and a disposable memory workflow;
- starts HTTP on a free loopback port;
- verifies liveness, readiness, CSS, JavaScript, and LiveView connection;
- verifies the reported version;
- sends `SIGTERM` and confirms clean shutdown;
- confirms no orphan process or workspace remains.

Tag publication depends on the full source gate and smoke matrix. Releases also emit an SBOM and signed provenance/attestation. The external Codex version is pinned to a documented supported range and checked before dispatch.

## VPS Deployment Package

The repository provides:

- a hardened systemd unit for the controller;
- a systemd resource-policy drop-in for the worker user slice;
- a Caddy configuration with TLS, authentication, security headers, rate limits, and WebSocket proxying;
- an environment-file template containing names and explanations but no values;
- an install script that creates identities/directories, verifies checksums, installs a versioned artifact, runs preflight, and enables the service;
- upgrade and rollback scripts that drain, switch the atomic symlink, verify readiness, and restore the prior version on failure;
- firewall, DNS, SSH-key, known-host, permissions, backup, log, and incident-response runbooks.

The service unit sets `MIX_ENV=prod`, a persistent 64-plus-character `SECRET_KEY_BASE`, an absolute workflow path, state/log roots, loopback port, mandatory acknowledgement, restrictive umask, restart limits, CPU/memory/PID/file-descriptor limits, and systemd hardening compatible with required writable paths.

## Data Flow

1. The controller passes preflight and obtains the single-instance lock.
2. It loads redacted workflow metadata and resolved provider credentials into separate owners.
3. It restores durable retry, blocked, claim, and budget state.
4. It polls Linear and normalizes candidates.
5. It applies state, label, claim, capacity, and budget eligibility.
6. It persists a claim before launching work.
7. It opens a localhost SSH session as `symphony-worker` and runs hooks/Codex only in the canonical worker workspace.
8. Provider-native tool calls return to the controller and execute under the scoped Linear credential.
9. Events update redacted observability state and durable counters.
10. Completion, failure, cancellation, or budget exhaustion is persisted before the claim changes.
11. Terminal tracker state triggers guarded cleanup only after preservation hooks succeed according to the production cleanup policy.

## Error Handling

- Configuration, secret reference, unsupported Codex version, unsafe bind, state-store, and workspace-containment failures fail startup or readiness before dispatch.
- Tracker authentication errors set readiness false and pause dispatch; rate limits honor provider delay signals and do not spin.
- Retryable transport and harness failures use bounded exponential backoff and persisted counters.
- Non-retryable safety, budget, repeated failure, and ambiguous restart conditions become explicit blocked records.
- Persistence failure stops new dispatch immediately; the controller never continues while unable to record claims.
- Cleanup preservation failure blocks deletion and alerts instead of deleting unpushed work.
- Web responses expose stable error codes and correlation identifiers, not raw exceptions, paths, commands, or credentials.

## Testing Strategy

Implementation follows red-green-refactor with focused tests for each behavior.

Required deterministic suites include:

- unauthenticated and cross-origin web requests;
- absence of mutation routes and harness selector;
- crash-report and log secret redaction;
- child environment allowlisting;
- workspace traversal, symlink, root, and remote containment attacks;
- real label-selected harness propagation;
- every budget dimension and administrative reset;
- persisted retry/blocked/budget recovery across process restart;
- interrupted claim recovery and duplicate-dispatch prevention;
- persistence-write failure fail-closed behavior;
- graceful drain and orphan cleanup;
- liveness/readiness state transitions;
- clean release artifact boot and static assets;
- install, upgrade, failed-upgrade rollback, and backup restoration.

Production certification additionally runs:

- disposable Linear + Codex local-controller/localhost-worker canary;
- tracker 429/500/timeout and malformed response injection;
- Codex crash, hang, unsupported protocol, and malformed JSON injection;
- SSH interruption, hook failure/timeout, disk-full, and log-handler failure;
- controller kill/restart during running, retrying, blocked, and draining states;
- multi-hour soak at concurrency one, then the intended production concurrency;
- restore and rollback rehearsal on the target Ubuntu image.

## Operations and Rollout

Rollout is staged:

1. deploy with no eligible label and verify preflight/readiness;
2. enable one disposable Linear issue with concurrency one;
3. verify repository clone, Codex turn, tracker update, logs, budgets, and cleanup;
4. exercise restart and rollback while a disposable issue is active;
5. enable the production opt-in label for a limited project;
6. increase concurrency only after CPU, memory, process, disk, API latency, and retry metrics remain within limits during soak.

Backups include `/etc/symphony`, `/var/lib/symphony`, and active `/srv/symphony-workspaces` until work is pushed. Backups are encrypted off-host and restoration is tested. Versioned binaries and build caches are reproducible and are not backup-critical.

## Definition of Done

The objective is complete only when all of the following are evidenced on the target profile:

- current `main` has required green CI and no unhandled dependency advisories;
- all P0 correctness/security regressions have automated tests;
- the release artifact contains and serves production assets;
- the application refuses unsafe public binding and the public dashboard is authenticated through TLS;
- controller and worker identities cannot read each other’s secrets;
- child environment and provider tools follow the production allowlist/scope policy;
- retries, turns, wall time, tokens, and failures are bounded and durable;
- restart, drain, duplicate prevention, persistence failure, cleanup preservation, and rollback tests pass;
- preflight, liveness, readiness, logs, alerts, backups, and operator runbooks are validated;
- Linear + Codex live canary and failure-injection matrix pass on Ubuntu 24.04;
- a fresh VPS installation and a rollback can be performed using only committed documentation and scripts;
- the repository and deployed service contain no credentials or machine-local configuration.
