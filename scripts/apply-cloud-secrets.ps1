[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Kubeconfig,
    [ValidateNotNullOrEmpty()][string]$Context = 'fcg-fase4',
    [string]$AwsExecutable = $env:FCG_AWS_EXECUTABLE
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')
if ($AwsExecutable) { $env:FCG_AWS_EXECUTABLE = $AwsExecutable }
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state

function Assert-CloudKubeTarget {
    param([object]$State, [string]$Kubeconfig, [string]$Context)
    $identity = Invoke-CloudAws -Arguments @('sts', 'get-caller-identity') -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($identity.Account -ne $State.AccountId) { throw 'The authenticated AWS account differs from the private state.' }
    if (-not $State.NetworkOutputs.ClusterName -or -not $State.NetworkOutputs.ClusterEndpoint) {
        throw 'Real network-compute cluster outputs are required before distributing credentials.'
    }
    $remote = Invoke-CloudAws -Arguments @('eks', 'describe-cluster', '--name', $State.NetworkOutputs.ClusterName) -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($remote.cluster.endpoint -ne $State.NetworkOutputs.ClusterEndpoint -or -not $remote.cluster.certificateAuthority.data) {
        throw 'The live EKS endpoint/CA does not match the expected cluster.'
    }
    $configuration = Invoke-CloudKubectl -Arguments @('config', 'view', '--minify', '--raw') -Kubeconfig $Kubeconfig -Context $Context -AsJson
    if (@($configuration.clusters).Count -ne 1) { throw 'The selected kubeconfig must resolve to exactly one cluster.' }
    $cluster = $configuration.clusters[0].cluster
    if ($cluster.'insecure-skip-tls-verify' -or
        $cluster.'certificate-authority-data' -cne $remote.cluster.certificateAuthority.data) {
        throw 'The kubeconfig must verify the actual EKS certificate authority.'
    }
    $expected = [uri]$remote.cluster.endpoint
    $server = [uri]$cluster.server
    $direct = $server.AbsoluteUri.TrimEnd('/') -ceq $expected.AbsoluteUri.TrimEnd('/')
    $tunnel = $server.Scheme -eq 'https' -and $server.Host -in @('127.0.0.1', 'localhost', '[::1]', '::1') -and
        $server.AbsolutePath -eq '/' -and $cluster.'tls-server-name' -ceq $expected.Host
    if ((-not $direct -and -not $tunnel) -or $server.UserInfo -or $server.Query -or $server.Fragment -or
        ($direct -and $cluster.'tls-server-name' -and $cluster.'tls-server-name' -cne $expected.Host)) {
        throw 'The kubeconfig target must be the actual EKS endpoint or a verified local TLS tunnel.'
    }
}

function Require-Setting {
    param([object]$Value, [string]$Name)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1f\x7f]') {
        throw "Required private-state value $Name is absent or invalid."
    }
    return $Value
}

function New-DatabaseConnection {
    param([string]$Database, [string]$Login, [string]$Password)
    $builder = New-Object System.Data.Common.DbConnectionStringBuilder
    $builder['Server'] = 'tcp:sqlserver.fcg-platform.svc.cluster.local,1433'
    $builder['Database'] = $Database
    $builder['User ID'] = $Login
    $builder['Password'] = $Password
    $builder['Encrypt'] = 'True'
    $builder['TrustServerCertificate'] = 'True'
    $builder['Connection Timeout'] = '30'
    return $builder.ConnectionString
}

function New-KubernetesObject {
    param([string]$Kind, [string]$Namespace, [string]$Name, [System.Collections.IDictionary]$Data)
    $object = [ordered]@{
        apiVersion = 'v1'; kind = $Kind
        metadata = @{ name = $Name; namespace = $Namespace; labels = @{ 'app.kubernetes.io/part-of' = 'fcg' } }
        data = [ordered]@{}
    }
    if ($Kind -eq 'Secret') { $object.type = 'Opaque' }
    foreach ($key in $Data.Keys) {
        $value = [string]$Data[$key]
        $object.data[$key] = if ($Kind -eq 'Secret') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) } else { $value }
    }
    return $object
}

Assert-CloudKubeTarget -State $state -Kubeconfig $Kubeconfig -Context $Context
$secretNames = @('SqlSaPassword', 'UsersAppPassword', 'UsersMigrationPassword', 'CatalogAppPassword',
    'CatalogMigrationPassword', 'RabbitPassword', 'JwtKey', 'AdminSeedName', 'AdminSeedEmail', 'AdminSeedPassword', 'GrafanaPassword')
foreach ($name in $secretNames) { $null = Require-Setting -Value $state.Secrets.$name -Name "Secrets.$name" }
if ([Text.Encoding]::UTF8.GetByteCount($state.Secrets.JwtKey) -lt 32) { throw 'The private-state JWT key is too short.' }

$userQueue = Require-Setting -Value $state.NotificationsOutputs.UserCreatedQueueUrl -Name 'NotificationsOutputs.UserCreatedQueueUrl'
$paymentQueue = Require-Setting -Value $state.NotificationsOutputs.PaymentProcessedQueueUrl -Name 'NotificationsOutputs.PaymentProcessedQueueUrl'
$queuePrefix = 'https://sqs.{0}.amazonaws.com/{1}/' -f $state.Region, $state.AccountId
foreach ($queue in @($userQueue, $paymentQueue)) {
    if (-not $queue.StartsWith($queuePrefix, [StringComparison]::Ordinal) -or
        $queue.Substring($queuePrefix.Length) -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'Queue outputs must belong to the authenticated account and selected region.'
    }
}
$searchEndpoint = Require-Setting -Value $state.SearchOutputs.DomainEndpoint -Name 'SearchOutputs.DomainEndpoint'
$searchUri = $null
if (-not [uri]::TryCreate($searchEndpoint, [UriKind]::Absolute, [ref]$searchUri) -or
    $searchUri.Scheme -ne 'https' -or $searchUri.UserInfo -or $searchUri.AbsolutePath -ne '/' -or
    $searchUri.Query -or $searchUri.Fragment -or -not $searchUri.Host.EndsWith(".$($state.Region).es.amazonaws.com", [StringComparison]::Ordinal)) {
    throw 'The real regional HTTPS OpenSearch endpoint is required.'
}
$indexName = Require-Setting -Value $state.SearchOutputs.IndexName -Name 'SearchOutputs.IndexName'
if ($indexName -notmatch '^[a-z0-9][a-z0-9_-]{0,127}$') { throw 'The actual search index output is invalid.' }

$secrets = @(
    (New-KubernetesObject 'Secret' 'fcg-platform' 'sql-bootstrap-secrets' @{ MSSQL_SA_PASSWORD = $state.Secrets.SqlSaPassword }),
    (New-KubernetesObject 'Secret' 'fcg-platform' 'rabbit-secrets' @{ RABBITMQ_DEFAULT_PASS = $state.Secrets.RabbitPassword }),
    (New-KubernetesObject 'Secret' 'fcg-platform' 'payments-api-secrets' @{ RabbitMq__Password = $state.Secrets.RabbitPassword }),
    (New-KubernetesObject 'Secret' 'fcg-platform' 'grafana-secrets' @{ GF_SECURITY_ADMIN_PASSWORD = $state.Secrets.GrafanaPassword }),
    (New-KubernetesObject 'Secret' 'fcg-users' 'users-api-secrets' @{
        ConnectionStrings__UsersDatabase = (New-DatabaseConnection 'FcgUsersDb' 'fcg_users_app' $state.Secrets.UsersAppPassword)
        Jwt__Key = $state.Secrets.JwtKey
    }),
    (New-KubernetesObject 'Secret' 'fcg-users' 'users-migration-secrets' @{
        ConnectionStrings__UsersDatabase = (New-DatabaseConnection 'FcgUsersDb' 'fcg_users_migrate' $state.Secrets.UsersMigrationPassword)
        AdminSeed__Enabled = 'true'; AdminSeed__Name = $state.Secrets.AdminSeedName
        AdminSeed__Email = $state.Secrets.AdminSeedEmail; AdminSeed__Password = $state.Secrets.AdminSeedPassword
    }),
    (New-KubernetesObject 'Secret' 'fcg-catalog' 'catalog-api-secrets' @{
        ConnectionStrings__CatalogDatabase = (New-DatabaseConnection 'FcgCatalogDb' 'fcg_catalog_app' $state.Secrets.CatalogAppPassword)
        Jwt__Key = $state.Secrets.JwtKey; RabbitMq__Password = $state.Secrets.RabbitPassword
    }),
    (New-KubernetesObject 'Secret' 'fcg-catalog' 'catalog-migration-secrets' @{
        ConnectionStrings__CatalogDatabase = (New-DatabaseConnection 'FcgCatalogDb' 'fcg_catalog_migrate' $state.Secrets.CatalogMigrationPassword)
    })
)
$awsConfiguration = @{ AWS_REGION = $state.Region; AWS_DEFAULT_REGION = $state.Region; AWS_EC2_METADATA_DISABLED = 'true' }
$userConfiguration = @{ Jwt__Issuer = 'FCG'; Jwt__Audience = 'FCG'; Jwt__AccessTokenMinutes = '120'; Sqs__Region = $state.Region; Sqs__QueueUrl = $userQueue; AdminSeed__Enabled = 'false' }
$catalogConfiguration = @{
    Jwt__Issuer = 'FCG'; Jwt__Audience = 'FCG'
    RabbitMq__Host = 'rabbitmq.fcg-platform.svc.cluster.local'; RabbitMq__Port = '5672'; RabbitMq__Username = 'fcg'; RabbitMq__VirtualHost = '/'
    RabbitMq__PaymentProcessedQueue = 'catalog-payment-processed'
    CatalogCache__Configuration = 'redis.fcg-platform.svc.cluster.local:6379'; CatalogCache__TtlSeconds = '60'; CatalogCache__TimeoutMilliseconds = '500'
    Search__Endpoint = $searchEndpoint; Search__IndexName = $indexName; Search__Region = $state.Region; Search__UseAwsAuth = 'true'
    Search__RequestTimeoutSeconds = '5'; Search__BatchSize = '20'; Search__PollIntervalSeconds = '2'; Search__MaxRetryDelaySeconds = '60'
}
$paymentsConfiguration = @{
    RabbitMq__Host = 'rabbitmq.fcg-platform.svc.cluster.local'; RabbitMq__Port = '5672'; RabbitMq__Username = 'fcg'; RabbitMq__VirtualHost = '/'
    RabbitMq__OrderPlacedQueue = 'payments-order-placed'; Payment__ApprovalLimit = '100.00'
    Sqs__Region = $state.Region; Sqs__QueueUrl = $paymentQueue
}
foreach ($settings in @($userConfiguration, $catalogConfiguration, $paymentsConfiguration)) {
    foreach ($key in $awsConfiguration.Keys) { $settings[$key] = $awsConfiguration[$key] }
}
$configMaps = @(
    (New-KubernetesObject 'ConfigMap' 'fcg-users' 'users-api-config' $userConfiguration),
    (New-KubernetesObject 'ConfigMap' 'fcg-catalog' 'catalog-api-config' $catalogConfiguration),
    (New-KubernetesObject 'ConfigMap' 'fcg-platform' 'payments-api-config' $paymentsConfiguration)
)

# Complete every comparison before the first write. Existing Secrets are never updated.
$missing = @()
foreach ($desired in $secrets) {
    $list = Invoke-CloudKubectl -Arguments @('get', 'secrets', '--field-selector', "metadata.name=$($desired.metadata.name)") -Kubeconfig $Kubeconfig -Context $Context -Namespace $desired.metadata.namespace -AsJson
    if ($list.PSObject.Properties.Name -notcontains 'items') { throw 'Secret preflight returned malformed JSON.' }
    $items = @($list.items)
    if ($items.Count -eq 0) { $missing += $desired; continue }
    if ($items.Count -ne 1) { throw 'Secret preflight returned an ambiguous resource list.' }
    $existing = $items[0]
    $keys = @($existing.data.PSObject.Properties.Name)
    $match = $existing.type -eq 'Opaque' -and $keys.Count -eq $desired.data.Keys.Count
    foreach ($key in $desired.data.Keys) {
        if ($keys -notcontains $key -or $existing.data.$key -cne $desired.data[$key]) { $match = $false }
    }
    if (-not $match) {
        throw "Existing Secret $($desired.metadata.namespace)/$($desired.metadata.name) differs from private state. Recover/import its real values; no silent rotation was attempted."
    }
}

$tempPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))) ("cloud-settings-{0}.local.json" -f [Guid]::NewGuid().ToString('N'))
try {
    if ($missing.Count -gt 0) {
        Write-CloudJson -Path $tempPath -Value @{ apiVersion = 'v1'; kind = 'List'; items = @($missing) }
        Assert-CloudWindow -State $state
        $null = Invoke-CloudKubectl -Arguments @('create', '-f', $tempPath) -Kubeconfig $Kubeconfig -Context $Context
    }
    Write-CloudJson -Path $tempPath -Value @{ apiVersion = 'v1'; kind = 'List'; items = @($configMaps) }
    Assert-CloudWindow -State $state
    $null = Invoke-CloudKubectl -Arguments @('apply', '--server-side', '--field-manager=fcg-cloud-bootstrap', '-f', $tempPath) -Kubeconfig $Kubeconfig -Context $Context
}
finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}
Write-Host "Cloud configuration applied; $($missing.Count) missing Secrets created, existing credentials preserved."
