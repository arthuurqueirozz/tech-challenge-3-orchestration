param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Name = 'search',
    [ValidateRange(1024, 65535)]
    [int]$Port = 18084
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$settingsPath = Join-Path $repo "$Name.local.env"
$catalogPath = Join-Path $repo "$Name.catalog.local.env"
$kongPath = Join-Path $repo "$Name.kong.local.json"
$paths = @($settingsPath, $catalogPath, $kongPath)
$existing = @($paths | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -eq $paths.Count) {
    Write-Host 'Existing local search settings preserved. Use their configured port.'
    return
}
if ($existing.Count -gt 0) {
    throw 'Partial local search settings exist. Inspect and preserve them before regenerating.'
}
function New-SearchLocalSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}
$sqlPassword = New-SearchLocalSecret
$rabbitPassword = New-SearchLocalSecret
$jwtKey = New-SearchLocalSecret
$encoding = New-Object Text.UTF8Encoding($false)
$template = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo 'k8s/gateway/kong.template.json')
if (-not $template.Contains('__JWT_SECRET_FROM_LOCAL_SETTINGS__')) {
    throw 'Expected gateway secret placeholder is missing.'
}
$rendered = $template.Replace('__JWT_SECRET_FROM_LOCAL_SETTINGS__', $jwtKey)
$null = $rendered | ConvertFrom-Json
[IO.File]::WriteAllLines($settingsPath, @(
    "FCG_SQL_PASSWORD=$sqlPassword"
    "FCG_RABBIT_PASSWORD=$rabbitPassword"
    "FCG_JWT_KEY=$jwtKey"
    "FCG_CATALOG_ENV_FILE=./$Name.catalog.local.env"
    "FCG_KONG_CONFIG_FILE=./$Name.kong.local.json"
    "FCG_CATALOG_IMAGE=fcg-catalog:fase4-$Name"
    "FCG_GATEWAY_PORT=$Port"
), $encoding)
[IO.File]::WriteAllLines($catalogPath, @(
    "ConnectionStrings__CatalogDatabase=Server=sqlserver,1433;Database=FcgCatalogSearchDb;User Id=sa;Password=$sqlPassword;TrustServerCertificate=True;Encrypt=False"
    'Jwt__Issuer=FCG'
    'Jwt__Audience=FCG'
    "Jwt__Key=$jwtKey"
    'RabbitMq__Host=rabbitmq'
    'RabbitMq__Port=5672'
    'RabbitMq__VirtualHost=/'
    'RabbitMq__Username=fcg-search'
    "RabbitMq__Password=$rabbitPassword"
    'RabbitMq__PaymentProcessedQueue=catalog-payment-processed-search'
    'CatalogCache__Configuration=redis:6379'
    'CatalogCache__TtlSeconds=60'
    'CatalogCache__TimeoutMilliseconds=500'
), $encoding)
[IO.File]::WriteAllText($kongPath, $rendered, $encoding)
Write-Host "Local search settings created for '$Name'; gateway port $Port. No AWS credentials used."
