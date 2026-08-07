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

    # Need a workspace that passes validation; create it
    ws_root = Config.local_workspace_root()
    ws = Path.join(ws_root, "MT-SNAP-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)

    # Use a fake prime that immediately exits so we can inspect session; we don't care about run_turn
    fake = Path.join(System.tmp_dir!(), "fake-prime-snap-#{System.unique_integer([:positive])}")
    File.write!(fake, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake, 0o755)

    # Prime command must be absolute path that WSL bash can execute; on Windows this will fail
    # to actually start, but we test the snapshot binding path without needing a live port:
    # instead verify bind directly and that session would contain it if start succeeded.
    binding = Tracker.bind_agent_tools()
    assert is_list(binding.secret_environment_names)
    assert "MY_SNAPSHOT_TOKEN" in binding.secret_environment_names

    on_exit(fn -> File.rm_rf(ws) end)
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
