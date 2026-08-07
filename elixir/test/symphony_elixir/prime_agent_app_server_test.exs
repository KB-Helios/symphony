defmodule SymphonyElixir.PrimeAgentAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrimeAgent.AppServer, as: PrimeAppServer

  defp wsl_path(path) when is_binary(path) do
    # Translate Windows C:/... to /mnt/c/... for WSL bash (which is what
    # System.find_executable("bash") returns on Windows). On non-Windows leave as-is.
    case Regex.run(~r/^([A-Za-z]):\/(.*)/, path) do
      [_, drive, rest] -> "/mnt/#{String.downcase(drive)}/#{rest}"
      _ -> path
    end
  end

  @tag :skip_on_windows
  test "prime run_turn sends prompt before awaiting completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-prime-run-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces") |> String.replace("\\", "/")
      workspace = Path.join(test_root, "workspaces/MT-PRIME") |> String.replace("\\", "/")
      File.mkdir_p!(workspace)

      trace_file = Path.join(test_root, "prime.trace") |> String.replace("\\", "/")
      fake_prime = Path.join(test_root, "fake-prime") |> String.replace("\\", "/")
      trace_file_wsl = wsl_path(trace_file)
      fake_prime_wsl = wsl_path(fake_prime)

      # Fake prime: waits for a prompt line on stdin, logs it, then emits agent_end.
      # Before fix, no prompt is sent => it blocks until harness timeout => trace stays empty.
      File.write!(fake_prime, """
      #!/bin/sh
      trace_file="#{trace_file_wsl}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"type":"agent_end","payload":{}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_prime, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        harness_kind: "prime",
        prime_command: fake_prime_wsl,
        codex_turn_timeout_ms: 5_000
      )

      # Inject short prime turn timeout so the failing case does not hang for 1h.
      # TestSupport workflow_content does not expose prime timeouts, so patch the file.
      workflow_content = File.read!(Workflow.workflow_file_path())

      unless String.contains?(workflow_content, "prime:\n  command:") do
        flunk("Expected workflow to contain 'prime:\\n  command:' marker for patching")
      end

      patched =
        String.replace(
          workflow_content,
          "prime:\n  command:",
          "prime:\n  turn_timeout_ms: 800\n  command:"
        )

      unless String.contains?(patched, "turn_timeout_ms: 800") do
        flunk("Workflow patching failed: expected patched workflow to contain 'turn_timeout_ms: 800'")
      end

      File.write!(Workflow.workflow_file_path(), patched)
      WorkflowStore.force_reload()

      issue = %Issue{
        id: "issue-prime-prompt",
        identifier: "MT-PRIME",
        title: "Validate prime prompt delivery",
        description: "Ensure prime harness sends prompt before awaiting completion",
        state: "In Progress",
        url: "https://example.org/issues/MT-PRIME",
        labels: []
      }

      prompt = "hello prime prompt #{System.unique_integer([:positive])}"

      result = PrimeAppServer.run(workspace, prompt, issue)

      assert {:ok, %{result: :turn_completed, session_id: session_id, thread_id: thread_id, turn_id: "1"}} =
                result

      assert is_binary(session_id)
      assert is_binary(thread_id)

      trace = File.read!(trace_file)
      assert trace =~ prompt, "expected trace to contain prompt #{inspect(prompt)}, got: #{inspect(trace)}"
      assert trace =~ "\"type\"", "expected prompt JSON to contain type field, got: #{inspect(trace)}"
      assert trace =~ "prompt", "expected prompt payload, got: #{inspect(trace)}"
    after
      File.rm_rf(test_root)
    end
  end

  @tag :skip_on_windows
  test "prime run_turn return tuple matches harness contract" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-prime-run-turn-contract-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces") |> String.replace("\\", "/")
      workspace = Path.join(test_root, "workspaces/MT-PRIME-CONTRACT") |> String.replace("\\", "/")
      File.mkdir_p!(workspace)

      trace_file = Path.join(test_root, "prime.contract.trace") |> String.replace("\\", "/")
      fake_prime = Path.join(test_root, "fake-prime-contract") |> String.replace("\\", "/")

      File.write!(fake_prime, """
      #!/bin/sh
      trace_file="#{trace_file}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        printf '%s\\n' '{"type":"turn_end","payload":{}}'
        exit 0
      done
      """)

      File.chmod!(fake_prime, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        harness_kind: "prime",
        prime_command: fake_prime
      )

      workflow_content = File.read!(Workflow.workflow_file_path())

      unless String.contains?(workflow_content, "prime:\n  command:") do
        flunk("Expected workflow to contain 'prime:\\n  command:' marker for patching")
      end

      patched =
        String.replace(
          workflow_content,
          "prime:\n  command:",
          "prime:\n  turn_timeout_ms: 800\n  command:"
        )

      unless String.contains?(patched, "turn_timeout_ms: 800") do
        flunk("Workflow patching failed: expected patched workflow to contain 'turn_timeout_ms: 800'")
      end

      File.write!(Workflow.workflow_file_path(), patched)
      WorkflowStore.force_reload()

      issue = %Issue{
        id: "issue-prime-contract",
        identifier: "MT-PRIME-CONTRACT",
        title: "Validate harness contract",
        description: "Contract check",
        state: "In Progress",
        url: "https://example.org/issues/MT-PRIME-CONTRACT",
        labels: []
      }

      assert {:ok, result_map} = PrimeAppServer.run(workspace, "contract prompt", issue)
      assert Map.has_key?(result_map, :result)
      assert Map.has_key?(result_map, :session_id)
      assert Map.has_key?(result_map, :thread_id)
      assert Map.has_key?(result_map, :turn_id)
      assert result_map.turn_id == "1"
      assert result_map.result == :turn_completed
    after
      File.rm_rf(test_root)
    end
  end
end
