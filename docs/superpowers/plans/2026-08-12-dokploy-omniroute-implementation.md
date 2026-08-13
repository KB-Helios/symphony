# Dokploy OmniRoute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Symphony's Linear + Codex profile as a private Dokploy Compose application on the named GCE Spot VM, with durable exact-once recovery, a deployment-selected OmniRoute model, and a private redacted Dokploy MCP service.

**Architecture:** Keep the existing tracker and Codex app-server seams. Add one schema-versioned JSON state store beneath the orchestrator, use a container-level `flock` as the single-owner boundary, and restore durable claims as delayed retries without restoring PIDs or Codex sessions. Package one non-root Symphony image beside a persistent Tailscale sidecar; generate only the non-secret Codex provider configuration at container startup and keep the model alias and credentials in Dokploy.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix/Bandit, Jason, ExUnit, Docker Compose, Tailscale, Dokploy, GCE, Codex app-server Responses API, and the official `@dokploy/mcp` server.

## Global Constraints

- Production target is `instance-20260804-153230-eu` in `europe-west1-b`, project `project-eb921be9-5a18-4ede-909`.
- Production profile is Linear tracker plus Codex app-server; Prime remains available in source but is not deployed.
- The private model base URL ends in `/v1`, the Codex provider uses `wire_api = "responses"`, and `SYMPHONY_MODEL` selects the model without changing Elixir source.
- Production begins with concurrency `1` and one required opt-in Linear label.
- Durable state, workspaces, Codex home, and Tailscale state use Docker named volumes.
- A durable claim is written before worker spawn. Restored `running` work is treated as `interrupted` and is revalidated against Linear before delayed redispatch in the preserved workspace.
- State writes use same-directory temporary files, file sync, atomic rename, and best-effort directory sync. A failed write makes readiness false and stops new dispatch.
- Container ownership is enforced with `/usr/bin/flock --exclusive --nonblock`; live BEAM PIDs, ports, references, and timers are never serialized.
- Symphony and Dokploy MCP have no public route. Tailscale is the only dashboard/model/MCP transport.
- Secrets never enter Git, durable state, workspaces, logs, or MCP responses. The Codex child receives only its explicit allowlist.
- Create and verify rollback artifacts before mutating the live VM. Do not delete the source disk, backups, or prior Dokploy state during this work.
- Every shell command is RTK-prefixed. Application behavior follows red-green-refactor.

---

### Task 1: Durable budget and state primitives

**Files:**
- Create: `elixir/lib/symphony_elixir/budget.ex`
- Create: `elixir/lib/symphony_elixir/runtime_state.ex`
- Create: `elixir/lib/symphony_elixir/state_store.ex`
- Create: `elixir/test/symphony_elixir/budget_test.exs`
- Create: `elixir/test/symphony_elixir/state_store_test.exs`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/config/config.exs`
- Modify: `elixir/WORKFLOW.md`

**Interfaces:**
- `Budget.new/3`, `authorize_attempt/3`, `authorize_turn/3`, `add_tokens/4`, `exhausted_dimension/3`, `to_map/1`, and `from_map/1` implement finite per-issue limits.
- `RuntimeState.from_orchestrator/1` returns a JSON-safe schema-version-1 map without runtime terms.
- `RuntimeState.restore/1` returns `{:ok, durable}` or `{:error, stable_code}`.
- `StateStore.load/1` returns `{:ok, durable | nil}`; `StateStore.save/2` atomically replaces the prior snapshot.

- [ ] **Step 1: Write the failing budget boundaries**

```elixir
test "production budget boundaries are finite" do
  limits = Budget.limits(Config.settings!().agent)
  now = ~U[2026-08-12 08:00:00Z]
  budget = Budget.new("issue-1", "SYM-1", now)

  assert limits == %{attempts: 10, turns: 100, wall_time_ms: 14_400_000,
                     tokens: 2_000_000, abnormal_failures: 5}
  assert {:ok, _} = Budget.authorize_attempt(%{budget | attempts: 9}, limits, now)
  assert {:error, :attempts, _} = Budget.authorize_attempt(%{budget | attempts: 10}, limits, now)
end
```

- [ ] **Step 2: Run RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/budget_test.exs`

Expected: missing `SymphonyElixir.Budget` and missing schema fields.

- [ ] **Step 3: Implement the minimal pure budget**

Use a struct containing `issue_id`, `identifier`, attempts, turns, input/output tokens, consecutive abnormal failures, and ISO-8601 first/last activity timestamps. Add exact defaults: attempts `10`, turns `100`, wall time `14_400_000`, total tokens `2_000_000`, failures `5`, recovery backoff `30_000`, drain timeout `120_000`.

- [ ] **Step 4: Write failing state round-trip and atomicity tests**

```elixir
test "round trips durable claims without runtime terms" do
  path = Path.join(System.tmp_dir!(), "symphony-state-#{System.unique_integer([:positive])}.json")
  durable = %{
    "version" => 1,
    "claims" => %{"issue-1" => %{"status" => "interrupted", "identifier" => "SYM-1"}},
    "budgets" => %{},
    "poll" => %{"last_success_at" => nil},
    "draining" => false
  }

  assert :ok = StateStore.save(path, durable)
  assert {:ok, ^durable} = StateStore.load(path)
  refute inspect(File.read!(path)) =~ "#PID"
end

test "failed replacement preserves the previous valid snapshot" do
  path = Path.join(System.tmp_dir!(), "symphony-state-#{System.unique_integer([:positive])}.json")
  assert :ok = StateStore.save(path, %{"version" => 1, "claims" => %{}})
  assert {:error, _} = StateStore.save(path, %{"version" => fn -> :not_json end})
  assert {:ok, %{"version" => 1}} = StateStore.load(path)
end
```

- [ ] **Step 5: Run RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/state_store_test.exs`

Expected: missing state modules.

- [ ] **Step 6: Implement atomic JSON storage and schema validation**

`StateStore.save/2` must encode before opening a temp file, create the parent directory, write and `:file.sync/1`, close, rename, then sync the parent directory when supported. Temp files stay beside the target and are removed on error. `RuntimeState.restore/1` accepts only version `1` and the statuses `running`, `retrying`, `interrupted`, `blocked`, and `budget_exhausted`.

- [ ] **Step 7: Run GREEN and commit**

Run: `rtk mise exec -- mix test test/symphony_elixir/budget_test.exs test/symphony_elixir/state_store_test.exs test/symphony_elixir/workspace_and_config_test.exs`

Commit: `feat: add durable scheduler state primitives`

---

### Task 2: Persist orchestrator transitions and recover interrupted claims

**Files:**
- Create: `elixir/test/symphony_elixir/orchestrator_resilience_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runtime_supervisor.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Create: `elixir/lib/symphony_elixir/signal_handler.ex`
- Modify: `elixir/lib/symphony_elixir.ex`

**Interfaces:**
- Orchestrator accepts `state_path:`, `state_store:`, and `recovery_backoff_ms:` options.
- `Orchestrator.health/1` returns a secret-free map with persistence, drain, tracker-poll, and dispatch status.
- `Orchestrator.drain/2` stops polling/new dispatch, persists `draining`, waits up to the exact deadline, then stops verified survivors.
- `GET /api/v1/health` is dependency-free; `GET /api/v1/ready` returns `200` or stable `503` JSON.

- [ ] **Step 1: Write failing claim-before-spawn and recovery tests**

```elixir
test "persists a claim before invoking the runner" do
  parent = self()
  store = fn snapshot -> send(parent, {:saved, snapshot}); :ok end
  runner = fn issue, _recipient, _opts ->
    assert_receive {:saved, %{"claims" => %{^issue.id => %{"status" => "running"}}}}
    :ok
  end

  state = start_orchestrator(state_writer: store, runner: runner)
  dispatch(state, issue("issue-1", "SYM-1"))
end

test "restored running claims wait, revalidate, and do not duplicate" do
  restored = snapshot_with_claim("issue-1", "SYM-1", "running")
  server = start_orchestrator(restored: restored, recovery_backoff_ms: 50)
  refute_receive {:runner_started, "issue-1"}, 40
  assert_receive {:runner_started, "issue-1"}, 250
  refute_receive {:runner_started, "issue-1"}, 100
end

test "persistence failure disables dispatch and readiness" do
  server = start_orchestrator(state_writer: fn _ -> {:error, :enospc} end)
  dispatch(server, issue("issue-1", "SYM-1"))
  refute_receive {:runner_started, _}
  assert %{dispatch_enabled: false, persistence: :failed} = Orchestrator.health(server)
end
```

- [ ] **Step 2: Run RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/orchestrator_resilience_test.exs`

Expected: option/health APIs are missing and dispatch occurs without a durable write.

- [ ] **Step 3: Add one persistence gate to the orchestrator**

All claim-changing helpers return the updated state through `persist/1`. Dispatch first inserts a `running` claim with issue metadata, harness, workspace, budget, and absolute UTC timestamps, persists it, and only then starts the task. Save failures set `dispatch_enabled: false`, `persistence_error: stable_code`, cancel polling/retry timers, and keep the prior snapshot.

- [ ] **Step 4: Restore state without runtime identities**

At init, load the snapshot and convert old `running` claims to `interrupted`. Schedule each eligible claim for `recovery_backoff_ms`; the existing retry path refreshes the issue from Linear before calling the runner. Reuse the recorded workspace path, issue identifier, harness, retry count, and budget. Do not restore PIDs, monitor refs, ports, timer refs, or Codex thread IDs as executable state.

- [ ] **Step 5: Add truthful readiness**

```json
{"status":"ready"}
```

is returned only when persistence is healthy, the orchestrator responds, it is not draining, configuration is valid, and the tracker has a recent successful poll. Failures use:

```json
{"error":{"code":"state_unwritable","message":"service is not ready","correlation_id":"..."}}
```

- [ ] **Step 6: Drain on SIGTERM without relying on it for correctness**

Add a supervised `SignalHandler` that translates SIGTERM into `Orchestrator.drain/2`. Drain persists `draining: true`, cancels future polls/retries, lets active tasks finish for up to `120_000` ms, terminates remaining task-supervisor children, persists the final snapshot, and exits. Abrupt recovery remains correct when SIGTERM never arrives.

- [ ] **Step 7: Run GREEN and commit**

Run: `rtk mise exec -- mix test test/symphony_elixir/orchestrator_resilience_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs`

Commit: `feat: recover durable orchestrator claims`

---

### Task 3: Allowlist the Codex provider environment

**Files:**
- Create: `elixir/lib/symphony_elixir/child_environment.ex`
- Create: `elixir/test/symphony_elixir/child_environment_test.exs`
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Modify: `elixir/lib/symphony_elixir/prime_agent/app_server.ex`
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`
- Modify: `elixir/WORKFLOW.md`

**Interfaces:**
- `ChildEnvironment.port_env/2` produces Port environment changes that remove every inherited variable not on the allowlist.
- `ChildEnvironment.shell_command/2` emits a shell-safe `env -i` command for SSH children.
- The Codex allowlist contains `HOME`, `PATH`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `SSH_AUTH_SOCK`, `GIT_SSH_COMMAND`, `CODEX_HOME`, `OMNIROUTE_BASE_URL`, `OMNIROUTE_API_KEY`, and `SYMPHONY_MODEL`.

- [ ] **Step 1: Write the failing environment test**

```elixir
test "Codex receives router credentials but not controller credentials" do
  env = ChildEnvironment.effective(%{
    "PATH" => "/usr/bin", "OMNIROUTE_API_KEY" => "router",
    "LINEAR_API_KEY" => "linear", "DOKPLOY_API_KEY" => "dokploy",
    "GOOGLE_APPLICATION_CREDENTIALS" => "/secret/gcp.json"
  }, :codex)

  assert env["OMNIROUTE_API_KEY"] == "router"
  refute Map.has_key?(env, "LINEAR_API_KEY")
  refute Map.has_key?(env, "DOKPLOY_API_KEY")
  refute Map.has_key?(env, "GOOGLE_APPLICATION_CREDENTIALS")
end
```

- [ ] **Step 2: Run RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/child_environment_test.exs`

Expected: missing module.

- [ ] **Step 3: Implement and wire the allowlist**

For local ports, pass `{name, false}` for every current variable not allowed and explicit binary values for allowed variables. Launch Bash without login profiles. For remote workers, use `env -i` with shell-escaped allowlisted values. Merge tracker secret names into the deny set even if a future allowlist accidentally contains one.

Set the production Codex command to:

```yaml
codex:
  command: codex --model "$SYMPHONY_MODEL" --config model_provider=omniroute app-server
```

- [ ] **Step 4: Run GREEN and commit**

Run: `rtk mise exec -- mix test test/symphony_elixir/child_environment_test.exs test/symphony_elixir/app_server_test.exs test/symphony_elixir/prime_agent_app_server_test.exs`

Commit: `fix: isolate Codex provider environment`

---

### Task 4: Build the Dokploy Compose application

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `deploy/dokploy/compose.yml`
- Create: `deploy/dokploy/entrypoint.sh`
- Create: `deploy/dokploy/healthcheck.sh`
- Create: `deploy/dokploy/env.example`
- Create: `deploy/dokploy/README.md`
- Create: `elixir/test/symphony_elixir/dokploy_packaging_test.exs`
- Modify: `elixir/mix.exs`

**Interfaces:**
- The image starts `/app/bin/symphony start` as non-root through `entrypoint.sh`.
- `entrypoint.sh` owns `/var/lib/symphony/state/controller.lock` using `flock`, renders `$CODEX_HOME/config.toml` from non-secret environment values, and never writes the router key.
- Compose services are `tailscale` and `symphony`; Symphony uses `network_mode: service:tailscale` and has no public `ports:` entry.

- [ ] **Step 1: Write failing packaging contract tests**

```elixir
test "compose is private, persistent, and capability-minimal" do
  compose = YamlElixir.read_from_file!("../deploy/dokploy/compose.yml")
  symphony = compose["services"]["symphony"]
  tailscale = compose["services"]["tailscale"]

  assert symphony["network_mode"] == "service:tailscale"
  refute Map.has_key?(symphony, "ports")
  assert symphony["cap_drop"] == ["ALL"]
  assert tailscale["cap_add"] == ["NET_ADMIN", "NET_RAW"]
  assert Map.keys(compose["volumes"]) |> Enum.sort() ==
           ~w(symphony-codex symphony-state symphony-tailscale symphony-workspaces)
end

test "entrypoint stores no secret in Codex config" do
  script = File.read!("../deploy/dokploy/entrypoint.sh")
  assert script =~ "env_key = \"OMNIROUTE_API_KEY\""
  refute script =~ "echo $OMNIROUTE_API_KEY"
  assert script =~ "flock --exclusive --nonblock"
end
```

- [ ] **Step 2: Run RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/dokploy_packaging_test.exs`

Expected: deployment assets are missing.

- [ ] **Step 3: Create the release image**

Use a pinned Elixir 1.19/OTP 28 Debian builder, `mix deps.get --only prod`, `mix assets.deploy`, and a normal `mix release`. Keep Burrito wrapping conditional on `BURRITO_TARGET` so the existing release workflow remains intact. The runtime installs only CA certificates, Git, OpenSSH client, Bash, `curl`, `flock`, Codex CLI, and the release; create UID/GID `10001` and run as that user.

- [ ] **Step 4: Create the two-service Compose file**

Use the official Tailscale image with `/var/lib/tailscale`, `/dev/net/tun`, `TS_STATE_DIR`, an ephemeral first-enrollment auth key, and `restart: unless-stopped`. Symphony depends on Tailscale health, shares its network namespace, mounts the three Symphony volumes, uses `read_only: true`, `tmpfs: /tmp`, drops all capabilities, and exposes only tailnet port `4021` from the shared namespace.

- [ ] **Step 5: Generate provider config safely**

The generated file contains:

```toml
model_provider = "omniroute"

[model_providers.omniroute]
name = "Private OmniRoute"
base_url = "<validated OMNIROUTE_BASE_URL ending in /v1>"
env_key = "OMNIROUTE_API_KEY"
wire_api = "responses"
```

Validate the base URL as HTTPS with no whitespace/control characters and the model alias as a single non-empty line. Do not render the key.

- [ ] **Step 6: Validate the image and Compose contract**

Run:

```bash
rtk docker compose -f deploy/dokploy/compose.yml config
rtk docker build --pull -t symphony:local .
rtk docker run --rm --entrypoint /app/bin/symphony symphony:local eval 'IO.puts(Application.spec(:symphony_elixir, :vsn))'
```

Expected: Compose config succeeds, image builds, and the release prints version `0.0.2` as non-root.

- [ ] **Step 7: Commit**

Commit: `feat: package Symphony for private Dokploy deployment`

---

### Task 5: Back up and deploy to the Spot VM

**Files:**
- Create: `deploy/dokploy/deploy.ps1`
- Create: `deploy/dokploy/verify.ps1`
- Modify: `deploy/dokploy/README.md`

**Interfaces:**
- `deploy.ps1 -Prepare` performs read-only discovery and creates verified rollback artifacts before API mutation.
- `deploy.ps1 -Deploy` creates or updates only the `Symphony/production` Dokploy Compose application and its secrets.
- `verify.ps1` checks container health, private tailnet access, OmniRoute models/Responses, state volume persistence, and no public listener.

- [ ] **Step 1: Write the deployment scripts in dry-run-first form**

The scripts must resolve the exact project/zone/instance, print resource IDs but never environment values, and stop if the VM identity differs. `-Prepare` starts the stopped Spot VM, runs `sudo sync`, records instance/disk/firewall/Dokploy metadata, creates a timestamped machine image, waits for `READY`, and exports a Dokploy database/config backup to a protected path.

- [ ] **Step 2: Verify rollback before mutation**

Run `deploy.ps1 -Prepare`, then independently query the machine image status and backup size/hash. Abort deployment unless both are present and non-empty.

- [ ] **Step 3: Create the Dokploy project and Compose application**

Use the official Dokploy API or existing authenticated panel session. Create project `Symphony`, environment `production`, one Compose application from the verified branch/commit, the four named volumes, resource limits, restart policy, and no domain. Add secrets only through Dokploy. Set concurrency `1`, the chosen opt-in label, private OmniRoute `/v1` base, and a live alias returned by `/v1/models`.

- [ ] **Step 4: Enroll Tailscale and perform a no-dispatch start**

Use a reusable tagged auth key only for initial sidecar enrollment, then remove it from active container environment after state is persisted. With no eligible Linear issue, verify health, readiness, logs, volumes, tailnet identity, and that public `207.175.141.51:4021` is unreachable.

- [ ] **Step 5: Run the canary and abrupt-recovery drill**

Create or select one disposable issue carrying the opt-in label. Record the workspace/claim snapshot, force-kill the Symphony container during active work, and verify one delayed continuation in the same workspace with no duplicate. Then stop/start the Spot VM and verify Dokploy, Tailscale identity, volumes, claims, budgets, and readiness return.

- [ ] **Step 6: Commit non-secret deployment automation**

Commit: `ops: automate verified Dokploy deployment`

---

### Task 6: Activate private Dokploy MCP and certify end to end

**Files:**
- Create: `deploy/dokploy-mcp/dokploy-mcp.container`
- Create: `deploy/dokploy-mcp/env.example`
- Create: `deploy/dokploy-mcp/install.sh`
- Create: `deploy/dokploy-mcp/verify.sh`
- Create: `deploy/dokploy-mcp/README.md`
- Create: `elixir/test/symphony_elixir/dokploy_mcp_packaging_test.exs`

**Interfaces:**
- The service runs official `@dokploy/mcp` under the existing rootless `airouter` user, listens on `127.0.0.1:3001`, and is published only through Tailscale.
- Upstream `DOKPLOY_URL` uses the Dokploy VM private GCP address on port `3000`.
- Redaction is always on and enabled tags are exactly `project,application,compose,deployment,domain`.

- [ ] **Step 1: Write failing static security tests**

```elixir
test "Dokploy MCP is private and redacted" do
  env = File.read!("../deploy/dokploy-mcp/env.example")
  unit = File.read!("../deploy/dokploy-mcp/dokploy-mcp.container")

  assert env =~ "DOKPLOY_REDACT_ENV=true"
  assert env =~ "DOKPLOY_ENABLED_TAGS=project,application,compose,deployment,domain"
  refute Regex.match?(~r/^DOKPLOY_API_KEY=.+$/m, env)
  assert unit =~ "PublishPort=127.0.0.1:3001:3000"
end
```

- [ ] **Step 2: Run RED, implement minimal rootless service, then run GREEN**

Run: `rtk mise exec -- mix test test/symphony_elixir/dokploy_mcp_packaging_test.exs`

Install one pinned official MCP image/package, a mode-`0600` environment file, bounded timeout/retry settings, and a user service with restart-on-failure. Preserve existing OmniRoute and AgentGateway units and routes.

- [ ] **Step 3: Narrow network access**

Add a GCP/VPS rule permitting Dokploy port `3000` only from the current OmniRoute VM private address. Confirm public port `3000` remains unreachable. Publish `127.0.0.1:3001` through Tailscale Serve or the existing private reverse proxy without changing current dashboard/API routes.

- [ ] **Step 4: Configure the operator Codex client**

Use a Streamable HTTP MCP entry pointing at the private tailnet URL, with write approvals required. Do not add this MCP server to Symphony issue-worker `CODEX_HOME`.

- [ ] **Step 5: Live acceptance**

Verify: tool discovery exposes only approved categories; a read-only project/application list succeeds; environment and Compose fields are redacted; one explicitly approved benign redeploy call succeeds; OmniRoute Responses still succeeds; Symphony canary completes through Linear + Codex; container and VM restart drills preserve exact-once behavior.

- [ ] **Step 6: Run the full source and deployment gates**

Run on Linux:

```bash
rtk mix format --check-formatted
rtk mix compile --warnings-as-errors
rtk mix specs.check
rtk mix credo --strict
rtk mix test
rtk mix dialyzer
rtk mix hex.audit
rtk docker compose -f deploy/dokploy/compose.yml config
```

Run the non-secret deployment verification scripts and `git diff --check`. Record exact pass/fail evidence and leave rollback artifacts retained.

- [ ] **Step 7: Commit final MCP assets and operations evidence**

Commit: `ops: activate private redacted Dokploy MCP`

---

## Completion Checklist

- [ ] Linear + Codex is the deployed profile with concurrency `1` and one opt-in label.
- [ ] OmniRoute provider/model are deployment configuration and use the Responses API through private Tailscale.
- [ ] Controller secrets are absent from the Codex child; the required router credential is present only as an environment variable.
- [ ] Atomic state, durable claims, budgets, retries, and workspaces survive container kill and Spot VM stop/start without duplicate dispatch.
- [ ] Symphony dashboard and Dokploy MCP have no public route.
- [ ] Dokploy owns the Compose application and all four named volumes.
- [ ] The current OmniRoute VM runs redacted, category-filtered Dokploy MCP with write approvals.
- [ ] Machine-image and Dokploy backups are verified and retained.
- [ ] Linux tests, image/Compose checks, live canary, OmniRoute Responses, MCP read/write, and recovery drills have fresh evidence.
