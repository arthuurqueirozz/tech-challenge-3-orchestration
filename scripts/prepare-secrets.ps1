param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3',
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Account $AccountId
$stack = (Aws cloudformation describe-stacks @{ StackName = 'fcg-fase3-notifications' }).Stacks[0]
if ($stack.StackStatus -notin @('CREATE_COMPLETE','UPDATE_COMPLETE')) { throw 'Cloud stack is not ready.' }
$outputs = @{}
foreach ($output in $stack.Outputs) { $outputs[$output.OutputKey] = $output.OutputValue }
function New-Secret {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}
$settingsPath = Join-Path $repo 'fase3-settings.local.json'
if (!(Test-Path -LiteralPath $settingsPath)) {
    Write-LocalJson $settingsPath @{ AccountId = $AccountId; SqlPassword = New-Secret; RabbitPassword = New-Secret; JwtKey = New-Secret; AdminPassword = New-Secret; GrafanaPassword = New-Secret }
}
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
if ($settings.AccountId -ne $AccountId) { throw 'Local settings belong to another AWS account.' }
$sqlPrefix = 'Server=sqlserver,1433;User Id=sa;Password=' + $settings.SqlPassword + ';TrustServerCertificate=True;Encrypt=False;'
$data = @{
    'sql-secrets' = @{ MSSQL_SA_PASSWORD = $settings.SqlPassword }
    'rabbit-secrets' = @{ RABBITMQ_DEFAULT_PASS = $settings.RabbitPassword }
    'users-secrets' = @{ ConnectionStrings__UsersDatabase = $sqlPrefix + 'Database=FcgUsersDb'; Jwt__Key = $settings.JwtKey; AdminSeed__Password = $settings.AdminPassword }
    'catalog-secrets' = @{ ConnectionStrings__CatalogDatabase = $sqlPrefix + 'Database=FcgCatalogDb'; Jwt__Key = $settings.JwtKey; RabbitMq__Password = $settings.RabbitPassword }
    'payments-secrets' = @{ RabbitMq__Password = $settings.RabbitPassword }
    'grafana-secrets' = @{ GF_SECURITY_ADMIN_USER = 'admin'; GF_SECURITY_ADMIN_PASSWORD = $settings.GrafanaPassword }
}
$expiry = @{}
foreach ($service in @('users','payments')) {
    $roleKey = if ($service -eq 'users') { 'UsersPublisherRoleArn' } else { 'PaymentsPublisherRoleArn' }
    $queueKey = if ($service -eq 'users') { 'UserCreatedQueueUrl' } else { 'PaymentProcessedQueueUrl' }
    if ($outputs[$roleKey] -ne "arn:aws:iam::${AccountId}:role/fcg-fase3-$service-publisher-role") { throw 'Unexpected publisher role output.' }
    $session = Aws sts assume-role @{ RoleArn = $outputs[$roleKey]; RoleSessionName = "fcg-kind-$service"; DurationSeconds = 3600 }
    if (!$session.Credentials.SessionToken) { throw 'No temporary session returned.' }
    $data["$service-aws"] = @{ AWS_ACCESS_KEY_ID = $session.Credentials.AccessKeyId; AWS_SECRET_ACCESS_KEY = $session.Credentials.SecretAccessKey; AWS_SESSION_TOKEN = $session.Credentials.SessionToken; AWS_REGION = 'us-east-1'; Sqs__QueueUrl = $outputs[$queueKey] }
    $expiry[$service] = $session.Credentials.Expiration
    Write-Host "$service STS session expires: $($session.Credentials.Expiration)"
}
$kong = Get-Content -Raw (Join-Path $repo 'k8s/gateway/kong.template.json') | ConvertFrom-Json
$kong.consumers[0].jwt_secrets[0].secret = $settings.JwtKey
$data['kong-declarative'] = @{ 'kong.json' = ($kong | ConvertTo-Json -Depth 30) }
$items = @($data.Keys | ForEach-Object { @{ apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = $_; namespace = 'fcg' }; type = 'Opaque'; stringData = $data[$_] } })
$secretsPath = Join-Path $repo 'fase3-secrets.local.json'
Write-LocalJson $secretsPath @{ apiVersion = 'v1'; kind = 'List'; items = $items }
Write-LocalJson (Join-Path $repo 'fase3-cloud.local.json') @{ AccountId = $AccountId; Outputs = $outputs; Expires = $expiry }
if ($Apply) {
    & kubectl @kube apply -f $secretsPath
    Check-Exit 'Apply Secrets'
    & kubectl @kube rollout restart deployment/users-api deployment/payments-api
    Check-Exit 'Reload STS sessions'
    foreach ($service in @('users-api','payments-api')) { & kubectl @kube rollout status "deployment/$service" --timeout=240s; Check-Exit "Reload $service" }
}
Write-Host 'Prepared ignored local Secrets. Deploy key stays on the host; containers receive restricted one-hour role sessions.'
