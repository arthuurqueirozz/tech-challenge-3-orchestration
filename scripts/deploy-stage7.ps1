$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$settingsPath = Join-Path $repo 'stage6-settings.local.json'
$kubeconfig = Join-Path $repo 'stage6.kubeconfig.local.yaml'
if (!(Test-Path -LiteralPath $settingsPath) -or !(Test-Path -LiteralPath $kubeconfig)) {
    throw 'Deploy stage 6 first (docs/ETAPA-6.md). Stage 7 reuses its isolated cluster and Secrets.'
}
function Check-Exit([string]$Step) { if ($LASTEXITCODE -ne 0) { throw "$Step failed." } }
$state = & docker inspect --format '{{.State.Status}}' fcg-fase3-stage6-control-plane
Check-Exit 'Kind node inspection'
if ($state -eq 'exited') {
    & docker start fcg-fase3-stage6-control-plane
    Check-Exit 'Kind node start'
}
$kube = @('--kubeconfig', $kubeconfig, '--context', 'kind-fcg-fase3-stage6')
$deadline = [DateTime]::UtcNow.AddMinutes(2)
do {
    try {
        & kubectl @kube get nodes --request-timeout=5s *> $null
        if ($LASTEXITCODE -eq 0) { break }
    } catch { # API/RBAC can still be initializing after the node restarts.
    }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
Check-Exit 'Kubernetes API readiness'
& kubectl @kube wait --for=condition=Ready node/fcg-fase3-stage6-control-plane --timeout=120s
Check-Exit 'Kind readiness'
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
$config = Get-Content -Raw -LiteralPath (Join-Path $repo 'k8s/gateway/kong.template.json') | ConvertFrom-Json
$config.consumers[0].jwt_secrets[0].secret = $settings.JwtKey
if ([string]::IsNullOrWhiteSpace($settings.JwtKey)) { throw 'Missing local JWT key.' }
$secret = @{
    apiVersion = 'v1'; kind = 'Secret'; type = 'Opaque'
    metadata = @{ name = 'kong-declarative'; namespace = 'fcg-stage6' }
    stringData = @{ 'kong.json' = ($config | ConvertTo-Json -Depth 30) }
}
$secretPath = Join-Path $repo 'stage7-kong.local.json'
[IO.File]::WriteAllText($secretPath, ($secret | ConvertTo-Json -Depth 35), (New-Object Text.UTF8Encoding($false)))
& kubectl @kube apply -f $secretPath
Check-Exit 'Kong local Secret'
& kubectl @kube apply -k (Join-Path $repo 'k8s/stage7')
Check-Exit 'Stage 7 manifests'
& kubectl @kube -n fcg-stage6 rollout restart deployment/kong
Check-Exit 'Reload Kong declarative configuration'
foreach ($service in @('sqlserver','rabbitmq','redis','users-api','catalog-api','prometheus','grafana','kong')) {
    & kubectl @kube -n fcg-stage6 rollout status "deployment/$service" --timeout=300s
    Check-Exit "Rollout $service"
}
Write-Host 'Stage 7 deployed. Start stage7 access and run stage7-smoke.ps1.'
