[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Prepare,
    [switch]$Deploy,
    [string]$Project = "project-eb921be9-5a18-4ede-909",
    [string]$Zone = "europe-west1-b",
    [string]$Instance = "instance-20260804-153230-eu",
    [string]$DokployUrl = $env:DOKPLOY_URL,
    [string]$DokployApiKey = $env:DOKPLOY_API_KEY,
    [string]$Repository = "https://github.com/KB-Helios/symphony.git",
    [string]$Branch = "codex/dokploy-omniroute",
    [int]$PreparationMaxAgeMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PreparationMarker = Join-Path $PSScriptRoot ".prepared.json"
$DeploymentMarker = Join-Path $PSScriptRoot ".deployment.json"

if ($Prepare.IsPresent -eq $Deploy.IsPresent) {
    throw "Specify exactly one of -Prepare or -Deploy"
}

function Invoke-Rtk {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & rtk @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: rtk $($Arguments -join ' ')"
    }
    return $output
}

function ConvertTo-RemoteBashCommand {
    param([Parameter(Mandatory)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    return "printf '%s' '$encoded' | base64 -d | bash"
}

function Get-TargetInstance {
    $json = Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "instances", "describe", $Instance,
        "--zone", $Zone, "--project", $Project,
        "--format=json(name,zone,status,scheduling.provisioningModel)"
    )
    $vm = $json | ConvertFrom-Json

    if ($vm.name -ne $Instance -or -not $vm.zone.EndsWith("/zones/$Zone")) {
        throw "Resolved VM identity does not match the target"
    }
    if ($vm.scheduling.provisioningModel -ne "SPOT") {
        throw "Refusing deployment because the target is not a Spot VM"
    }
    return $vm
}

function Start-Target {
    $vm = Get-TargetInstance
    if ($vm.status -ne "RUNNING") {
        Invoke-Rtk -Arguments @(
            "gcloud.cmd", "compute", "instances", "start", $Instance,
            "--zone", $Zone, "--project", $Project, "--quiet"
        ) | Out-Null
    }
}

function Get-BootDiskIdentity {
    $diskNameOutput = Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "instances", "describe", $Instance,
        "--zone", $Zone, "--project", $Project,
        "--format=value(disks[0].source.basename())"
    )
    $diskName = ($diskNameOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($diskName)) { throw "Target VM has no boot disk" }

    $diskIdOutput = Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "disks", "describe", $diskName,
        "--zone", $Zone, "--project", $Project, "--format=value(id)"
    )
    $diskId = ($diskIdOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($diskId)) { throw "Target boot disk has no immutable ID" }

    return [pscustomobject]@{
        Source = $diskName
        Id = $diskId
    }
}

function Invoke-Dokploy {
    param(
        [Parameter(Mandatory)][string]$Route,
        [ValidateSet("Get", "Post")][string]$Method = "Post",
        [hashtable]$Body
    )

    if ([string]::IsNullOrWhiteSpace($DokployUrl) -or [string]::IsNullOrWhiteSpace($DokployApiKey)) {
        throw "DOKPLOY_URL and DOKPLOY_API_KEY are required for -Deploy"
    }

    $request = @{
        Uri = "$($DokployUrl.TrimEnd('/'))/api/$Route"
        Method = $Method
        Headers = @{ "x-api-key" = $DokployApiKey }
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    return Invoke-RestMethod @request
}

function Get-RequiredEnvironment {
    param([bool]$RequireTailscaleKey)

    $names = @(
        "SECRET_KEY_BASE", "LINEAR_API_KEY", "OMNIROUTE_BASE_URL",
        "OMNIROUTE_API_KEY", "SYMPHONY_MODEL"
    )
    if ($RequireTailscaleKey) { $names += "TS_AUTHKEY" }

    $values = [ordered]@{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$name is required"
        }
        if ($value.Contains("`r") -or $value.Contains("`n")) {
            throw "$name must be one line"
        }
        $values[$name] = $value
    }

    if ($values.SECRET_KEY_BASE.Length -lt 64) {
        throw "SECRET_KEY_BASE must be at least 64 characters"
    }
    if ($values.OMNIROUTE_BASE_URL -notmatch '^https://.+/v1$') {
        throw "OMNIROUTE_BASE_URL must be an HTTPS URL ending in /v1"
    }

    $assignee = [Environment]::GetEnvironmentVariable("LINEAR_ASSIGNEE")
    if ($null -ne $assignee -and ($assignee.Contains("`r") -or $assignee.Contains("`n"))) {
        throw "LINEAR_ASSIGNEE must be one line"
    }
    $values["LINEAR_ASSIGNEE"] = $assignee

    if (-not $RequireTailscaleKey) {
        $tailscaleKey = [Environment]::GetEnvironmentVariable("TS_AUTHKEY")
        $values["TS_AUTHKEY"] = $tailscaleKey
    }
    return $values
}

function Test-ModelRouter {
    param([Parameter(Mandatory)]$Values)

    $headers = @{ Authorization = "Bearer $($Values.OMNIROUTE_API_KEY)" }
    $catalog = Invoke-RestMethod -Uri "$($Values.OMNIROUTE_BASE_URL)/models" -Headers $headers -TimeoutSec 15
    $modelIds = @($catalog.data | ForEach-Object { $_.id })
    if ($Values.SYMPHONY_MODEL -notin $modelIds) {
        throw "SYMPHONY_MODEL is not advertised by the private OmniRoute catalog"
    }
    Write-Host "Private OmniRoute preflight passed for model alias $($Values.SYMPHONY_MODEL)"
}

function Assert-RollbackPrepared {
    if (-not (Test-Path -LiteralPath $PreparationMarker -PathType Leaf)) {
        throw "Rollback proof is missing; run deploy.ps1 -Prepare before -Deploy"
    }

    $proof = Get-Content -LiteralPath $PreparationMarker -Raw | ConvertFrom-Json
    if ($proof.project -ne $Project -or $proof.zone -ne $Zone -or $proof.instance -ne $Instance) {
        throw "Rollback proof targets a different VM"
    }
    if ($proof.backupDir -notmatch '^/var/backups/codex/dokploy-predeploy-[0-9]{8}-[0-9]{6}$') {
        throw "Rollback proof contains an invalid backup path"
    }

    $preparedAt = [DateTimeOffset]::Parse([string]$proof.preparedAt).ToUniversalTime()
    $age = [DateTimeOffset]::UtcNow - $preparedAt
    if ($age.TotalMinutes -lt -5 -or $age.TotalMinutes -gt $PreparationMaxAgeMinutes) {
        throw "Rollback proof is stale; run deploy.ps1 -Prepare again"
    }

    $vm = Get-TargetInstance
    $bootDisk = Get-BootDiskIdentity
    if ($proof.bootDiskSource -ne $bootDisk.Source -or [string]$proof.bootDiskId -ne $bootDisk.Id) {
        throw "Rollback proof boot disk name or immutable ID no longer matches the target VM"
    }

    $status = Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "machine-images", "describe", $proof.machineImage,
        "--project", $Project, "--format=value(status)"
    )
    if (($status | Out-String).Trim() -ne "READY") {
        throw "Rollback machine image is no longer READY"
    }

    Start-Target
    $remoteCheck = "sudo test -s '$($proof.backupDir)/dokploy.sql' -a -s '$($proof.backupDir)/dokploy-etc.tar.gz'"
    Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "ssh", $Instance,
        "--zone", $Zone, "--project", $Project,
        "--command=$remoteCheck"
    ) | Out-Null
    Write-Host "Rollback proof revalidated: $($proof.machineImage) and $($proof.backupDir)"
}

function Prepare-Rollback {
    $vm = Get-TargetInstance
    $bootDisk = Get-BootDiskIdentity
    Write-Host "Target verified: $($vm.name) ($($vm.status))"
    Start-Target

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $backupDir = "/var/backups/codex/dokploy-predeploy-$stamp"
    $remoteBackup = @'
set -euo pipefail
backup_dir="__BACKUP_DIR__"
sudo install -d -m 700 "$backup_dir"
sudo sync
postgres_container=$(sudo docker ps --format '{{.Names}}' | grep -E 'dokploy.*postgres|postgres.*dokploy' | head -n 1)
test -n "$postgres_container"
sudo docker exec "$postgres_container" sh -lc 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | sudo tee "$backup_dir/dokploy.sql" >/dev/null
sudo tar -C /etc -czf "$backup_dir/dokploy-etc.tar.gz" dokploy
sudo sha256sum "$backup_dir/dokploy.sql" "$backup_dir/dokploy-etc.tar.gz"
sudo test -s "$backup_dir/dokploy.sql"
sudo test -s "$backup_dir/dokploy-etc.tar.gz"
sudo sync
'@.Replace("__BACKUP_DIR__", $backupDir)

    $remoteBackupCommand = ConvertTo-RemoteBashCommand -Script $remoteBackup
    $backupProof = Invoke-Rtk -Arguments @(
        "gcloud.cmd", "compute", "ssh", $Instance,
        "--zone", $Zone, "--project", $Project,
        "--command=$remoteBackupCommand"
    )
    Write-Host "Dokploy backup verified at $backupDir"
    $backupProof | ForEach-Object { Write-Host $_ }

    $imageName = "symphony-predeploy-$stamp"
    try {
        Invoke-Rtk -Arguments @(
            "gcloud.cmd", "compute", "instances", "stop", $Instance,
            "--zone", $Zone, "--project", $Project, "--quiet"
        ) | Out-Null

        if ($PSCmdlet.ShouldProcess($Instance, "Create verified machine image $imageName")) {
            Invoke-Rtk -Arguments @(
                "gcloud.cmd", "compute", "machine-images", "create", $imageName,
                "--source-instance", $Instance, "--source-instance-zone", $Zone,
                "--project", $Project,
                "--description", "Pre-Symphony Dokploy rollback $stamp"
            ) | Out-Null
        }

        $status = Invoke-Rtk -Arguments @(
            "gcloud.cmd", "compute", "machine-images", "describe", $imageName,
            "--project", $Project, "--format=value(status)"
        )
        if (($status | Out-String).Trim() -ne "READY") {
            throw "Machine image $imageName is not READY"
        }
        $proof = [ordered]@{
            schema = 1
            project = $Project
            zone = $Zone
            instance = $Instance
            bootDiskSource = $bootDisk.Source
            bootDiskId = $bootDisk.Id
            machineImage = $imageName
            backupDir = $backupDir
            preparedAt = (Get-Date).ToUniversalTime().ToString("o")
        }
        [IO.File]::WriteAllText($PreparationMarker, ($proof | ConvertTo-Json -Depth 4))
        Write-Host "Machine image verified READY: $imageName"
    }
    finally {
        Start-Target
    }
}

function Deploy-Symphony {
    Assert-RollbackPrepared
    $values = Get-RequiredEnvironment -RequireTailscaleKey:$false
    Test-ModelRouter -Values $values

    $projects = @(Invoke-Dokploy -Route "project.all" -Method Get)
    $projectRecord = $projects | Where-Object { $_.name -eq "Symphony" } | Select-Object -First 1
    if ($null -eq $projectRecord) {
        Invoke-Dokploy -Route "project.create" -Body @{ name = "Symphony" } | Out-Null
        $projects = @(Invoke-Dokploy -Route "project.all" -Method Get)
        $projectRecord = $projects | Where-Object { $_.name -eq "Symphony" } | Select-Object -First 1
        if ($null -eq $projectRecord) { throw "Dokploy did not return the created Symphony project" }
    }

    $projectRecord = Invoke-Dokploy -Route "project.one?projectId=$($projectRecord.projectId)" -Method Get
    $environment = @($projectRecord.environments) |
        Where-Object { $_.name -eq "production" } |
        Select-Object -First 1
    if ($null -eq $environment) {
        Invoke-Dokploy -Route "environment.create" -Body @{
            name = "production"
            description = "Private Symphony production"
            projectId = $projectRecord.projectId
        } | Out-Null
        $projectRecord = Invoke-Dokploy -Route "project.one?projectId=$($projectRecord.projectId)" -Method Get
        $environment = @($projectRecord.environments) |
            Where-Object { $_.name -eq "production" } |
            Select-Object -First 1
        if ($null -eq $environment) { throw "Dokploy did not return the created production environment" }
    }

    $projectRecord = Invoke-Dokploy -Route "project.one?projectId=$($projectRecord.projectId)" -Method Get
    $allCompose = @($projectRecord.environments | ForEach-Object {
        if ($null -ne $_.PSObject.Properties["compose"]) { @($_.compose) }
        if ($null -ne $_.PSObject.Properties["composes"]) { @($_.composes) }
    })
    $compose = $allCompose | Where-Object { $_.name -eq "symphony" } | Select-Object -First 1
    $isNew = $null -eq $compose

    if ($isNew) {
        $compose = Invoke-Dokploy -Route "compose.create" -Body @{
            name = "symphony"
            appName = "symphony"
            description = "Linear plus Codex via private OmniRoute"
            environmentId = $environment.environmentId
            composeType = "docker-compose"
        }
    }

    $domains = @(Invoke-Dokploy -Route "domain.byComposeId?composeId=$($compose.composeId)" -Method Get)
    if ($domains.Count -ne 0) {
        throw "Refusing private deployment because the Symphony Compose has Dokploy domains"
    }

    if ($isNew) {
        $values = Get-RequiredEnvironment -RequireTailscaleKey:$true
    }
    $envLines = @($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"

    Invoke-Dokploy -Route "compose.update" -Body @{
        composeId = $compose.composeId
        name = "symphony"
        sourceType = "git"
        customGitUrl = $Repository
        customGitBranch = $Branch
        composePath = "./deploy/dokploy/compose.yaml"
        composeType = "docker-compose"
        autoDeploy = $false
    } | Out-Null

    $domains = @(Invoke-Dokploy -Route "domain.byComposeId?composeId=$($compose.composeId)" -Method Get)
    if ($domains.Count -ne 0) {
        throw "Refusing private deployment because Dokploy domains appeared after update"
    }

    Invoke-Dokploy -Route "compose.saveEnvironment" -Body @{
        composeId = $compose.composeId
        env = $envLines
        createEnvFile = $true
    } | Out-Null

    Invoke-Dokploy -Route "compose.deploy" -Body @{
        composeId = $compose.composeId
        title = "Deploy Symphony $Branch"
        description = "Private Tailscale deployment with durable state"
    } | Out-Null

    $deployment = [ordered]@{
        schema = 1
        projectId = $projectRecord.projectId
        composeId = $compose.composeId
        deployedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
    [IO.File]::WriteAllText($DeploymentMarker, ($deployment | ConvertTo-Json -Depth 3))
    Remove-Item -LiteralPath $PreparationMarker -Force

    Write-Host "Dokploy deployment queued: project=$($projectRecord.projectId) compose=$($compose.composeId)"
    Write-Host "No domain or public port was created"
}

if ($WhatIfPreference) {
    $vm = Get-TargetInstance
    Write-Host "WhatIf target verified: $($vm.name) ($($vm.status))"
    if ($Prepare) {
        Write-Host "WhatIf: back up Dokploy, stop VM, create and verify machine image, restart VM"
    }
    else {
        Write-Host "WhatIf: create or update only Symphony/production/symphony and queue deployment"
    }
    return
}

if ($Prepare) {
    Prepare-Rollback
}
else {
    Deploy-Symphony
}
