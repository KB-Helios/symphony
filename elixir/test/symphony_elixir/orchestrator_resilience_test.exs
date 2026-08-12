defmodule SymphonyElixir.OrchestratorResilienceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RuntimeState, StateStore}

  defmodule FailingStateStore do
    def load(_path), do: {:ok, nil}
    def save(_path, _snapshot), do: {:error, :state_write_failed}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000,
      max_concurrent_agents: 1,
      tracker_required_labels: []
    )

    state_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-state-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(state_root)
    on_exit(fn -> File.rm_rf(state_root) end)
    %{state_path: Path.join(state_root, "state.json")}
  end

  test "writes the running claim before invoking the worker", %{state_path: state_path} do
    issue = issue("issue-claim", "SYM-CLAIM")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    parent = self()

    runner = fn started_issue, _recipient, _opts ->
      send(parent, {:worker_observed_state, started_issue.id, StateStore.load(state_path)})
      :ok
    end

    pid = start_orchestrator!(state_path: state_path, runner: runner)

    assert_receive {:worker_observed_state, "issue-claim",
                    {:ok,
                     %{
                       "claims" => %{
                         "issue-claim" => %{"status" => "running", "identifier" => "SYM-CLAIM"}
                       }
                     }}},
                   1_000

    stop_orchestrator(pid)
  end

  test "restores an interrupted claim once after the recovery backoff", %{state_path: state_path} do
    issue = issue("issue-recover", "SYM-RECOVER")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    snapshot =
      RuntimeState.from_orchestrator(
        %{
          running: %{
            issue.id => %{
              identifier: issue.identifier,
              issue: issue,
              harness: "codex",
              retry_attempt: 1,
              workspace_path: "/var/lib/symphony/workspaces/SYM-RECOVER",
              started_at: ~U[2026-08-12 08:00:00Z]
            }
          },
          retry_attempts: %{},
          blocked: %{},
          completed: MapSet.new(),
          draining: false
        },
        ~U[2026-08-12 08:01:00Z]
      )

    assert :ok = StateStore.save(state_path, snapshot)
    parent = self()

    runner = fn started_issue, _recipient, opts ->
      send(parent, {:recovered, started_issue.id, opts})
      :ok
    end

    pid =
      start_orchestrator!(
        state_path: state_path,
        runner: runner,
        recovery_backoff_ms: 100
      )

    refute_receive {:recovered, _, _}, 60
    assert_receive {:recovered, "issue-recover", opts}, 1_000
    assert opts[:workspace_path] == "/var/lib/symphony/workspaces/SYM-RECOVER"
    refute_receive {:recovered, "issue-recover", _}, 250

    stop_orchestrator(pid)
  end

  test "state write failure disables dispatch and readiness", %{state_path: state_path} do
    issue = issue("issue-full", "SYM-FULL")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    parent = self()
    runner = fn started_issue, _recipient, _opts -> send(parent, {:started, started_issue.id}) end

    pid =
      start_orchestrator!(
        state_path: state_path,
        state_store: FailingStateStore,
        runner: runner
      )

    refute_receive {:started, _}, 250

    assert %{
             ready?: false,
             dispatch_enabled: false,
             persistence: {:error, :state_write_failed}
           } = Orchestrator.health(pid)

    stop_orchestrator(pid)
  end

  test "model router outage prevents dispatch and readiness", %{state_path: state_path} do
    issue = issue("issue-router-down", "SYM-ROUTER-DOWN")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    parent = self()
    runner = fn started_issue, _recipient, _opts -> send(parent, {:started, started_issue.id}) end

    pid =
      start_orchestrator!(
        state_path: state_path,
        router_check: fn -> {:error, :router_unreachable} end,
        runner: runner
      )

    refute_receive {:started, _}, 250

    assert %{
             ready?: false,
             model_router: {:error, :router_unreachable}
           } = Orchestrator.health(pid)

    stop_orchestrator(pid)
  end

  test "drain persists the non-ready state and stops future polling", %{state_path: state_path} do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_orchestrator!(state_path: state_path)

    assert eventually(fn -> Orchestrator.health(pid).last_tracker_poll_success_at != nil end)
    assert :ok = Orchestrator.drain(pid, 1_000)

    assert %{
             ready?: false,
             draining: true,
             dispatch_enabled: false,
             persistence: :ok
           } = Orchestrator.health(pid)

    assert {:ok, %{"draining" => true}} = StateStore.load(state_path)
    stop_orchestrator(pid)
  end

  defp start_orchestrator!(opts) do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(Keyword.put(opts, :name, name))
    pid
  end

  defp stop_orchestrator(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Durable issue #{identifier}",
      description: "Exercise durable scheduling",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: [],
      blocked_by: [],
      dispatchable: true
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
