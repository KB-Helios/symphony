defmodule SymphonyElixir.StateStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RuntimeState, StateStore}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-state-store-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{path: Path.join(root, "state.json")}
  end

  test "missing state starts empty", %{path: path} do
    assert {:ok, nil} = StateStore.load(path)
  end

  test "round trips a schema-versioned durable snapshot", %{path: path} do
    snapshot = %{
      "version" => 1,
      "saved_at" => "2026-08-12T08:00:00Z",
      "claims" => %{
        "issue-1" => %{
          "status" => "interrupted",
          "identifier" => "SYM-1",
          "workspace_path" => "/var/lib/symphony/workspaces/SYM-1",
          "harness" => "codex"
        }
      },
      "completed" => [],
      "poll" => %{"last_success_at" => nil, "last_error" => nil},
      "draining" => false
    }

    assert :ok = StateStore.save(path, snapshot)
    assert {:ok, ^snapshot} = StateStore.load(path)
    refute File.read!(path) =~ "#PID"
  end

  test "encoding failure preserves the previous valid snapshot", %{path: path} do
    previous = RuntimeState.empty(~U[2026-08-12 08:00:00Z])
    assert :ok = StateStore.save(path, previous)

    assert {:error, :state_encode_failed} =
             StateStore.save(path, Map.put(previous, "invalid", fn -> :not_json end))

    assert {:ok, ^previous} = StateStore.load(path)
  end

  test "rejects malformed JSON and unsupported schemas", %{path: path} do
    File.write!(path, "not-json")
    assert {:error, :state_invalid_json} = StateStore.load(path)

    File.write!(path, Jason.encode!(%{"version" => 2, "claims" => %{}}))
    assert {:error, :state_unsupported_version} = StateStore.load(path)
  end

  test "runtime conversion excludes process-only identities" do
    state = %{
      running: %{
        "issue-1" => %{
          pid: self(),
          ref: make_ref(),
          timer_ref: make_ref(),
          identifier: "SYM-1",
          workspace_path: "/var/lib/symphony/workspaces/SYM-1",
          harness: "codex",
          retry_attempt: 2,
          started_at: ~U[2026-08-12 08:00:00Z]
        }
      },
      retry_attempts: %{},
      blocked: %{},
      completed: MapSet.new(),
      last_tracker_poll_success_at: nil,
      last_tracker_poll_error: nil,
      draining: false
    }

    snapshot = RuntimeState.from_orchestrator(state, ~U[2026-08-12 08:01:00Z])
    claim = snapshot["claims"]["issue-1"]

    assert claim["status"] == "running"
    assert claim["identifier"] == "SYM-1"
    refute Map.has_key?(claim, "pid")
    refute Map.has_key?(claim, "ref")
    refute Map.has_key?(claim, "timer_ref")
    assert {:ok, _json} = Jason.encode(snapshot)
  end
end
