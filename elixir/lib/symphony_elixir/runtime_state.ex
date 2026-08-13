defmodule SymphonyElixir.RuntimeState do
  @moduledoc """
  Converts live orchestrator state into the schema-versioned durable shape.
  """

  alias SymphonyElixir.Budget

  @version 1
  @statuses ~w(running retrying interrupted blocked budget_exhausted)

  @spec empty(DateTime.t()) :: map()
  def empty(%DateTime{} = now) do
    %{
      "version" => @version,
      "saved_at" => DateTime.to_iso8601(now),
      "claims" => %{},
      "completed" => [],
      "poll" => %{"last_success_at" => nil, "last_error" => nil},
      "draining" => false
    }
  end

  @spec validate(map()) :: {:ok, map()} | {:error, atom()}
  def validate(%{"version" => @version, "claims" => claims} = snapshot) when is_map(claims) do
    if Enum.all?(claims, &valid_claim?/1) do
      {:ok, snapshot}
    else
      {:error, :state_invalid_claim}
    end
  end

  def validate(%{"version" => _version}), do: {:error, :state_unsupported_version}
  def validate(_snapshot), do: {:error, :state_invalid_schema}

  @spec from_orchestrator(map(), DateTime.t()) :: map()
  def from_orchestrator(state, %DateTime{} = now) when is_map(state) do
    claims =
      %{}
      |> add_claims(Map.get(state, :running, %{}), "running")
      |> add_claims(Map.get(state, :retry_attempts, %{}), "retrying")
      |> add_claims(Map.get(state, :blocked, %{}), "blocked")

    %{
      "version" => @version,
      "saved_at" => DateTime.to_iso8601(now),
      "claims" => claims,
      "completed" => state |> Map.get(:completed, MapSet.new()) |> completed_ids(),
      "poll" => %{
        "last_success_at" => encode_datetime(Map.get(state, :last_tracker_poll_success_at)),
        "last_error" => encode_scalar(Map.get(state, :last_tracker_poll_error))
      },
      "draining" => Map.get(state, :draining, false) == true
    }
  end

  defp add_claims(claims, entries, status) when is_map(entries) do
    Enum.reduce(entries, claims, fn {issue_id, entry}, acc ->
      Map.put(acc, to_string(issue_id), claim(entry, status))
    end)
  end

  defp add_claims(claims, _entries, _status), do: claims

  defp claim(entry, status) when is_map(entry) do
    issue = Map.get(entry, :issue)

    %{
      "status" => status,
      "identifier" => scalar(entry[:identifier] || issue_value(issue, :identifier)),
      "issue" => issue_map(issue),
      "workspace_path" => scalar(entry[:workspace_path]),
      "worker_host" => scalar(entry[:worker_host]),
      "harness" => scalar(entry[:harness]),
      "retry_attempt" => integer(entry[:retry_attempt] || entry[:attempt]),
      "due_at" => encode_datetime(entry[:due_at]),
      "session_id" => scalar(entry[:session_id]),
      "turn_count" => integer(entry[:turn_count]),
      "budget" => budget_map(entry[:budget]),
      "started_at" => encode_datetime(entry[:started_at]),
      "last_error" => scalar(entry[:error])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp issue_map(%_{} = issue), do: issue |> Map.from_struct() |> issue_map()

  defp issue_map(issue) when is_map(issue) do
    ~w(id identifier title description state url priority created_at updated_at branch_name assignee_id)a
    |> Enum.reduce(%{}, fn key, acc ->
      case encode_value(Map.get(issue, key)) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
    |> Map.put("labels", encode_string_list(Map.get(issue, :labels, [])))
    |> Map.put("blocked_by", encode_string_list(Map.get(issue, :blocked_by, [])))
  end

  defp issue_map(_issue), do: nil

  defp issue_value(%_{} = issue, key), do: Map.get(issue, key)
  defp issue_value(issue, key) when is_map(issue), do: Map.get(issue, key)
  defp issue_value(_issue, _key), do: nil

  defp budget_map(%Budget{} = budget), do: Budget.to_map(budget)
  defp budget_map(budget) when is_map(budget), do: encode_map(budget)
  defp budget_map(_budget), do: nil

  defp completed_ids(%MapSet{} = ids), do: ids |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort()
  defp completed_ids(ids) when is_list(ids), do: ids |> Enum.map(&to_string/1) |> Enum.sort()
  defp completed_ids(_ids), do: []

  defp valid_claim?({issue_id, %{"status" => status}}),
    do: is_binary(issue_id) and issue_id != "" and status in @statuses

  defp valid_claim?(_claim), do: false

  defp encode_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), encode_value(value)} end)
  end

  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp encode_value(nil), do: nil
  defp encode_value(values) when is_list(values), do: Enum.map(values, &encode_value/1)
  defp encode_value(value) when is_map(value), do: encode_map(value)
  defp encode_value(_value), do: nil

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(_value), do: nil

  defp encode_scalar(value), do: encode_value(value)
  defp scalar(value) when is_binary(value), do: value
  defp scalar(_value), do: nil
  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: nil

  defp encode_string_list(values) when is_list(values) do
    values
    |> Enum.map(&scalar/1)
    |> Enum.reject(&is_nil/1)
  end

  defp encode_string_list(_values), do: []
end
