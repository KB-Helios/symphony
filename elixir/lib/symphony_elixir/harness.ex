defmodule SymphonyElixir.Harness do
  @moduledoc """
  Dispatches agent execution to the configured harness (Codex or Prime).

  The selected harness is determined by `harness.kind` in `WORKFLOW.md` front
  matter and defaults to `codex`, preserving full backward compatibility.
  """

  alias SymphonyElixir.Config

  @supported_harnesses ["codex", "prime"]
  @port_line_bytes 10_485_760

  @type harness_kind :: String.t()
  @type session :: map()

  @spec port_line_bytes() :: pos_integer()
  def port_line_bytes, do: @port_line_bytes

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec supported_harnesses() :: [harness_kind()]
  def supported_harnesses, do: @supported_harnesses

  @spec normalize_kind(term()) :: harness_kind()
  def normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      normalized when normalized in @supported_harnesses -> normalized
      _ -> "codex"
    end
  end

  def normalize_kind(_kind), do: "codex"

  @spec current_kind() :: harness_kind()
  def current_kind do
    Config.harness_kind()
    |> normalize_kind()
  end

  @spec harness_for(term()) :: harness_kind()
  def harness_for(nil), do: current_kind()
  def harness_for(kind) when is_binary(kind), do: normalize_kind(kind)
  def harness_for(_), do: current_kind()

  @spec module_for(harness_kind()) :: module()
  def module_for("prime"), do: SymphonyElixir.PrimeAgent.AppServer
  def module_for(_), do: SymphonyElixir.Codex.AppServer

  @spec current_module() :: module()
  def current_module, do: module_for(current_kind())

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    harness = harness_for(Keyword.get(opts, :harness, current_kind()))
    module = module_for(harness)

    case module.start_session(workspace, opts) do
      {:ok, session} -> {:ok, Map.put(session, :harness, harness)}
      other -> other
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    harness = Map.get(session, :harness, current_kind())
    module = module_for(harness)
    module.run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) when is_map(session) do
    harness = Map.get(session, :harness, "codex")
    module = module_for(harness)
    module.stop_session(session)
  end

  def stop_session(_session), do: :ok
end
