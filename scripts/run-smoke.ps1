param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$cloud = Get-Content -Raw (Join-Path $repo 'fase3-cloud.local.json') | ConvertFrom-Json
foreach ($expiry in $cloud.Expires.PSObject.Properties) {
    if ([DateTimeOffset]::Parse($expiry.Value) -lt [DateTimeOffset]::UtcNow.AddMinutes(15)) { throw 'Renew publisher credentials with prepare-secrets.ps1 -Apply before this smoke.' }
}
& (Join-Path $PSScriptRoot 'stage7-smoke.ps1') -KubeconfigName fase3.kubeconfig.local.yaml -Context kind-fcg-fase3 -Namespace fcg -SettingsName fase3-settings.local.json -EvidenceName gateway-evidence.local.json -AllowMonitoringAccess
try {
    & (Join-Path $PSScriptRoot 'set-notifications.ps1') -Enabled true -AccountId $AccountId -Profile $Profile
    & (Join-Path $PSScriptRoot 'integrated-smoke.ps1') -Profile $Profile
}
finally { & (Join-Path $PSScriptRoot 'set-notifications.ps1') -Enabled false -AccountId $AccountId -Profile $Profile }
& (Join-Path $PSScriptRoot 'collect-stage4-logs.ps1') -Profile $Profile -EvidenceName integrated-smoke.local.json
Write-Host 'Gateway and integrated cloud smoke complete. Triggers confirmed paused; inspect Grafana, then run stop.ps1.'
