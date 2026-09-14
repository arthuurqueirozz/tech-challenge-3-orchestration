param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
$awsExe = if ($awsCommand) { $awsCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe' }
$utf8 = New-Object Text.UTF8Encoding($false)
$identity = & $awsExe sts get-caller-identity --profile $Profile --output json --no-cli-pager | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $identity.Account -ne $AccountId -or !$identity.Arn.EndsWith(':user/fiap-fase3-cli')) { throw 'Unexpected AWS account or deploy user.' }
function New-LocalSecret {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}
$settingsPath = Join-Path $repo 'stage4.local.env'
if (!(Test-Path -LiteralPath $settingsPath)) {
    $settings = @(
        'FCG_SQL_PASSWORD=' + (New-LocalSecret)
        'FCG_JWT_KEY=' + (New-LocalSecret)
        'FCG_RABBIT_USER=fcg-stage4'
        'FCG_RABBIT_PASSWORD=' + (New-LocalSecret)
        'FCG_ADMIN_PASSWORD=' + (New-LocalSecret)
        "USER_CREATED_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/$AccountId/fcg-fase3-user-created"
        "PAYMENT_PROCESSED_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/$AccountId/fcg-fase3-payment-processed"
    )
    [IO.File]::WriteAllLines($settingsPath, $settings, $utf8)
}
# Only short-lived role credentials enter containers. Never write the deploy user's key here.
foreach ($service in @('users', 'payments')) {
    $roleArn = "arn:aws:iam::${AccountId}:role/fcg-fase3-$service-publisher-role"
    $session = & $awsExe sts assume-role --role-arn $roleArn --role-session-name "fcg-stage4-$service" --duration-seconds 3600 --profile $Profile --region us-east-1 --output json --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or !$session.Credentials.SessionToken) { throw "Unable to assume $service publisher role." }
    $runtimePath = Join-Path $repo "$service-runtime.local.env"
    [IO.File]::WriteAllLines($runtimePath, @(
        'AWS_ACCESS_KEY_ID=' + $session.Credentials.AccessKeyId
        'AWS_SECRET_ACCESS_KEY=' + $session.Credentials.SecretAccessKey
        'AWS_SESSION_TOKEN=' + $session.Credentials.SessionToken
        'AWS_REGION=us-east-1'
        'AWS_EC2_METADATA_DISABLED=true'
    ), $utf8)
    Write-Host "$service temporary credentials prepared; expiration: $($session.Credentials.Expiration)"
}
Write-Host 'Local files prepared. Recreate users-api/payments-api after renewing credentials. Never print docker compose config or container environment.'
