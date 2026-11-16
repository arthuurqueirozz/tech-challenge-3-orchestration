[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateSet('users','catalog')][string]$Service,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$OrchestrationRepository = 'arthuurqueirozz/tech-challenge-3-orchestration',
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$OrchestrationRef
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state
if (-not $Repository) { $Repository = "arthuurqueirozz/tech-challenge-2-$Service-api" }
if ($Repository -cne "arthuurqueirozz/tech-challenge-2-$Service-api" -or
    $OrchestrationRepository -cne 'arthuurqueirozz/tech-challenge-3-orchestration') { throw 'Only the existing repositories authorized for this project may receive deploy credentials/configuration.' }
$gh = (Get-Command gh -CommandType Application -ErrorAction Stop).Source
$null = Invoke-CloudNative -Executable $gh -Arguments @('auth','status','--hostname','github.com')
$account = Invoke-CloudAws -Arguments @('sts','get-caller-identity') -Profile $state.AwsProfile -Region $state.Region -AsJson
if ($account.Account -cne $state.AccountId) { throw 'The AWS operator differs from the intended account.' }
$property = (Get-Culture).TextInfo.ToTitleCase($Service) + 'DeployRoleArn'
$roleArn = [string]$state.DeployOutputs.$property
if ($roleArn -cne "arn:aws:iam::$($state.AccountId):role/fiap-f4-$Service-deploy") { throw 'Only the separate restricted deploy role may be uploaded to GitHub.' }
if ($state.GatewayOutputs.HttpsConfigured -cne 'true') { throw 'Activate and verify HTTPS before configuring deployment smoke URLs.' }
if ($state.NetworkOutputs.ClusterName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$' -or
    $state.NodeInstanceId -cnotmatch '^i-([0-9a-f]{8}|[0-9a-f]{17})$' -or
    $state.DeployOutputs.EksTunnelDocumentName -cne 'fcg-fase4-eks-tunnel') { throw 'The verified cluster, node and fixed SSM document are required.' }
$baseUrl = $null
if (-not [uri]::TryCreate([string]$state.GatewayOutputs.PublicUrl,[UriKind]::Absolute,[ref]$baseUrl) -or
    $baseUrl.Scheme -cne 'https' -or $baseUrl.Port -ne 443 -or $baseUrl.UserInfo -or $baseUrl.Query -or $baseUrl.Fragment -or
    $baseUrl.AbsolutePath -cne '/' -or $baseUrl.Host -cne $state.GatewayOutputs.PublicIp) { throw 'A verified HTTPS gateway URL for the actual public IP is required.' }
$ghUser = Invoke-CloudNative -Executable $gh -Arguments @('api','user') -AsJson
if ($ghUser.login -cne 'leo-bernar') { throw 'Authenticate gh as the GitHub identity authorized for this project (leo-bernar).' }
$null = Invoke-CloudNative -Executable $gh -Arguments @('api',"repos/$OrchestrationRepository/commits/$OrchestrationRef") -AsJson
$statusUrl = $baseUrl.AbsoluteUri.TrimEnd('/') + "/status/$Service"
$status = Invoke-WebRequest -UseBasicParsing -Uri $statusUrl -MaximumRedirection 0 -TimeoutSec 15
$body = ConvertFrom-CloudJson -Json $status.Content
$expectedService = if ($Service -eq 'users') { 'FCG Users API' } else { 'FCG Catalog API' }
if ([int]$status.StatusCode -ne 200 -or $status.Headers['X-Build-Sha'] -notmatch '^[0-9a-f]{40}$' -or $body.service -cne $expectedService -or $body.status -cne 'running') { throw 'The actual HTTPS status route is not ready for pipeline verification.' }
$duration = [Math]::Min(3600, [Math]::Floor(([DateTimeOffset]::Parse($state.WindowEndUtc) - [DateTimeOffset]::UtcNow).TotalSeconds))
if ($duration -lt 1200) { throw 'Less than twenty minutes remain in the approved window; do not start another deployment.' }
$session = Invoke-CloudAws -Arguments @('sts','assume-role','--role-arn',$roleArn,'--role-session-name',("fcg-$Service-"+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')),'--duration-seconds',[string][int]$duration) -Profile $state.AwsProfile -Region $state.Region -AsJson
if ($session.AssumedRoleUser.Arn -notlike "arn:aws:sts::$($state.AccountId):assumed-role/fiap-f4-$Service-deploy/*") { throw 'STS did not return the intended restricted role.' }
$variables = [ordered]@{
    AWS_ACCOUNT_ID=$state.AccountId; AWS_REGION=$state.Region; AWS_SESSION_EXPIRES_AT=$session.Credentials.Expiration
    ECR_REPOSITORY="$($state.ProjectName)/$Service"; EKS_CLUSTER_NAME=$state.NetworkOutputs.ClusterName
    K8S_NAMESPACE="fcg-$Service"; ORCHESTRATION_REPOSITORY=$OrchestrationRepository; ORCHESTRATION_REF=$OrchestrationRef
    SSM_NODE_INSTANCE_ID=$state.NodeInstanceId; SSM_TUNNEL_DOCUMENT_NAME=$state.DeployOutputs.EksTunnelDocumentName
    SMOKE_URL=$statusUrl
}
# Each secret travels over stdin. Never use --body with secret values or write them to disk.
function Set-RepositorySecret([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'STS returned an incomplete session.' }
    $preference=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $captured=@($Value | & $gh secret set $Name --repo $Repository 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$preference }
    if ($code -ne 0) { throw "Cannot set repository secret $Name; the private response was suppressed." }
}
try {
    # Reject new deployment starts throughout a partial renewal; activate expiry last.
    $null = Invoke-CloudNative -Executable $gh -Arguments @('variable','set','AWS_SESSION_EXPIRES_AT','--repo',$Repository,'--body','1970-01-01T00:00:00Z')
    foreach ($name in $variables.Keys | Where-Object { $_ -ne 'AWS_SESSION_EXPIRES_AT' }) {
        $null = Invoke-CloudNative -Executable $gh -Arguments @('variable','set',$name,'--repo',$Repository,'--body',[string]$variables[$name])
    }
    Set-RepositorySecret 'AWS_ACCESS_KEY_ID' $session.Credentials.AccessKeyId
    Set-RepositorySecret 'AWS_SECRET_ACCESS_KEY' $session.Credentials.SecretAccessKey
    Set-RepositorySecret 'AWS_SESSION_TOKEN' $session.Credentials.SessionToken
    $null = Invoke-CloudNative -Executable $gh -Arguments @('variable','set','AWS_SESSION_EXPIRES_AT','--repo',$Repository,'--body',[string]$variables.AWS_SESSION_EXPIRES_AT)
    Write-Host "Restricted one-hour session installed for $Repository; expires $($session.Credentials.Expiration)."
}
finally { $session=$null }
