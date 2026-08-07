defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @doc """
Handles a request with no states by returning an empty issue list.

## Returns

  - `{:ok, []}`
"""
@spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  @doc """
  Finds configured issues whose states match the requested state names.
  
  ## Parameters
  
    - state_names: State names to match after trimming whitespace and converting them to lowercase.
  
  ## Returns
  
    A tuple containing the matching issues.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, list()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @doc """
Fetches configured issues matching the requested IDs.

## Parameters

  - ids: Issue IDs to match.

## Returns

  `{:ok, issues}` containing the matching issues, or an error tuple.
"""
@spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  @doc """
  Fetches configured issues whose IDs match the requested IDs.
  
  ## Parameters
  
    - issue_ids: List of issue IDs to retrieve.
  
  ## Returns
  
    `{:ok, issues}` containing the configured issues with matching IDs.
  """
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
