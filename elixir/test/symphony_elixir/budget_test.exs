defmodule SymphonyElixir.BudgetTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Budget

  @started_at ~U[2026-08-12 08:00:00Z]

  test "production budget and recovery defaults are finite" do
    settings = Config.settings!()

    assert Budget.limits(settings.agent) == %{
             attempts: 10,
             turns: 100,
             wall_time_ms: 14_400_000,
             tokens: 2_000_000,
             abnormal_failures: 5
           }

    assert settings.runtime.recovery_backoff_ms == 30_000
    assert settings.runtime.graceful_drain_timeout_ms == 120_000
  end

  test "the configured attempt and turn boundaries stop the next unit of work" do
    limits = Budget.limits(Config.settings!().agent)
    budget = Budget.new("issue-1", "SYM-1", @started_at)

    attempt_budget = %{budget | attempts: 9}
    assert {:ok, %{attempts: 10}} = Budget.authorize_attempt(attempt_budget, limits, @started_at)

    assert {:error, :attempts, %{attempts: 10}} =
             Budget.authorize_attempt(%{budget | attempts: 10}, limits, @started_at)

    turn_budget = %{budget | total_turns: 99}
    assert {:ok, %{total_turns: 100}} = Budget.authorize_turn(turn_budget, limits, @started_at)

    assert {:error, :turns, %{total_turns: 100}} =
             Budget.authorize_turn(%{budget | total_turns: 100}, limits, @started_at)
  end

  test "turns, tokens, wall time, and consecutive abnormal failures exhaust at exact limits" do
    limits = Budget.limits(Config.settings!().agent)
    budget = Budget.new("issue-1", "SYM-1", @started_at)

    turn_budget = %{budget | total_turns: limits.turns}
    assert Budget.exhausted_dimension(turn_budget, limits, @started_at) == :turns

    token_budget = Budget.add_tokens(budget, 1_200_000, 800_000, @started_at)
    assert Budget.exhausted_dimension(token_budget, limits, @started_at) == :tokens

    four_hours_later = DateTime.add(@started_at, 14_400, :second)
    assert Budget.exhausted_dimension(budget, limits, four_hours_later) == :wall_time

    failure_budget = %{budget | consecutive_abnormal_failures: 5}
    assert Budget.exhausted_dimension(failure_budget, limits, @started_at) == :abnormal_failures
  end

  test "budget JSON shape round trips without losing timestamps or counters" do
    budget = %{
      Budget.new("issue-1", "SYM-1", @started_at)
      | attempts: 3,
        total_turns: 7,
        input_tokens: 11,
        output_tokens: 13,
        consecutive_abnormal_failures: 2
    }

    assert {:ok, ^budget} = budget |> Budget.to_map() |> Budget.from_map()
  end
end
