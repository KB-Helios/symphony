defmodule SymphonyElixir.DokployMcpPackagingTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @deployment_root Path.join(@repo_root, "deploy/dokploy-mcp")

  test "Dokploy MCP is loopback-only, redacted, filtered, and approval-gated" do
    env = File.read!(Path.join(@deployment_root, "env.example"))
    unit = File.read!(Path.join(@deployment_root, "dokploy-mcp.container"))
    codex = File.read!(Path.join(@deployment_root, "operator-codex.toml.example"))

    assert env =~ "DOKPLOY_REDACT_ENV=true"
    assert env =~ "DOKPLOY_ENABLED_TAGS=project,application,compose,deployment,domain"
    assert env =~ "DOKPLOY_API_KEY="
    refute Regex.match?(~r/^DOKPLOY_API_KEY=.+$/m, env)

    assert unit =~ "PublishPort=127.0.0.1:3003:3000"
    refute unit =~ "PublishPort=127.0.0.1:3001:3000"
    assert unit =~ "DropCapability=all"
    assert unit =~ "ReadOnly=true"

    assert codex =~ "url = \"https://ai-router-main.tail31b2b0.ts.net:3003/mcp\""
    assert codex =~ "default_tools_approval_mode = \"writes\""
  end
end
