param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3'
)
. (Join-Path $PSScriptRoot 'common.ps1')
$kindExe = Resolve-Tool kind (Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages/Kubernetes.kind_Microsoft.Winget.Source_8wekyb3d8bbwe/kind.exe')
$null = & docker info --format '{{.OSType}}'
Check-Exit 'Docker Linux engine (start Docker Desktop first)'
foreach ($service in @('users','catalog','payments')) {
    & docker build -t "fcg-${service}:fase3" (Join-Path $repo "../tech-challenge-2-$service-api")
    Check-Exit "Build $service"
}
$clusters = & $kindExe get clusters
Check-Exit 'Kind inventory'
if ($clusters -notcontains $cluster) {
    & $kindExe create cluster --name $cluster --image kindest/node:v1.37.0 --kubeconfig $config --wait 180s
    Check-Exit 'Create Kind'
} else {
    $state = & docker inspect --format '{{.State.Status}}' "$cluster-control-plane"
    Check-Exit 'Kind state'
    if ($state -eq 'exited') { & docker start "$cluster-control-plane"; Check-Exit 'Start Kind' }
    if (!(Test-Path -LiteralPath $config)) { & $kindExe export kubeconfig --name $cluster --kubeconfig $config; Check-Exit 'Export kubeconfig' }
}
Wait-Until { try { & kubectl @kube get nodes --request-timeout=5s *> $null; $LASTEXITCODE -eq 0 } catch { $false } } 'Kubernetes API'
& kubectl @kube wait --for=condition=Ready node/fcg-fase3-control-plane --timeout=180s
Check-Exit 'Node readiness'
foreach ($service in @('users','catalog','payments')) {
    & $kindExe load docker-image "fcg-${service}:fase3" --name $cluster
    Check-Exit "Load $service"
}
& (Join-Path $PSScriptRoot 'prepare-secrets.ps1') -AccountId $AccountId -Profile $Profile
& kubectl @kube apply -f (Join-Path $repo 'k8s/final/namespace.yaml')
Check-Exit 'Namespace'
& kubectl @kube apply -f (Join-Path $repo 'fase3-secrets.local.json')
Check-Exit 'Secrets'
& kubectl @kube apply -k (Join-Path $repo 'k8s/final')
Check-Exit 'Final manifests'
# SQL/Rabbit must be ready before the applications migrate/connect after cold start.
foreach ($service in @('sqlserver','rabbitmq','redis')) {
    & kubectl @kube rollout status "deployment/$service" --timeout=300s
    Check-Exit "Dependency $service"
}
& kubectl @kube rollout restart deployment/users-api deployment/catalog-api deployment/payments-api deployment/kong
Check-Exit 'Load local images and Secrets'
foreach ($service in @('users-api','catalog-api','payments-api','kong','prometheus','grafana')) {
    & kubectl @kube rollout status "deployment/$service" --timeout=300s
    Check-Exit "Deployment $service"
}
Write-Host 'Final stack deployed. Run start-access.ps1, then run-smoke.ps1. AWS mappings remain paused until explicitly enabled.'
