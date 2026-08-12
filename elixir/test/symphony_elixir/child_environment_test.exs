defmodule SymphonyElixir.ChildEnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ChildEnvironment

  test "Codex receives model-router settings but no controller credentials" do
    source = %{
      "HOME" => "/home/symphony",
      "PATH" => "/usr/bin",
      "CODEX_HOME" => "/var/lib/symphony/codex",
      "OMNIROUTE_BASE_URL" => "https://router.example/v1",
      "OMNIROUTE_API_KEY" => "router-secret",
      "SYMPHONY_MODEL" => "kimi-k3",
      "LINEAR_API_KEY" => "linear-secret",
      "DOKPLOY_API_KEY" => "dokploy-secret",
      "GOOGLE_APPLICATION_CREDENTIALS" => "/run/secrets/gcp.json",
      "TS_AUTHKEY" => "tailscale-secret"
    }

    env = ChildEnvironment.effective(source, :codex, ["LINEAR_API_KEY"])

    assert env["OMNIROUTE_BASE_URL"] == "https://router.example/v1"
    assert env["OMNIROUTE_API_KEY"] == "router-secret"
    assert env["SYMPHONY_MODEL"] == "kimi-k3"
    refute Map.has_key?(env, "LINEAR_API_KEY")
    refute Map.has_key?(env, "DOKPLOY_API_KEY")
    refute Map.has_key?(env, "GOOGLE_APPLICATION_CREDENTIALS")
    refute Map.has_key?(env, "TS_AUTHKEY")
  end

  test "port changes explicitly remove every inherited variable outside the allowlist" do
    source = %{"PATH" => "/usr/bin", "LINEAR_API_KEY" => "secret", "UNRELATED" => "value"}

    changes = ChildEnvironment.port_env(source, :codex, ["LINEAR_API_KEY"])

    assert {~c"LINEAR_API_KEY", false} in changes
    assert {~c"UNRELATED", false} in changes
    refute Enum.any?(changes, fn {name, _value} -> name == ~c"PATH" end)
  end

  test "remote command starts from an empty environment and shell-quotes values" do
    source = %{
      "PATH" => "/usr/local/bin:/usr/bin",
      "SYMPHONY_MODEL" => "model with ' quote",
      "LINEAR_API_KEY" => "must-not-appear"
    }

    command = ChildEnvironment.shell_command(source, :codex, ["LINEAR_API_KEY"])

    assert String.starts_with?(command, "env -i ")
    assert command =~ "PATH='/usr/local/bin:/usr/bin'"
    assert command =~ "SYMPHONY_MODEL='model with '\"'\"' quote'"
    refute command =~ "LINEAR_API_KEY"
    refute command =~ "must-not-appear"
  end
end
