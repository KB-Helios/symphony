defmodule SymphonyElixir.CodexTransportTest do
  use SymphonyElixir.TestSupport

  test "codex port line is 10 MB" do
    assert SymphonyElixir.Codex.AppServer.port_line_bytes() == 10_485_760
  end

  test "prime port line is 10 MB" do
    assert SymphonyElixir.PrimeAgent.AppServer.port_line_bytes() == 10_485_760
  end

  test "stderr handling is documented (merged stream filtered via protocol_message_candidate?)" do
    codex_source = File.read!("lib/symphony_elixir/codex/app_server.ex")
    prime_source = File.read!("lib/symphony_elixir/prime_agent/app_server.ex")

    # Documented deviation: merged stderr filtered via protocol_message_candidate?/1
    assert codex_source =~ "Merged stderr"
    assert prime_source =~ "Merged stderr"
    assert codex_source =~ "protocol_message_candidate?"
    assert prime_source =~ "protocol_message_candidate?"
  end

  test "stall timeout is harness-aware (prime vs codex)" do
    source = File.read!("lib/symphony_elixir/orchestrator.ex")
    assert source =~ "stall_timeout_for_entry"
    assert source =~ "\"prime\""
    assert source =~ "prime.stall_timeout_ms"
    assert source =~ "codex.stall_timeout_ms"
  end
end
