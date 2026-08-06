defmodule SymphonyElixir.PrimeAgent.AppServer do
  @moduledoc """
  Client for `prime-agent` in RPC mode (`prime-agent --mode rpc`).

  Speaks JSONL over stdio (LF-delimited, matching Codex AppServer framing) and
  translates Prime lifecycle events into the same orchestrator event vocabulary
  used by the Codex harness so `AgentRunner` / `Orchestrator` can stay
  harness-agnostic.

  Protocol summary (see `prime-agent --mode rpc` docs):
  - Commands are JSON objects with `type` and optional `id`, one per line on stdin.
  - Responses are `{"type":"response","success":bool}` with the same `id`.
  - Events are `{"type":"agent_start" | "turn_start" | "message_update" | ...}` streamed on stdout.
  - The transport is line-delimited JSON (`\\n`).
  """

  @behaviour SymphonyElixir.Harness

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @json_mode_flag "--mode json"

  @type session :: %{
          port: port(),
          metadata: map(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          prime_settings: map(),
          harness: String.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @impl SymphonyElixir.Harness
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    prime_settings = Config.prime_settings()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, prime_settings) do
      metadata = port_metadata(port, worker_host)

      {:ok,
       %{
         port: port,
         metadata: metadata,
         workspace: expanded_workspace,
         worker_host: worker_host,
         prime_settings: prime_settings,
         harness: "prime"
       }}
    end
  end

  @impl SymphonyElixir.Harness
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          workspace: workspace
        } = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = prime_session_id(metadata, workspace)

    emit_message(on_message, :session_started, %{session_id: session_id, harness: "prime"}, metadata)
    Logger.info("Prime session started for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace}")

    case await_prime_completion(port, on_message, metadata) do
      {:ok, result} ->
        Logger.info("Prime session completed for #{issue_context(issue)} session_id=#{session_id}")
        {:ok, %{result: result, session_id: session_id, thread_id: session_id, turn_id: "1"}}

      {:error, reason} ->
        Logger.warning("Prime session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason, harness: "prime"}, metadata)
        {:error, reason}
    end
  end

  @impl SymphonyElixir.Harness
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port), do: stop_port(port)
  def stop_session(_session), do: :ok

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, _prime_settings) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command())],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, _prime_settings) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command do
    command = Config.prime_command()

    if String.contains?(command, @json_mode_flag) do
      "exec #{command}"
    else
      "exec #{command}"
    end
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    command = Config.prime_command()
    "cd #{shell_escape(workspace)} && exec #{command}"
  end

  defp tracker_secret_port_env do
    case Config.settings() do
      {:ok, settings} ->
        settings.tracker.secret_environment_names
        |> valid_environment_names()
        |> Enum.map(fn name -> {String.to_charlist(name), false} end)

      _ ->
        []
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names || [], fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp prime_session_id(metadata, workspace) do
    pid = Map.get(metadata, :codex_app_server_pid, "prime")
    hash = :erlang.phash2({workspace, pid, System.monotonic_time()}) |> Integer.to_string(16)
    "prime-#{pid}-#{String.slice(hash, 0, 8)}"
  end

  defp send_prime_prompt(port, prompt, _issue) do
    payload =
      if String.contains?(Config.prime_command(), @json_mode_flag) do
        %{"type" => "prompt", "message" => prompt}
      else
        %{"type" => "prompt", "message" => prompt, "id" => prime_request_id()}
      end

    send_message(port, payload)
    :ok
  end

  defp prime_request_id, do: "symphony-#{System.unique_integer([:positive])}"

  defp await_prime_completion(port, on_message, metadata) do
    receive_loop(port, on_message, metadata, Config.settings!().prime.turn_timeout_ms, "")
  end

  defp receive_loop(port, on_message, metadata, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_prime_line(port, on_message, metadata, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, metadata, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, :turn_completed}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_prime_line(port, on_message, metadata, data, timeout_ms) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => type} = payload} ->
        case translate_prime_event(type, payload, payload_string, port, on_message, metadata) do
          :continue -> receive_loop(port, on_message, metadata, timeout_ms, "")
          {:done, result} -> result
        end

      {:ok, payload} ->
        emit_message(on_message, :other_message, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
        receive_loop(port, on_message, metadata, timeout_ms, "")

      {:error, _} ->
        if String.trim(payload_string) != "" do
          emit_message(on_message, :notification, %{payload: payload_string, raw: payload_string, harness: "prime"}, metadata)
        end

        receive_loop(port, on_message, metadata, timeout_ms, "")
    end
  end

  defp translate_prime_event("response", payload, payload_string, _port, on_message, metadata) do
    success = Map.get(payload, "success", true)

    if success == false do
      emit_message(on_message, :turn_failed, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
      :continue
    else
      :continue
    end
  end

  defp translate_prime_event("agent_start", payload, payload_string, _port, on_message, metadata) do
    emit_message(on_message, :notification, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    :continue
  end

  defp translate_prime_event("agent_end", payload, payload_string, _port, on_message, metadata) do
    emit_message(on_message, :turn_completed, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    {:done, {:ok, :turn_completed}}
  end

  defp translate_prime_event("turn_end", payload, payload_string, _port, on_message, metadata) do
    emit_message(on_message, :turn_completed, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    {:done, {:ok, :turn_completed}}
  end

  defp translate_prime_event(type, payload, payload_string, _port, on_message, metadata)
       when type in ["turn_failed", "turn_cancelled"] do
    event = if type == "turn_failed", do: :turn_failed, else: :turn_cancelled
    emit_message(on_message, event, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    {:done, {:error, {String.to_atom(type), payload}}}
  end

  defp translate_prime_event(type, payload, payload_string, _port, on_message, metadata)
       when type in ["tool_execution_start", "tool_execution_end", "message_start", "message_update", "message_end"] do
    event =
      case type do
        "tool_execution_start" -> :notification
        "tool_execution_end" -> if Map.get(payload, "isError") == true, do: :tool_call_failed, else: :tool_call_completed
        _ -> :notification
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    :continue
  end

  defp translate_prime_event(_type, payload, payload_string, _port, on_message, metadata) do
    emit_message(on_message, :notification, %{payload: payload, raw: payload_string, harness: "prime"}, metadata)
    :continue
  end

  defp issue_context(%{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp shell_escape(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  defp default_on_message(_message), do: :ok

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end
end
