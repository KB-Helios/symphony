defmodule SymphonyElixir.SignalHandlerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SignalHandler

  test "SIGTERM drains and then requests a bounded clean VM stop" do
    previous = Application.get_env(:symphony_elixir, :install_signal_handler)
    Application.put_env(:symphony_elixir, :install_signal_handler, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :install_signal_handler)
      else
        Application.put_env(:symphony_elixir, :install_signal_handler, previous)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator)
    parent = self()

    {:ok, handler} =
      SignalHandler.start_link(
        name: Module.concat(__MODULE__, "Handler#{System.unique_integer([:positive])}"),
        orchestrator: orchestrator,
        timeout_ms: 50,
        poll_interval_ms: 5,
        stop_fun: fn code -> send(parent, {:vm_stop_requested, code}) end
      )

    send(handler, {:signal, :sigterm})

    assert_receive {:vm_stop_requested, 0}, 250
    assert %{draining: true, dispatch_enabled: false} = Orchestrator.health(orchestrator)
    GenServer.stop(orchestrator_pid)
  end
end
