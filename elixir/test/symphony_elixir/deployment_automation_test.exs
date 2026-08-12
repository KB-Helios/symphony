defmodule SymphonyElixir.DeploymentAutomationTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @deploy_script Path.join(@repo_root, "deploy/dokploy/deploy.ps1")
  @verify_script Path.join(@repo_root, "deploy/dokploy/verify.ps1")

  test "deployment automation is target-locked, backup-first, and secret-free" do
    deploy = File.read!(@deploy_script)

    assert deploy =~ "instance-20260804-153230-eu"
    assert deploy =~ "europe-west1-b"
    assert deploy =~ "project-eb921be9-5a18-4ede-909"
    assert deploy =~ ~s("machine-images", "create")
    assert deploy =~ ".prepared.json"
    assert deploy =~ "machine-images\", \"describe"
    assert deploy =~ "bootDiskId"
    assert deploy =~ "PreparationMaxAgeMinutes"
    assert deploy =~ "--format=json(name,zone,status,scheduling.provisioningModel)"
    assert deploy =~ "--format=value(disks[0].source.basename())"
    assert deploy =~ "--format=value(id)"
    assert deploy =~ "Remove-Item -LiteralPath $PreparationMarker"
    assert deploy =~ "/models"
    assert deploy =~ "domain.byComposeId"
    assert deploy =~ "compose.saveEnvironment"
    assert deploy =~ "compose.deploy"
    refute deploy =~ "lin_api_"
    refute deploy =~ "tskey-auth-"
  end

  test "verification checks private health, router responses, volumes, and public refusal" do
    verify = File.read!(@verify_script)

    assert verify =~ "/api/v1/ready"
    assert verify =~ "/v1/responses"
    assert verify =~ "symphony-state"
    assert verify =~ "public port 4021"
    assert verify =~ "domain.byComposeId"
    assert verify =~ "tailscale funnel status"
  end
end
