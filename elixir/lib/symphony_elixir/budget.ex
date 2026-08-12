defmodule SymphonyElixir.Budget do
  @moduledoc """
  Pure, durable per-issue execution accounting.
  """

  @enforce_keys [:issue_id, :identifier, :first_activity_at, :last_activity_at]
  defstruct issue_id: nil,
            identifier: nil,
            attempts: 0,
            total_turns: 0,
            input_tokens: 0,
            output_tokens: 0,
            consecutive_abnormal_failures: 0,
            first_activity_at: nil,
            last_activity_at: nil

  @type t :: %__MODULE__{
          issue_id: String.t(),
          identifier: String.t(),
          attempts: non_neg_integer(),
          total_turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          consecutive_abnormal_failures: non_neg_integer(),
          first_activity_at: DateTime.t(),
          last_activity_at: DateTime.t()
        }

  @spec new(String.t(), String.t(), DateTime.t()) :: t()
  def new(issue_id, identifier, %DateTime{} = now) do
    %__MODULE__{
      issue_id: issue_id,
      identifier: identifier,
      first_activity_at: now,
      last_activity_at: now
    }
  end

  @spec limits(struct() | map()) :: map()
  def limits(agent) do
    %{
      attempts: agent.max_attempts_per_issue,
      turns: agent.max_total_turns_per_issue,
      wall_time_ms: agent.max_wall_time_ms_per_issue,
      tokens: agent.max_total_tokens_per_issue,
      abnormal_failures: agent.max_consecutive_abnormal_failures
    }
  end

  @spec authorize_attempt(t(), map(), DateTime.t()) :: {:ok, t()} | {:error, :attempts, t()}
  def authorize_attempt(%__MODULE__{attempts: count} = budget, %{attempts: limit}, %DateTime{} = now)
      when count < limit do
    {:ok, %{budget | attempts: count + 1, last_activity_at: now}}
  end

  def authorize_attempt(%__MODULE__{} = budget, _limits, %DateTime{}),
    do: {:error, :attempts, budget}

  @spec authorize_turn(t(), map(), DateTime.t()) :: {:ok, t()} | {:error, :turns, t()}
  def authorize_turn(%__MODULE__{total_turns: count} = budget, %{turns: limit}, %DateTime{} = now)
      when count < limit do
    {:ok, %{budget | total_turns: count + 1, last_activity_at: now}}
  end

  def authorize_turn(%__MODULE__{} = budget, _limits, %DateTime{}),
    do: {:error, :turns, budget}

  @spec add_tokens(t(), non_neg_integer(), non_neg_integer(), DateTime.t()) :: t()
  def add_tokens(%__MODULE__{} = budget, input, output, %DateTime{} = now)
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    %{
      budget
      | input_tokens: budget.input_tokens + input,
        output_tokens: budget.output_tokens + output,
        last_activity_at: now
    }
  end

  @spec record_abnormal_failure(t(), DateTime.t()) :: t()
  def record_abnormal_failure(%__MODULE__{} = budget, %DateTime{} = now) do
    %{
      budget
      | consecutive_abnormal_failures: budget.consecutive_abnormal_failures + 1,
        last_activity_at: now
    }
  end

  @spec record_normal_completion(t(), DateTime.t()) :: t()
  def record_normal_completion(%__MODULE__{} = budget, %DateTime{} = now) do
    %{budget | consecutive_abnormal_failures: 0, last_activity_at: now}
  end

  @spec exhausted_dimension(t(), map(), DateTime.t()) ::
          :wall_time | :turns | :tokens | :abnormal_failures | nil
  def exhausted_dimension(%__MODULE__{} = budget, limits, %DateTime{} = now) do
    cond do
      DateTime.diff(now, budget.first_activity_at, :millisecond) >= limits.wall_time_ms ->
        :wall_time

      budget.total_turns >= limits.turns ->
        :turns

      budget.input_tokens + budget.output_tokens >= limits.tokens ->
        :tokens

      budget.consecutive_abnormal_failures >= limits.abnormal_failures ->
        :abnormal_failures

      true ->
        nil
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = budget) do
    budget
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode_value(value)} end)
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_budget}
  def from_map(map) when is_map(map) do
    with {:ok, first_activity_at} <- parse_datetime(map["first_activity_at"]),
         {:ok, last_activity_at} <- parse_datetime(map["last_activity_at"]),
         true <- is_binary(map["issue_id"]),
         true <- is_binary(map["identifier"]) do
      {:ok,
       %__MODULE__{
         issue_id: map["issue_id"],
         identifier: map["identifier"],
         attempts: non_negative(map["attempts"]),
         total_turns: non_negative(map["total_turns"]),
         input_tokens: non_negative(map["input_tokens"]),
         output_tokens: non_negative(map["output_tokens"]),
         consecutive_abnormal_failures: non_negative(map["consecutive_abnormal_failures"]),
         first_activity_at: first_activity_at,
         last_activity_at: last_activity_at
       }}
    else
      _ -> {:error, :invalid_budget}
    end
  end

  def from_map(_map), do: {:error, :invalid_budget}

  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}
  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0
end
