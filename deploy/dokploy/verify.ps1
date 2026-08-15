[CmdletBinding()]
param(
    [string]$Project = "project-eb921be9-5a18-4ede-909",
    [string]$Zone = "europe-west1-b",
    [string]$Instance = "instance-20260804-153230-eu",
    [string]$SymphonyUrl = "http://symphony-prod:4021",
    [string]$OmniRouteUrl = "https://ai-router-main.tail31b2b0.ts.net/v1",
    [string]$OmniRouteApiKey = $env:OMNIROUTE_API_KEY,
    [string]$Model = $env:SYMPHONY_MODEL,
    [string]$DokployUrl = $env:DOKPLOY_URL,
    [string]$DokployApiKey = $env:DOKPLOY_API_KEY,
    [string]$ComposeId = $env:DOKPLOY_COMPOSE_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$DeploymentMarker = Join-Path $PSScriptRoot ".deployment.json"

if ([string]::IsNullOrWhiteSpace($ComposeId) -and (Test-Path -LiteralPath $DeploymentMarker -PathType Leaf)) {
    $ComposeId = [string](Get-Content -LiteralPath $DeploymentMarker -Raw | ConvertFrom-Json).composeId
}

if ([string]::IsNullOrWhiteSpace($DokployUrl) -or
    [string]::IsNullOrWhiteSpace($DokployApiKey) -or
    [string]::IsNullOrWhiteSpace($ComposeId)) {
    throw "DOKPLOY_URL, DOKPLOY_API_KEY, and the deployed Compose ID are required"
}

function Invoke-Rtk {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $output = & rtk @Arguments
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Command failed: rtk $($Arguments -join ' ')"
    }
    return @{ Code = $code; Output = $output }
}

function ConvertTo-RemoteBashCommand {
    param([Parameter(Mandatory)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    return "printf '%s' '$encoded' | base64 -d | bash"
}

$vmResult = Invoke-Rtk -Arguments @(
    "gcloud.cmd", "compute", "instances", "describe", $Instance,
    "--zone", $Zone, "--project", $Project,
    "--format=json(name,status,networkInterfaces[0].accessConfigs[0].natIP)"
)
$vm = ($vmResult.Output | ConvertFrom-Json)
if ($vm.name -ne $Instance -or $vm.status -ne "RUNNING") {
    throw "Target VM is not the expected running instance"
}

$remote = @'
set -euo pipefail
for volume in symphony-state symphony-workspaces symphony-codex symphony-tailscale; do
  sudo docker volume inspect "$volume" >/dev/null
done
container=$(sudo docker ps --filter label=com.docker.compose.service=symphony --format '{{.ID}}')
test "$(wc -w <<<"$container")" -eq 1
test "$(sudo docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy
test "$(sudo docker inspect --format '{{.Config.User}}' "$container")" = 10001:10001
sudo docker exec "$container" test -s /var/lib/symphony/state/runtime-state.json
if sudo ss -ltnH 'sport = :4021' | grep -q .; then
  echo 'unexpected host listener on 4021' >&2
  exit 1
fi
tailscale_container=$(sudo docker ps --filter label=com.docker.compose.service=tailscale --format '{{.ID}}')
test "$(wc -w <<<"$tailscale_container")" -eq 1
funnel_status=$(sudo docker exec "$tailscale_container" tailscale funnel status --json)
compact_funnel=$(printf '%s' "$funnel_status" | tr -d '[:space:]')
if printf '%s' "$compact_funnel" | grep -Eq '"AllowFunnel":\{[^}]*true'; then
  echo 'unexpected Tailscale Funnel exposure' >&2
  exit 1
fi
'@
$remoteCommand = ConvertTo-RemoteBashCommand -Script $remote
Invoke-Rtk -Arguments @(
    "gcloud.cmd", "compute", "ssh", $Instance,
    "--zone", $Zone, "--project", $Project,
    "--command=$remoteCommand"
) | Out-Null

$health = Invoke-WebRequest -UseBasicParsing -Uri "$SymphonyUrl/api/v1/health" -TimeoutSec 10
if ($health.StatusCode -ne 200) { throw "Symphony health failed" }
$ready = Invoke-WebRequest -UseBasicParsing -Uri "$SymphonyUrl/api/v1/ready" -TimeoutSec 10
if ($ready.StatusCode -ne 200) { throw "Symphony readiness failed" }

$publicIp = $vm.networkInterfaces[0].accessConfigs[0].natIP
$publicProbe = Invoke-Rtk -AllowFailure -Arguments @(
    "curl.exe", "--connect-timeout", "5", "--silent", "--output", "NUL",
    "http://$publicIp`:4021/api/v1/health"
)
if ($publicProbe.Code -eq 0) {
    throw "public port 4021 is reachable"
}
Write-Host "public port 4021 is closed"

$domainRequest = @{
    Uri = "$($DokployUrl.TrimEnd('/'))/api/domain.byComposeId?composeId=$ComposeId"
    Method = "Get"
    Headers = @{ "x-api-key" = $DokployApiKey }
    TimeoutSec = 15
}
$domainResponse = Invoke-RestMethod @domainRequest
$domains = if ($domainResponse -is [Array] -and $domainResponse.Count -eq 0) {
    @()
} else {
    @($domainResponse)
}
if ($domains.Count -ne 0) {
    throw "Symphony has Dokploy domains and is not private-only"
}
Write-Host "Dokploy domains and Tailscale Funnel exposure are absent"

if ([string]::IsNullOrWhiteSpace($OmniRouteApiKey) -or [string]::IsNullOrWhiteSpace($Model)) {
    throw "OMNIROUTE_API_KEY and SYMPHONY_MODEL are required"
}
$headers = @{ Authorization = "Bearer $OmniRouteApiKey" }
$models = Invoke-RestMethod -Uri "$($OmniRouteUrl.TrimEnd('/'))/models" -Headers $headers -TimeoutSec 15
if (@($models.data).Count -eq 0) { throw "OmniRoute returned no models" }

$responseRequest = @{
    Uri = "$($OmniRouteUrl.TrimEnd('/'))/responses"
    Method = "Post"
    Headers = $headers
    ContentType = "application/json"
    Body = @{ model = $Model; input = "Reply with READY only."; max_output_tokens = 16 } |
        ConvertTo-Json -Compress
    TimeoutSec = 60
}
$response = Invoke-RestMethod @responseRequest
if ([string]::IsNullOrWhiteSpace($response.id)) { throw "OmniRoute Responses canary failed" }

Write-Host "Symphony is healthy and ready over Tailscale"
Write-Host "OmniRoute models and /v1/responses succeeded"
Write-Host "All four durable volumes and non-root container execution are verified"
