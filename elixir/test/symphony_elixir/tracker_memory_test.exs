defmodule SymphonyElixir.Tracker.MemoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker.Memory

  test "memory empty list returns without building MapSet" do
    assert {:ok, []} = Memory.fetch_issues_by_states([])
    assert {:ok, []} = Memory.fetch_issues_by_ids([])
  end

  test "memory empty list fast-path does not require provider state" do
    # Ensures early return works even when no issues are configured.
    previous_value = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_value) end)
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    assert {:ok, []} = Memory.fetch_issues_by_states([])
    assert {:ok, []} = Memory.fetch_issues_by_ids([])
  end
end
