# Application Release Blockers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the current security and correctness release blockers and restore an honest, enforced Linux source gate for the Linear + Codex production profile.

**Architecture:** Keep the existing OTP and adapter boundaries, but make the web surface read-only, isolate child environments, make tool exposure explicit, and enforce workspace containment at the last destructive boundary. Release correctness is proven by clean Ubuntu CI, dependency audit, production assets, and copy/paste-tested CLI documentation.

**Tech Stack:** Elixir 1.19.5/OTP 28, Phoenix 1.8/LiveView, Bandit, Ecto embedded schemas, ExUnit, Credo, Dialyzer, Hex audit, GitHub Actions.

## Global Constraints

- Target Ubuntu 24.04 LTS x86_64; Windows is a documented development platform, not the release authority.
- Initial production profile is Linear + Codex; Prime and other trackers stay experimental.
- Bandit must bind to loopback in production and the production web surface must have no mutation route.
- The default child environment is an allowlist; controller and tracker secrets never reach harness children.
- Provider tools default to disabled; broad provider-native tools require explicit `trusted` mode.
- Every production `def` has an adjacent `@spec` or documented callback exemption.
- Every behavior change follows a witnessed RED-GREEN test cycle.
- Every shell command in this repository is prefixed with `rtk`.

---

## File Structure

- Create `elixir/lib/symphony_elixir/runtime_environment.ex`: production-mode and loopback/origin validation.
- Create `elixir/lib/symphony_elixir/agent_environment.ex`: child environment allowlist and remote `env -i` assignments.
- Create `elixir/lib/symphony_elixir/secret_redactor.ex`: recursive and text redaction for logs/errors.
- Create `elixir/test/symphony_elixir/security_hardening_test.exs`: web, environment, redaction, and public-bind regressions.
- Modify `elixir/lib/symphony_elixir/workflow_store.ex`: delete runtime mutation and hide resolved settings from Inspect output.
- Modify `elixir/lib/symphony_elixir_web/router.ex`: remove mutation routes.
- Modify `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`: remove mutation actions.
- Modify `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`: remove harness mutation UI/event.
- Modify `elixir/lib/symphony_elixir/config/schema.ex`: server URL, environment allowlist, and tool-mode fields.
- Modify `elixir/lib/symphony_elixir/http_server.ex`, `elixir/lib/symphony_elixir_web/endpoint.ex`, and `elixir/config/config.exs`: production web policy.
- Modify both app-server clients and `elixir/lib/symphony_elixir/tracker.ex`: environment/tool policy.
- Modify `elixir/lib/symphony_elixir/workspace.ex` and workspace safety tests: canonical deletion containment.
- Modify `elixir/lib/symphony_elixir/agent_runner.ex` and harness/orchestrator tests: selected-harness propagation.
- Modify dependency/build/CI files and operator documentation.

### Task 1: Remove Runtime Workflow Mutation

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow_store.ex:65-224,270-283`
- Modify: `elixir/lib/symphony_elixir_web/router.ex:25-38`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:26-52`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex:36-59,229-249,864-880`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

**Interfaces:**
- Removes: `WorkflowStore.update_harness/1`, `POST /api/v1/harness`, and LiveView event `select_harness`.
- Preserves: file-watch reload and `WorkflowStore.force_reload/0`.

- [ ] **Step 1: Write route and LiveView regression tests**

```elixir
test "production observability surface has no workflow mutation route", %{conn: conn} do
  conn = post(conn, "/api/v1/harness", %{"harness" => "prime"})
  assert conn.status == 404
  assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(conn.resp_body)
end

test "dashboard renders no harness mutation control" do
  {:ok, _view, html} = live(build_conn(), "/")
  refute html =~ "phx-change=\"select_harness\""
  refute html =~ "Switch execution harness"
end
```

- [ ] **Step 2: Run the focused tests and witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/extensions_test.exs --only web`

Expected: FAIL because `/api/v1/harness` returns a mutation response and the selector is rendered.

- [ ] **Step 3: Delete mutation code and leave the catch-all 404**

Remove both `update_harness/1` clauses and their YAML helpers from `WorkflowStore`; remove the controller action, route, `handle_event("select_harness", ...)`, selector markup, and `update_workflow_harness/1`. Do not replace them with another write path.

- [ ] **Step 4: Run focused tests and the existing reload tests**

Run: `rtk mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/core_test.exs --only web`

Expected: PASS; file-watch and forced read-only reload tests remain green.

- [ ] **Step 5: Commit the removal**

```bash
rtk git add elixir/lib/symphony_elixir/workflow_store.ex elixir/lib/symphony_elixir_web elixir/test/symphony_elixir/extensions_test.exs
rtk git commit -m "fix: make observability workflow read-only"
```

### Task 2: Prevent Secret Disclosure in State and Logs

**Files:**
- Create: `elixir/lib/symphony_elixir/secret_redactor.ex`
- Modify: `elixir/lib/symphony_elixir/workflow_store.ex:15-19`
- Modify: `elixir/lib/symphony_elixir/workspace.ex:448-465`
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex:1033-1059`
- Modify: `elixir/lib/symphony_elixir/prime_agent/app_server.ex:298-319`
- Test: `elixir/test/symphony_elixir/security_hardening_test.exs`

**Interfaces:**
- Produces: `SecretRedactor.redact_text/2 :: String.t()` and `SecretRedactor.redact_term/2 :: term()`.
- `WorkflowStore` keeps functional state but derives an Inspect view containing only path, stamp, and last error.

- [ ] **Step 1: Write redaction and Inspect tests**

```elixir
test "redactor removes configured values recursively" do
  secrets = ["linear-secret", "cookie-secret"]
  assert SecretRedactor.redact_text("token=linear-secret", secrets) == "token=[REDACTED]"
  assert SecretRedactor.redact_term(%{token: "linear-secret", nested: ["cookie-secret"]}, secrets) ==
           %{token: "[REDACTED]", nested: ["[REDACTED]"]}
end

test "workflow store state inspection excludes resolved settings" do
  state = %WorkflowStore{path: "/tmp/workflow", settings: %{tracker: %{api_key: "linear-secret"}}}
  inspected = inspect(state)
  refute inspected =~ "linear-secret"
  refute inspected =~ "api_key"
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/security_hardening_test.exs`

Expected: compilation failure because `SecretRedactor` is undefined and current state inspection exposes settings.

- [ ] **Step 3: Implement recursive exact-value redaction**

```elixir
defmodule SymphonyElixir.SecretRedactor do
  @moduledoc false

  @spec redact_text(String.t(), [String.t()]) :: String.t()
  def redact_text(text, secrets) when is_binary(text) do
    Enum.reduce(valid(secrets), text, &String.replace(&2, &1, "[REDACTED]"))
  end

  @spec redact_term(term(), [String.t()]) :: term()
  def redact_term(value, secrets) when is_binary(value), do: redact_text(value, secrets)
  def redact_term(value, secrets) when is_list(value), do: Enum.map(value, &redact_term(&1, secrets))
  def redact_term(value, secrets) when is_map(value), do: Map.new(value, fn {k, v} -> {k, redact_term(v, secrets)} end)
  def redact_term(value, _secrets), do: value

  defp valid(secrets), do: Enum.filter(secrets, &(is_binary(&1) and byte_size(&1) >= 4))
end
```

Add `@derive {Inspect, only: [:path, :stamp, :last_error]}` immediately before the `WorkflowStore` defstruct. Pass adapter-declared resolved secret values through the redactor before logging hook/protocol payloads.

- [ ] **Step 4: Run tests and specs check**

Run: `rtk mise exec -- mix test test/symphony_elixir/security_hardening_test.exs && rtk mise exec -- mix specs.check`

Expected: PASS with no secret value in captured log or inspected state.

- [ ] **Step 5: Commit redaction**

```bash
rtk git add elixir/lib/symphony_elixir/secret_redactor.ex elixir/lib/symphony_elixir/workflow_store.ex elixir/lib/symphony_elixir/workspace.ex elixir/lib/symphony_elixir/codex/app_server.ex elixir/lib/symphony_elixir/prime_agent/app_server.ex elixir/test/symphony_elixir/security_hardening_test.exs
rtk git commit -m "fix: redact controller secrets from diagnostics"
```

### Task 3: Enforce an Allowlisted Harness Environment

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_environment.ex`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:143-170`
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex:207-274`
- Modify: `elixir/lib/symphony_elixir/prime_agent/app_server.ex:156-224`
- Test: `elixir/test/symphony_elixir/app_server_test.exs`
- Test: `elixir/test/symphony_elixir/prime_agent_app_server_test.exs`

**Interfaces:**
- Adds config: `agent.allowed_environment_variables`, default `[]`.
- Produces: `AgentEnvironment.port_env/2` and `AgentEnvironment.remote_prefix/2`.
- Protected names can never be re-enabled: tracker secrets, `SECRET_KEY_BASE`, `SSH_AUTH_SOCK`, and names matching `TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL`.

- [ ] **Step 1: Write child-environment tests using the fake app server**

```elixir
test "app server child receives allowlisted values but not controller secrets" do
  System.put_env("SYMPHONY_TEST_ALLOWED", "visible")
  System.put_env("UNRELATED_SECRET_TOKEN", "hidden")

  assert {:ok, env} = AgentEnvironment.effective(%{allowed_environment_variables: ["SYMPHONY_TEST_ALLOWED"]}, [])
  assert env["SYMPHONY_TEST_ALLOWED"] == "visible"
  refute Map.has_key?(env, "UNRELATED_SECRET_TOKEN")
  refute Map.has_key?(env, "SSH_AUTH_SOCK")
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/prime_agent_app_server_test.exs`

Expected: FAIL because the module/config field does not exist and children currently inherit the host environment.

- [ ] **Step 3: Implement the fixed allowlist and Port unset list**

```elixir
@base ~w(HOME PATH LANG LC_ALL LC_CTYPE TERM CODEX_HOME)
@protected ~r/(TOKEN|SECRET|PASSWORD|PRIVATE_KEY|CREDENTIAL)/i

@spec effective(map(), [String.t()]) :: {:ok, %{String.t() => String.t()}}
def effective(agent, adapter_secret_names) do
  denied = MapSet.new(adapter_secret_names ++ ["SECRET_KEY_BASE", "SSH_AUTH_SOCK"])
  names = Enum.uniq(@base ++ Map.get(agent, :allowed_environment_variables, []))

  env =
    names
    |> Enum.reject(&(MapSet.member?(denied, &1) or Regex.match?(@protected, &1)))
    |> Map.new(fn name -> {name, System.get_env(name)} end)
    |> Map.reject(fn {_name, value} -> is_nil(value) end)

  {:ok, env}
end

@spec port_env(map(), [String.t()]) :: [{charlist(), charlist() | false}]
def port_env(agent, secret_names) do
  {:ok, allowed} = effective(agent, secret_names)
  Enum.map(System.get_env(), fn {name, _} ->
    value = Map.get(allowed, name)
    {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
  end)
end
```

For remote launch, build `env -i` assignments only from `effective/2`, shell-escape both names and values, then append the harness command. Use the same module from Codex and Prime clients.

- [ ] **Step 4: Verify both harnesses**

Run: `rtk mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/prime_agent_app_server_test.exs`

Expected: PASS; fake children prove allowed value present and secret absent for local and remote command generation.

- [ ] **Step 5: Commit environment isolation**

```bash
rtk git add elixir/lib/symphony_elixir/agent_environment.ex elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/codex/app_server.ex elixir/lib/symphony_elixir/prime_agent/app_server.ex elixir/test/symphony_elixir
rtk git commit -m "fix: allowlist harness child environment"
```

### Task 4: Make Provider Tool Exposure Explicit

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:46-88`
- Modify: `elixir/lib/symphony_elixir/tracker.ex:48-58,106-123`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/linear/agent_tool.ex`
- Test: `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- Test: `elixir/test/symphony_elixir/linear_adapter_test.exs`

**Interfaces:**
- Adds `tracker.agent_tools.mode` with values `disabled` (default), `scoped`, and `trusted`.
- `disabled` advertises no provider tool.
- `trusted` advertises the existing raw provider tool.
- `scoped` is accepted only by Linear and advertises `linear_issue`, whose issue identifier is injected from session context rather than accepted from model input.

- [ ] **Step 1: Write mode and scope tests**

```elixir
test "provider tools default to disabled" do
  write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
  assert Tracker.bind_agent_tools() == []
end

test "scoped Linear tool ignores model-supplied issue identity" do
  binding = Linear.AgentTool.bind(:scoped, %{issue: %{id: "issue-1", identifier: "LIN-1"}})
  assert [%{"name" => "linear_issue"}] = binding.specs
  refute get_in(hd(binding.specs), ["inputSchema", "properties", "issue_id"])
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/linear_adapter_test.exs`

Expected: FAIL because tool mode and `linear_issue` do not exist.

- [ ] **Step 3: Add schema validation and mode dispatch**

```elixir
field(:agent_tools, :map, default: %{"mode" => "disabled"})

mode = provider |> Map.get("agent_tools", %{}) |> Map.get("mode", "disabled")

case {settings.tracker.kind, mode} do
  {_kind, "disabled"} -> []
  {"linear", "scoped"} -> adapter.bind_agent_tools(:scoped)
  {_kind, "trusted"} -> adapter.bind_agent_tools(:trusted)
  _ -> {:error, {:invalid_agent_tool_mode, mode}}
end
```

Implement `linear_issue` with only `get`, `comment`, and `transition` actions. Its executor takes the bound issue from internal context, refreshes it through the configured project before mutation, and rejects a mismatch with `scoped_issue_mismatch`. Keep `linear_graphql` only in `trusted` mode.

- [ ] **Step 4: Run tool and config suites**

Run: `rtk mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/linear_adapter_test.exs test/symphony_elixir/core_test.exs`

Expected: PASS for disabled/scoped/trusted modes and current-issue enforcement.

- [ ] **Step 5: Commit tool policy**

```bash
rtk git add elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/tracker.ex elixir/lib/symphony_elixir/linear elixir/test/symphony_elixir
rtk git commit -m "feat: gate provider tools by trust mode"
```

### Task 5: Harden the Production HTTP Boundary

**Files:**
- Create: `elixir/lib/symphony_elixir/runtime_environment.ex`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:335-351`
- Modify: `elixir/lib/symphony_elixir/http_server.ex:19-113`
- Modify: `elixir/lib/symphony_elixir_web/endpoint.ex:9-49`
- Modify: `elixir/config/config.exs:7-20`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

**Interfaces:**
- Adds `server.external_url`, required HTTPS when production HTTP is enabled.
- Produces `RuntimeEnvironment.production?/0`, `validate_bind/2`, and `check_origin/1`.
- Production accepts only `127.0.0.1`, `::1`, or parsed loopback tuples.
- Endpoint accepts JSON/urlencoded bodies up to 65,536 bytes; multipart and method override are removed.

- [ ] **Step 1: Write fail-closed server tests**

```elixir
test "production rejects a public bind" do
  System.put_env("MIX_ENV", "prod")
  assert {:error, :production_bind_must_be_loopback} = RuntimeEnvironment.validate_bind("0.0.0.0", "https://symphony.example.com")
end

test "production requires an HTTPS external URL" do
  System.put_env("MIX_ENV", "prod")
  assert {:error, :production_external_url_must_be_https} = RuntimeEnvironment.validate_bind("127.0.0.1", "http://symphony.example.com")
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/extensions_test.exs`

Expected: FAIL because public binding and missing external URL are currently accepted.

- [ ] **Step 3: Implement validation and runtime endpoint options**

```elixir
@spec validate_bind(String.t(), String.t() | nil) :: :ok | {:error, atom()}
def validate_bind(host, external_url) do
  cond do
    not production?() -> :ok
    host not in ["127.0.0.1", "::1", "localhost"] -> {:error, :production_bind_must_be_loopback}
    not https_url?(external_url) -> {:error, :production_external_url_must_be_https}
    true -> :ok
  end
end
```

Call validation before `Endpoint.start_link/0`; derive `url`, `check_origin: [external_url]`, and secure session behavior from the parsed external URL. Configure Plug.Parsers with `length: 65_536`, parsers `[:urlencoded, :json]`, and remove `Plug.MethodOverride`.

- [ ] **Step 4: Run endpoint tests**

Run: `rtk mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/observability_pubsub_test.exs`

Expected: PASS for loopback/HTTPS and request-limit behavior.

- [ ] **Step 5: Commit web hardening**

```bash
rtk git add elixir/lib/symphony_elixir/runtime_environment.ex elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/http_server.ex elixir/lib/symphony_elixir_web/endpoint.ex elixir/config/config.exs elixir/test/symphony_elixir
rtk git commit -m "fix: fail closed on unsafe production HTTP"
```

### Task 6: Enforce Workspace Containment and Preservation

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex:137-168,468-564`
- Modify: `elixir/lib/symphony_elixir/path_safety.ex`
- Test: `elixir/test/symphony_elixir/workspace_safety_hardening_gap_test.exs`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- `Workspace.remove_recorded/2` validates against `Config.local_workspace_root/0`, not `dirname(path)`.
- Remote validation returns a canonical absolute root and child path from `realpath -m` and refuses the root itself.
- A failing `before_remove` hook returns `{:error, {:before_remove_failed, reason}}` and preserves the workspace.

- [ ] **Step 1: Add adversarial deletion tests**

```elixir
test "remove_recorded refuses an absolute path outside configured root" do
  assert {:error, {:invalid_workspace_path, :outside_workspace_root, _, _}} =
           Workspace.remove_recorded("/var/lib/unrelated", nil)
end

test "before_remove failure preserves workspace" do
  assert {:error, {:before_remove_failed, _}} = Workspace.remove(issue, nil)
  assert File.dir?(workspace_path)
end
```

Include root-itself, `..`, separator, symlink escape, and remote canonical mismatch cases.

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/workspace_safety_hardening_gap_test.exs`

Expected: FAIL because recorded-path containment is tautological and cleanup ignores hook failure.

- [ ] **Step 3: Validate against configured roots immediately before removal**

Route local paths through `PathSafety.canonicalize_under_root(path, Config.local_workspace_root(), allow_root?: false)`. For remote removal, execute one quoted script that obtains canonical root/child, checks `child != root` and `child` begins with `root <> "/"`, then runs the hook and `rm -rf -- "$child"` only inside the guarded branch.

- [ ] **Step 4: Run complete workspace suites**

Run: `rtk mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/workspace_safety_hardening_gap_test.exs test/symphony_elixir/ssh_test.exs`

Expected: PASS with no deletion outside the configured root.

- [ ] **Step 5: Commit workspace hardening**

```bash
rtk git add elixir/lib/symphony_elixir/workspace.ex elixir/lib/symphony_elixir/path_safety.ex elixir/test/symphony_elixir
rtk git commit -m "fix: enforce workspace containment before deletion"
```

### Task 7: Preserve the Selected Harness End to End

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex:22-87`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex:954-1060`
- Test: `elixir/test/symphony_elixir/harness_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

**Interfaces:**
- `AgentRunner.run/3` consumes `opts[:harness]` and emits the same value in `worker_runtime_info`.
- Orchestrator running, blocked, timeout, and snapshot metadata use that selected value.

- [ ] **Step 1: Write a real dispatch propagation test**

```elixir
test "label-selected Prime harness reaches runner metadata and timeout selection" do
  issue = issue_fixture(labels: ["harness:prime"])
  assert {:ok, %{harness: "prime"}} = dispatch_and_capture_runtime_info(issue)
  assert snapshot_running_entry(issue.id).harness == "prime"
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/harness_test.exs test/symphony_elixir/orchestrator_status_test.exs`

Expected: FAIL because AgentRunner reports `Harness.current_kind/0` instead of `opts[:harness]`.

- [ ] **Step 3: Use the dispatch-selected value**

```elixir
selected_harness = Keyword.fetch!(opts, :harness)
send_worker_runtime_info(orchestrator, issue.id, worker_host, workspace_path, selected_harness)
Harness.run(selected_harness, workspace_path, prompt, harness_opts)
```

Delete tests that duplicate the private selector and assert through dispatch instead.

- [ ] **Step 4: Run harness and stall suites**

Run: `rtk mise exec -- mix test test/symphony_elixir/harness_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/orchestrator_stall_claimed_test.exs`

Expected: PASS for Codex and Prime selection.

- [ ] **Step 5: Commit propagation fix**

```bash
rtk git add elixir/lib/symphony_elixir/agent_runner.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir
rtk git commit -m "fix: preserve selected harness metadata"
```

### Task 8: Clear Dependency Advisories and Enforce the Audit

**Files:**
- Modify: `elixir/mix.exs`
- Modify: `elixir/mix.lock`
- Modify: `elixir/Makefile`
- Modify: `.github/workflows/make-all.yml`

**Interfaces:**
- Adds `make audit` running `mix hex.audit`.
- `make all` and CI fail on any unignored Hex advisory.

- [ ] **Step 1: Record the failing advisory gate**

Run: `rtk mise exec -- mix hex.audit`

Expected: FAIL with the current Bandit/Phoenix/Plug/Req/Mint/HPAX advisories.

- [ ] **Step 2: Raise compatible direct constraints and update the lock**

Update direct requirements to patched compatible releases discovered by `mix hex.outdated`; then run:

```bash
rtk mise exec -- mix deps.update bandit phoenix phoenix_live_view req ecto solid yaml_elixir burrito
rtk mise exec -- mix deps.unlock --unused
```

Do not add an advisory ignore without a linked, expiry-dated security decision in the repository.

- [ ] **Step 3: Add the audit Make target**

```make
.PHONY: audit

audit:
	$(MIX) hex.audit

ci:
	$(MAKE) setup
	$(MAKE) audit
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer
```

- [ ] **Step 4: Verify dependency, compile, and unit behavior**

Run: `rtk mise exec -- mix hex.audit && rtk mise exec -- mix compile --warnings-as-errors && rtk mise exec -- mix test`

Expected: PASS with zero advisories and zero deterministic test failures on Ubuntu.

- [ ] **Step 5: Commit patched dependencies**

```bash
rtk git add elixir/mix.exs elixir/mix.lock elixir/Makefile .github/workflows/make-all.yml
rtk git commit -m "build: block releases with vulnerable dependencies"
```

### Task 9: Restore an Honest Portable Quality Gate

**Files:**
- Create: `.gitattributes`
- Modify: `elixir/.gitattributes`
- Modify: `elixir/mix.exs:11-45`
- Modify: Credo-reported source files
- Modify: affected ExUnit fixtures and snapshots
- Modify: `.github/workflows/make-all.yml`

**Interfaces:**
- LF is enforced for source/config/docs.
- Coverage includes production-critical modules and uses an honest global threshold of 80%.
- Ubuntu 24.04 is a required source-gate job with timeout and concurrency cancellation.

- [ ] **Step 1: Add LF policy and normalize tracked text**

```gitattributes
* text=auto
*.ex text eol=lf
*.exs text eol=lf
*.md text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
*.sh text eol=lf
Makefile text eol=lf
```

Run: `rtk git add --renormalize .`

Expected: only line-ending changes plus deliberate source edits.

- [ ] **Step 2: Remove critical coverage ignores and set 80%**

Keep generated Phoenix helpers ignored, but remove Orchestrator, Workspace, WorkflowStore, AgentRunner, both app-server clients, HttpServer, Presenter, controller, and router from `ignore_modules`; set `threshold: 80`.

- [ ] **Step 3: Resolve each non-EOL Credo finding without changing behavior**

Run: `rtk mise exec -- mix credo --strict`

Expected before edits: the recorded 6 readability and 9 refactoring findings. Split `format_rate_limit_bucket/1`, flatten workflow/orchestrator conditions, order aliases, and wrap long lines; rerun until exit 0.

- [ ] **Step 4: Run the full clean source gate on Ubuntu**

Run: `rtk mise exec -- make all`

Expected: exit 0; format, specs, Credo, 328-plus deterministic tests, at least 80% honest coverage, Dialyzer, and audit all pass.

- [ ] **Step 5: Harden CI execution**

Add `timeout-minutes: 30`, concurrency cancellation keyed by workflow/ref, explicit Ubuntu 24.04, and an Elixir/OTP-aware cache key. Make this workflow the documented required check.

- [ ] **Step 6: Commit quality restoration**

```bash
rtk git add .gitattributes elixir/.gitattributes elixir/mix.exs elixir/lib elixir/test .github/workflows/make-all.yml
rtk git commit -m "test: restore portable production quality gate"
```

### Task 10: Fix Build Assets, CLI Contract, and Production Documentation

**Files:**
- Modify: `elixir/mix.exs:95-114`
- Modify: `elixir/lib/symphony_elixir/cli.ex:79-126`
- Modify: `elixir/README.md`
- Create: `elixir/WORKFLOW.production.example.md`
- Test: `elixir/test/symphony_elixir/cli_test.exs`

**Interfaces:**
- Usage always shows the required acknowledgement flag for run mode.
- `mix release.prepare` runs audit and `assets.deploy` before Burrito packaging.
- Production example uses Linear scoped tools, one opt-in label, concurrency one, and no environment inheritance.

- [ ] **Step 1: Write CLI usage assertions**

```elixir
test "run usage includes mandatory acknowledgement" do
  assert CLI.usage_message() =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
end
```

- [ ] **Step 2: Witness RED**

Run: `rtk mise exec -- mix test test/symphony_elixir/cli_test.exs`

Expected: FAIL because current usage and README examples omit the switch.

- [ ] **Step 3: Add a release preparation alias**

```elixir
"release.prepare": ["hex.audit", "assets.deploy"]
```

Make the release workflow call `mix release.prepare` before `mix release`.

- [ ] **Step 4: Write the production example with exact safe defaults**

The front matter must contain `required_labels: [symphony-ready]`, `max_concurrent_agents: 1`, `agent_tools.mode: scoped`, the granular all-false approval map, loopback server host, HTTPS external URL example, and no `inherit=all`. The prompt must use `linear_issue`, not raw `linear_graphql`.

- [ ] **Step 5: Verify docs commands and production build inputs**

Run: `rtk mise exec -- mix test test/symphony_elixir/cli_test.exs && rtk mise exec -- mix release.prepare`

Expected: PASS and `elixir/priv/static/cache_manifest.json` exists.

- [ ] **Step 6: Commit the operator contract**

```bash
rtk git add elixir/mix.exs elixir/lib/symphony_elixir/cli.ex elixir/README.md elixir/WORKFLOW.production.example.md elixir/test/symphony_elixir/cli_test.exs
rtk git commit -m "docs: publish safe production startup profile"
```

## Workstream Verification

Run from a fresh Ubuntu 24.04 checkout:

```bash
rtk mise install
rtk mise exec -- make all
rtk mise exec -- mix release.prepare
rtk mise exec -- mix hex.audit
rtk git diff --check
```

Acceptance: all commands exit 0, no web mutation route exists, secrets are absent from child/log/crash tests, public production binding fails, workspace attack tests pass, and the production example validates.
