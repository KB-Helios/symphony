defmodule SymphonyElixir.DeploymentConfigTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @compose_path Path.join(@repo_root, "deploy/dokploy/compose.yaml")

  test "Dokploy compose keeps Symphony private and all durable data on named volumes" do
    assert {:ok, %{"services" => services, "volumes" => volumes}} =
             YamlElixir.read_from_file(@compose_path)

    symphony = services["symphony"]
    tailscale = services["tailscale"]

    assert symphony["network_mode"] == "service:tailscale"
    refute Map.has_key?(symphony, "ports")
    assert symphony["restart"] == "unless-stopped"
    assert symphony["read_only"] == true
    assert symphony["stop_grace_period"] == "2m"
    assert is_map(symphony["healthcheck"])

    assert "symphony_state:/var/lib/symphony/state" in symphony["volumes"]
    assert "symphony_workspaces:/var/lib/symphony/workspaces" in symphony["volumes"]
    assert "symphony_codex:/var/lib/symphony/codex" in symphony["volumes"]

    assert tailscale["restart"] == "unless-stopped"
    assert "tailscale_state:/var/lib/tailscale" in tailscale["volumes"]

    assert Map.keys(volumes) |> Enum.sort() ==
             ~w(symphony_codex symphony_state symphony_workspaces tailscale_state)
  end
end
