defmodule SymphonyElixir.SignalHandler do
  @moduledoc """
  Converts supported VM shutdown signals into a bounded orchestrator drain.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if Application.get_env(:symphony_elixir, :install_signal_handler, true) do
      _ = :os.set_signal(:sigterm, :handle)
    end

    {:ok,
     %{
       orchestrator: Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator),
       timeout_ms: Keyword.get(opts, :timeout_ms, SymphonyElixir.Config.settings!().runtime.graceful_drain_timeout_ms),
       poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 100),
       stop_buffer_ms: Keyword.get(opts, :stop_buffer_ms, 1_000),
       stop_fun: Keyword.get(opts, :stop_fun, &System.stop/1),
       stop_deadline_ms: nil
     }}
  end

  @impl true
  def handle_info({:signal, :sigterm}, %{stop_deadline_ms: nil} = state) do
    _ = SymphonyElixir.Orchestrator.drain(state.orchestrator, state.timeout_ms)
    send(self(), :maybe_stop_vm)

    {:noreply,
     %{
       state
       | stop_deadline_ms: System.monotonic_time(:millisecond) + state.timeout_ms + state.stop_buffer_ms
     }}
  end

  def handle_info({:signal, :sigterm}, state), do: {:noreply, state}

  def handle_info(:maybe_stop_vm, state) do
    now_ms = System.monotonic_time(:millisecond)

    if drain_complete?(state.orchestrator) or now_ms >= state.stop_deadline_ms do
      _ = state.stop_fun.(0)
      {:stop, :normal, state}
    else
      Process.send_after(self(), :maybe_stop_vm, state.poll_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drain_complete?(orchestrator) do
    case SymphonyElixir.Orchestrator.snapshot(orchestrator, 1_000) do
      %{running: []} -> true
      :unavailable -> true
      _ -> false
    end
  end
end
