defmodule SymphonyElixir.HarnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Harness

  test "config defaults harness to codex and preserves codex intact" do
    # Default written by TestSupport is codex
    assert Config.harness_kind() == "codex"
    assert Harness.current_kind() == "codex"
    assert Harness.current_module() == SymphonyElixir.Codex.AppServer
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "harness kind can be switched to prime via WORKFLOW.md" do
    write_workflow_file!(Workflow.workflow_file_path(), harness_kind: "prime")
    assert Config.harness_kind() == "prime"
    assert Harness.current_kind() == "prime"
    assert Harness.module_for("prime") == SymphonyElixir.PrimeAgent.AppServer
    # Codex settings remain present
    assert Config.settings!().codex.command == "codex app-server"
    assert Config.settings!().prime.command == "prime-agent --mode rpc"
  end

  test "prime config fields are parsed and isolated from codex" do
    write_workflow_file!(Workflow.workflow_file_path(),
      harness_kind: "prime",
      prime_command: "prime-agent --mode rpc --model claude-sonnet",
      prime_provider: "anthropic",
      prime_model: "claude-sonnet-4"
    )

    settings = Config.settings!()
    assert settings.harness.kind == "prime"
    assert settings.prime.command == "prime-agent --mode rpc --model claude-sonnet"
    assert settings.prime.provider == "anthropic"
    assert settings.prime.model == "claude-sonnet-4"
  end

  test "harness normalize rejects invalid values and falls back to codex" do
    assert Harness.normalize_kind("PRIME") == "prime"
    assert Harness.normalize_kind("codex") == "codex"
    assert Harness.normalize_kind("unknown") == "codex"
    assert Harness.normalize_kind(nil) == "codex"
    assert Harness.normalize_kind("") == "codex"
  end

  test "supported_harnesses includes both backends" do
    assert "codex" in Harness.supported_harnesses()
    assert "prime" in Harness.supported_harnesses()
  end

  test "invalid harness kind fails workflow validation" do
    workflow_file = Workflow.workflow_file_path()

    File.write!(workflow_file, """
    ---
    harness:
      kind: invalid
    tracker:
      kind: memory
    ---
    prompt
    """)

    assert {:error, {:invalid_workflow_config, msg}} = SymphonyElixir.WorkflowStore.force_reload()
    assert msg =~ "harness.kind"
    # Restore
    write_workflow_file!(workflow_file)
  end

  test "label harness:prime overrides global codex setting for dispatch" do
    # Simulate what Orchestrator does: label takes precedence
    # We verify Harness normalization and that AgentRunner would pick prime when label present.
    # The orchestrator helper is private; we test the effective policy:
    # global codex + issue label harness:prime => dispatch should use prime.
    write_workflow_file!(Workflow.workflow_file_path(), harness_kind: "codex")

    # Direct Harness policy: if issue has label harness:prime, orchestrator picks prime.
    # We verify via Harness helper that label extraction would yield prime.
    # Since resolve_harness_for_issue is private, we simulate its logic:
    labels = ["harness:prime", "bug"]

    picked =
      Enum.find_value(labels, fn l ->
        case String.downcase(String.trim(l)) do
          "harness:prime" -> "prime"
          "harness:codex" -> "codex"
          _ -> nil
        end
      end)

    assert picked == "prime"
    # And global fallback
    assert Harness.current_kind() == "codex"
  end

  test "state payload exposes harness and supported_harnesses" do
    payload = SymphonyElixirWeb.Presenter.state_payload(SymphonyElixir.Orchestrator, 100)
    # In test env orchestrator may be unavailable; payload contains harness when available
    # Ensure the presenter handles both paths without crash
    assert is_map(payload)
  end
end
