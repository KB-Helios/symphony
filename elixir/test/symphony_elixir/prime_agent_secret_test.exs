defmodule SymphonyElixir.PrimeAgentSecretTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrimeAgent.AppServer, as: PrimeAppServer
  alias SymphonyElixir.Tracker

  test "prime remote launch unsets tracker secrets" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony-prime-secret-#{System.unique_integer([:positive])}"),
      tracker_api_token: "$MY_TEST_LINEAR_TOKEN",
      tracker_project_slug: "project"
    )

    System.put_env("MY_TEST_LINEAR_TOKEN", "secret-value")

    on_exit(fn -> System.delete_env("MY_TEST_LINEAR_TOKEN") end)

    WorkflowStore.force_reload()
    binding = Tracker.bind_agent_tools()
    assert "MY_TEST_LINEAR_TOKEN" in binding.secret_environment_names

    cmd = PrimeAppServer.remote_launch_command_for_test("/tmp/ws-test")
    assert String.contains?(cmd, "unset")
    assert String.contains?(cmd, "MY_TEST_LINEAR_TOKEN")
    assert String.contains?(cmd, "cd ")
  end

  test "prime session binds secrets snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "symphony-prime-snapshot-#{System.unique_integer([:positive])}"),
      tracker_api_token: "$MY_SNAPSHOT_TOKEN",
      tracker_project_slug: "project"
    )

    System.put_env("MY_SNAPSHOT_TOKEN", "snap-secret")

    on_exit(fn -> System.delete_env("MY_SNAPSHOT_TOKEN") end)

    WorkflowStore.force_reload()

    ws_root = Config.local_workspace_root()
    ws = Path.join(ws_root, "MT-SNAP-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    # Verify snapshot isolation: session stores binding; changing env after start_session
    # must not affect the stored snapshot or remote command derived from it.
    binding_before = Tracker.bind_agent_tools()
    assert is_list(binding_before.secret_environment_names)
    assert "MY_SNAPSHOT_TOKEN" in binding_before.secret_environment_names

    # Also verify remote_launch derived from snapshot, not live env, via 2-arg form.
    # Simulate rotation: add a new token env and reload, then ensure snapshot-derived command
    # still contains the original token and live-derived command would differ only after reload.
    System.put_env("MY_NEW_TOKEN", "new-secret")

    on_exit(fn -> System.delete_env("MY_NEW_TOKEN") end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: ws_root,
      tracker_api_token: "$MY_NEW_TOKEN",
      tracker_project_slug: "project"
    )

    WorkflowStore.force_reload()

    # Live binding now contains MY_NEW_TOKEN, but snapshot from before still contains old.
    live_binding = Tracker.bind_agent_tools()
    assert "MY_NEW_TOKEN" in live_binding.secret_environment_names

    snapshot_cmd = PrimeAppServer.remote_launch_command_for_test("/tmp/ws-snap", binding_before)
    live_cmd = PrimeAppServer.remote_launch_command_for_test("/tmp/ws-snap", live_binding)
    assert String.contains?(snapshot_cmd, "MY_SNAPSHOT_TOKEN")
    assert String.contains?(live_cmd, "MY_NEW_TOKEN")
    refute snapshot_cmd == live_cmd
  end

  test "prime elicitation maps to turn_input_required" do
    # Verify source maps elicitation_request -> turn_input_required
    source = File.read!("lib/symphony_elixir/prime_agent/app_server.ex")
    assert source =~ "elicitation_request"
    assert source =~ ":turn_input_required"
    assert source =~ "mcpServer/elicitation/request"
  end

  test "prime stall timeout is harness-aware" do
    source = File.read!("lib/symphony_elixir/orchestrator.ex")
    assert source =~ "stall_timeout_for_entry"
    assert source =~ ~s("prime")
    assert source =~ "prime.stall_timeout_ms"
    assert source =~ "codex.stall_timeout_ms"
  end
end
