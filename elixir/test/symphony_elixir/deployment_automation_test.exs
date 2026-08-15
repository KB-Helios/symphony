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
    assert deploy =~ "ToBase64String"
    assert deploy =~ "Remove-Item -LiteralPath $PreparationMarker"
    assert deploy =~ "/models"
    assert deploy =~ "domain.byComposeId"
    assert deploy =~ "compose.saveEnvironment"
    assert deploy =~ "compose.deploy"
    refute deploy =~ "lin_api_"
    refute deploy =~ "tskey-auth-"
  end

  test "Dokploy client suppresses empty JSON arrays instead of emitting a phantom item" do
    deploy = File.read!(@deploy_script)

    assert deploy =~ "$response = Invoke-RestMethod @request"
    assert deploy =~ "$response -is [Array] -and $response.Count -eq 0"

    # Verify non-empty responses are still surfaced correctly to project.all, project.one, and compose.create
    assert deploy =~ ~r/\$projects = @\(Invoke-Dokploy -Route "project\.all"/
    assert deploy =~ ~r/\$projectRecord = Invoke-Dokploy -Route "project\.one\?projectId=/
    assert deploy =~ ~r/\$compose = Invoke-Dokploy -Route "compose\.create"/

    # Verify that non-empty arrays are still accessible after the empty-array check
    assert deploy =~ ~r/\$projects \| Where-Object \{ \$_\.name -eq "Symphony" \}/
    assert deploy =~ ~r/@\(\$projectRecord\.environments\)/
    assert deploy =~ ~r/if \(\$null -eq \$compose\)/
  end

  test "verification checks private health, router responses, volumes, and public refusal" do
    verify = File.read!(@verify_script)

    assert verify =~ "/api/v1/ready"
    assert verify =~ "/v1/responses"
    assert verify =~ "symphony-state"
    assert verify =~ "public port 4021"
    assert verify =~ "domain.byComposeId"
    assert verify =~ "tailscale funnel status"
    assert verify =~ "ToBase64String"
    assert verify =~ "--format=json(name,status,networkInterfaces[0].accessConfigs[0].natIP)"
    refute verify =~ ~s("--format=json")
    assert verify =~ "Invoke-WebRequest -UseBasicParsing"
    assert verify =~ "$domainResponse -is [Array] -and $domainResponse.Count -eq 0"
  end
end
