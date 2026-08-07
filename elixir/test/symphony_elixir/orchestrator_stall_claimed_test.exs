defmodule SymphonyElixir.OrchestratorStallClaimedTest do
  use SymphonyElixir.TestSupport

  test "stalled non-blocked issue stays claimed during backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1
    )

    issue_id = "id-1"
    stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    # Direct state test: call reconcile_stalled_running_issues via test helper
    # to avoid poll-cycle re-dispatch masking the claimed bug.
    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "MT-1",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-1",
            title: "t",
            state: "Todo",
            dispatchable: true,
            labels: [],
            blocked_by: [],
            url: "https://example.org/issues/MT-1"
          },
          session_id: "thread-stall",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          started_at: stale_at
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      blocked: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      task_supervisor: SymphonyElixir.TaskSupervisor
    }

    next_state = Orchestrator.reconcile_stalled_running_issues_for_test(state)

    # Stall non-blocked path should remove from running, add to retry, but KEEP claimed per spec §7.1/7.4/8.5
    refute Map.has_key?(next_state.running, issue_id),
           "expected running to NOT contain #{issue_id} after stall restart"

    assert Map.has_key?(next_state.retry_attempts, issue_id),
           "expected retry_attempts to contain #{issue_id}, got: #{inspect(next_state.retry_attempts)}"

    assert MapSet.member?(next_state.claimed, issue_id),
           "expected claimed to still contain #{issue_id} during backoff (spec §7.1/8.5 claimed = running ∪ RetryQueued), got: #{inspect(next_state.claimed)}"

    refute Process.alive?(worker_pid)

    # Invariant check: claimed = running ∪ RetryQueued
    assert MapSet.member?(next_state.claimed, issue_id) ==
             (Map.has_key?(next_state.running, issue_id) or
                Map.has_key?(next_state.retry_attempts, issue_id)),
           "claimed invariant violated"

    # Also verify blocked path still retains claimed (sanity)
    # Cleanup retry timer to avoid stray messages
    Enum.each(next_state.retry_attempts, fn {_id, %{timer_ref: ref}} ->
      if is_reference(ref), do: Process.cancel_timer(ref)
    end)

    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
  end
end
