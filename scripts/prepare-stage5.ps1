$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$settingsPath = Join-Path $repo 'stage5.local.env'
if (Test-Path -LiteralPath $settingsPath) { Write-Host 'Existing stage 5 local settings preserved.'; return }
function New-LocalSecret {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}
[IO.File]::WriteAllLines($settingsPath, @(
    'FCG_SQL_PASSWORD=' + (New-LocalSecret)
    'FCG_RABBIT_PASSWORD=' + (New-LocalSecret)
    'FCG_JWT_KEY=' + (New-LocalSecret)
), (New-Object Text.UTF8Encoding($false)))
Write-Host 'Stage 5 local secrets generated. No AWS credentials required.'
