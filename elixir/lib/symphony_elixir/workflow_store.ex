defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :settings]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :settings)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, %State{settings: settings}} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec update_harness(String.t()) :: :ok | {:error, term()}
  def update_harness(kind) when is_binary(kind) do
    normalized = kind |> String.trim() |> String.downcase()

    if normalized not in ["codex", "prime"] do
      {:error, :invalid_harness}
    else
      path = Workflow.workflow_file_path()

      with {:ok, content} <- File.read(path),
           {:ok, updated} <- build_updated_content(content, normalized),
           :ok <- atomic_write(path, updated) do
        force_reload()
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def update_harness(_kind), do: {:error, :invalid_harness}

  defp build_updated_content(content, kind) do
    case split_front_matter(content) do
      {:ok, {front_matter, body, delimiter}} ->
        with :ok <- validate_front_matter_yaml(front_matter) do
          updated_front = update_front_matter_string(front_matter, kind)
          {:ok, delimiter <> updated_front <> delimiter <> body}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] ->
            front_matter = Enum.join(front, "\n")
            body = Enum.join(prompt_lines, "\n")
            {:ok, {front_matter, body, "---\n"}}

          _ ->
            {:error, {:workflow_parse_error, {:unterminated_front_matter, Enum.join(tail, "\n")}}}
        end

      _ ->
        {:ok, {"", content, "---\n"}}
    end
  end

  defp validate_front_matter_yaml(front_matter) do
    yaml = String.trim(front_matter)

    if yaml == "" do
      :ok
    else
      if Code.ensure_loaded?(YamlElixir) and function_exported?(YamlElixir, :read_from_string, 1) do
        case YamlElixir.read_from_string(yaml) do
          {:ok, decoded} when is_map(decoded) -> :ok
          {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
          {:error, reason} -> {:error, {:workflow_parse_error, reason}}
        end
      else
        :ok
      end
    end
  end

  defp update_front_matter_string(front_matter, kind) do
    trimmed = String.trim(front_matter)

    cond do
      trimmed == "" ->
        "harness:\n  kind: #{kind}\n"

      String.contains?(front_matter, "harness:") ->
        updated =
          Regex.replace(~r/harness:\s*\n(?:[ \t]+kind:.*\n?)*/, front_matter, "harness:\n  kind: #{kind}\n")

        if String.contains?(updated, "kind: #{kind}") do
          ensure_trailing_newline(updated)
        else
          Regex.replace(~r/harness:\s*\n/, front_matter, "harness:\n  kind: #{kind}\n")
          |> ensure_trailing_newline()
        end

      true ->
        base = front_matter |> String.trim_trailing() |> ensure_trailing_newline()
        base <> "harness:\n  kind: #{kind}\n"
    end
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(str) do
    if String.ends_with?(str, "\n"), do: str, else: str <> "\n"
  end

  defp atomic_write(path, content) do
    tmp = path <> ".tmp.#{:erlang.system_time(:millisecond)}.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
