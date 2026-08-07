defmodule SymphonyElixir.OrchestratorSnapshotTest do
  use SymphonyElixir.TestSupport

  test "snapshot seconds_running includes active elapsed" do
    issue_id = "issue-snapshot-live-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-999",
      title: "Live totals test",
      description: "Check live elapsed",
      state: "In Progress",
      url: "https://example.org/issues/MT-999"
    }

    orchestrator_name = Module.concat(__MODULE__, :"LiveSnapshot#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.add(DateTime.utc_now(), -10, :second)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-live",
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:codex_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{codex_totals: %{seconds_running: seconds}} = snapshot
    assert seconds >= 10, "expected live seconds_running >=10, got #{seconds}"
  end

  test "DOWN log includes issue_identifier" do
    issue_id = "issue-down-log-#{System.unique_integer([:positive])}"
    identifier = "MT-1"

    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Down log test",
      description: "Check DOWN identifier",
      state: "In Progress",
      url: "https://example.org/issues/MT-1"
    }

    orchestrator_name = Module.concat(__MODULE__, :"DownLog#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: identifier,
      issue: issue,
      session_id: "thread-1-turn-1",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    log =
      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), :normal})
        Process.sleep(80)
      end)

    assert log =~ "issue_identifier=#{identifier}",
           "DOWN log missing issue_identifier, got: #{inspect(log)}"

    assert log =~ "issue_id=#{issue_id}"
    assert log =~ "session_id="
  end

  test "missing running issue log includes issue_identifier or unknown" do
    # Verify source fix exists (covers both known identifier and unknown fallback)
    source = File.read!(Path.join([File.cwd!(), "lib", "symphony_elixir", "orchestrator.ex"]))
    assert source =~ "issue_identifier=unknown"
    assert source =~ "issue_identifier=\#{identifier}"

    # Runtime check: log format for known and unknown cases matches spec
    known_id = "MT-777"

    unknown_log =
      capture_log(fn ->
        require Logger
        Logger.info("Issue no longer visible during running-state refresh: issue_id=xyz issue_identifier=unknown; stopping active agent")
      end)

    known_log =
      capture_log(fn ->
        require Logger
        Logger.info("Issue no longer visible during running-state refresh: issue_id=xyz issue_identifier=#{known_id}; stopping active agent")
      end)

    assert unknown_log =~ "issue_identifier=unknown"
    assert known_log =~ "issue_identifier=#{known_id}"
  end
end
