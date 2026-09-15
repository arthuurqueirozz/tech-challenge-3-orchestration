$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$kindCommand = Get-Command kind -ErrorAction SilentlyContinue
$kindExe = if ($kindCommand) { $kindCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Kubernetes.kind_Microsoft.Winget.Source_8wekyb3d8bbwe\kind.exe' }
$kubeconfig = Join-Path $repo 'stage6.kubeconfig.local.yaml'
$settingsPath = Join-Path $repo 'stage6-settings.local.json'
$utf8 = New-Object Text.UTF8Encoding($false)
function Check-Exit([string]$Step) { if ($LASTEXITCODE -ne 0) { throw "$Step failed." } }
function New-Secret {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}
if (!(Test-Path -LiteralPath $settingsPath)) {
    $settings = @{ SqlPassword = New-Secret; RabbitPassword = New-Secret; JwtKey = New-Secret; AdminPassword = New-Secret; GrafanaPassword = New-Secret }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), $utf8)
}
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
$clusters = & $kindExe get clusters
Check-Exit 'Kind inventory'
if ($clusters -notcontains 'fcg-fase3-stage6') {
    & $kindExe create cluster --name fcg-fase3-stage6 --image kindest/node:v1.37.0 --kubeconfig $kubeconfig --wait 120s
    Check-Exit 'Kind creation'
}
elseif (!(Test-Path -LiteralPath $kubeconfig)) {
    & $kindExe export kubeconfig --name fcg-fase3-stage6 --kubeconfig $kubeconfig
    Check-Exit 'Kubeconfig export'
}
foreach ($service in @('users','catalog')) {
    & docker build -t "fcg-${service}:stage6" (Join-Path $repo "../tech-challenge-2-$service-api")
    Check-Exit "Build $service"
    & $kindExe load docker-image "fcg-${service}:stage6" --name fcg-fase3-stage6
    Check-Exit "Load $service"
}
$kube = @('--kubeconfig', $kubeconfig, '--context', 'kind-fcg-fase3-stage6')
& kubectl @kube apply -f (Join-Path $repo 'k8s/stage6/namespace.yaml')
Check-Exit 'Namespace'
$sqlPrefix = 'Server=sqlserver,1433;User Id=sa;Password=' + $settings.SqlPassword + ';TrustServerCertificate=True;Encrypt=False;'
$secretData = @{
    'sql-secrets' = @{ MSSQL_SA_PASSWORD = $settings.SqlPassword }
    'rabbit-secrets' = @{ RABBITMQ_DEFAULT_PASS = $settings.RabbitPassword }
    'users-secrets' = @{ ConnectionStrings__UsersDatabase = $sqlPrefix + 'Database=FcgUsersDb'; Jwt__Key = $settings.JwtKey; AdminSeed__Password = $settings.AdminPassword }
    'catalog-secrets' = @{ ConnectionStrings__CatalogDatabase = $sqlPrefix + 'Database=FcgCatalogDb'; Jwt__Key = $settings.JwtKey; RabbitMq__Password = $settings.RabbitPassword }
    'grafana-secrets' = @{ GF_SECURITY_ADMIN_USER = 'admin'; GF_SECURITY_ADMIN_PASSWORD = $settings.GrafanaPassword }
}
$items = @($secretData.Keys | ForEach-Object { @{ apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = $_; namespace = 'fcg-stage6' }; type = 'Opaque'; stringData = $secretData[$_] } })
$secretPath = Join-Path $repo 'stage6-secrets.local.json'
[IO.File]::WriteAllText($secretPath, (@{ apiVersion = 'v1'; kind = 'List'; items = $items } | ConvertTo-Json -Depth 12), $utf8)
& kubectl @kube apply -f $secretPath
Check-Exit 'Local Secrets'
& kubectl @kube apply -k (Join-Path $repo 'k8s/stage6')
Check-Exit 'Stage 6 manifests'
& kubectl @kube -n fcg-stage6 rollout restart deployment/users-api deployment/catalog-api
Check-Exit 'Reload locally built API images'
foreach ($service in @('sqlserver','rabbitmq','redis','users-api','catalog-api','prometheus','grafana')) {
    & kubectl @kube -n fcg-stage6 rollout status "deployment/$service" --timeout=300s
    Check-Exit "Rollout $service"
}
Write-Host 'Stage 6 deployed. Run scripts/stage6-smoke.ps1. Secrets are in ignored local files.'
