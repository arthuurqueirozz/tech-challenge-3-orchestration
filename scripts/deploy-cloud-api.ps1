[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('users','catalog')][string]$Service,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{12}$')][string]$AccountId,
    [ValidateSet('us-east-2')][string]$Region = 'us-east-2',
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][ValidatePattern('^i-([0-9a-f]{8}|[0-9a-f]{17})$')][string]$NodeInstanceId,
    [Parameter(Mandatory = $true)][string]$TunnelDocumentName,
    [Parameter(Mandatory = $true)][string]$Kubeconfig,
    [string]$Context = 'fcg-fase4',
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$BuildSha,
    [Parameter(Mandatory = $true)][string]$OrchestrationRef,
    [Parameter(Mandatory = $true)][string]$DeploymentId,
    [Parameter(Mandatory = $true)][uri]$SmokeUrl,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-tunnel.ps1')
if ($Namespace -cne "fcg-$Service") { throw 'Each API deploy role must use its own namespace.' }
$state = [pscustomobject]@{
    AccountId = $AccountId; Region = $Region; ProjectName = 'fcg-fase4'; AwsProfile = ''
    WindowStartUtc = '2026-11-13T23:00:00Z'; WindowEndUtc = '2026-11-18T23:00:00Z'
    NodeInstanceId = $NodeInstanceId
    NetworkOutputs = $null
    DeployOutputs = [pscustomobject]@{ EksTunnelDocumentName = $TunnelDocumentName }
}
Assert-CloudWindow -State $state
$cluster = Invoke-CloudAws -Arguments @('eks','describe-cluster','--name',$ClusterName) -Region $Region -AsJson
$state.NetworkOutputs = [pscustomobject]@{ ClusterName = $ClusterName; ClusterEndpoint = $cluster.cluster.endpoint }
$directory = Split-Path ([IO.Path]::GetFullPath($Kubeconfig)) -Parent
$handle = $null
try {
    $handle = Start-CloudTunnel -State $state -DirectoryPath $directory -Kubeconfig $Kubeconfig -Context $Context
    & (Join-Path $PSScriptRoot 'deploy-api.ps1') -Service $Service -Kubeconfig $Kubeconfig -Context $Context -Namespace $Namespace -Image $Image -BuildSha $BuildSha -OrchestrationRef $OrchestrationRef -DeploymentId $DeploymentId -SmokeUrl $SmokeUrl -OutputPath $OutputPath
    if ($LASTEXITCODE -ne 0) { throw 'API migration/rollout failed; inspect its redacted deployment result.' }
}
finally {
    if ($handle) { Stop-CloudTunnel -Handle $handle }
    if (Test-Path -LiteralPath $Kubeconfig -PathType Leaf) { Remove-Item -LiteralPath $Kubeconfig -Force }
}
