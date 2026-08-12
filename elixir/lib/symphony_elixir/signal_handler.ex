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
       timeout_ms: Keyword.get(opts, :timeout_ms, SymphonyElixir.Config.settings!().runtime.graceful_drain_timeout_ms)
     }}
  end

  @impl true
  def handle_info({:signal, :sigterm}, state) do
    _ = SymphonyElixir.Orchestrator.drain(state.orchestrator, state.timeout_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
