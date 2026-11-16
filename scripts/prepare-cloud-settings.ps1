[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')

function Set-MissingProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function New-PrivatePassword {
    $bytes = New-Object byte[] 24
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return 'Aa1!' + [Convert]::ToBase64String($bytes)
}

$resolvedPath = [IO.Path]::GetFullPath($StatePath)
$ancestor = [IO.Path]::GetDirectoryName($resolvedPath)
while ($ancestor) {
    if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
        throw 'Keep the private cloud state outside every Git working tree.'
    }
    if ([IO.Path]::GetFileName($ancestor) -eq 'reference') {
        throw 'The immutable reference directory cannot contain generated cloud state.'
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}

if (Test-Path -LiteralPath $resolvedPath) {
    Protect-CloudFile -Path $resolvedPath
    try {
        $rawJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedPath
        if ($rawJson -notmatch '^\s*\{') { throw 'Expected an object.' }
        $state = ConvertFrom-CloudJson -Json $rawJson
    }
    catch { throw 'The existing private state is not valid JSON; recover it without regenerating credentials.' }
    if ($null -eq $state -or $state -is [array] -or $state -isnot [pscustomobject] -or
        $state.PSObject.Properties.Name -notcontains 'SchemaVersion' -or $state.SchemaVersion -ne 1) {
        throw 'The existing state must be a SchemaVersion 1 object; it was not changed.'
    }
}
else {
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 1
        AccountId = ''
        Region = 'us-east-2'
        ProjectName = 'fcg-fase4'
        AwsProfile = 'fiap-fase4'
        WindowStartUtc = '2026-11-13T23:00:00Z'
        WindowEndUtc = '2026-11-18T23:00:00Z'
        AdminRoleArn = ''
        AdminCidrIPv4 = ''
        AvailabilityZoneA = ''
        AvailabilityZoneB = ''
    }
}

foreach ($name in @('NetworkOutputs', 'NotificationsOutputs', 'RuntimeOutputs', 'SearchOutputs', 'DeployOutputs', 'GatewayOutputs', 'Images', 'Secrets')) {
    Set-MissingProperty -Object $state -Name $name -Value ([pscustomobject]@{})
    if ($null -eq $state.$name -or $state.$name -isnot [pscustomobject] -or $state.$name -is [array]) {
        throw "The existing $name value must be a JSON object; nothing was overwritten."
    }
}

$generated = 0
$passwordNames = @('SqlSaPassword', 'UsersAppPassword', 'UsersMigrationPassword', 'CatalogAppPassword',
    'CatalogMigrationPassword', 'RabbitPassword', 'JwtKey', 'AdminSeedPassword', 'GrafanaPassword')
foreach ($name in $passwordNames) {
    if ($state.Secrets.PSObject.Properties.Name -notcontains $name) {
        $state.Secrets | Add-Member -MemberType NoteProperty -Name $name -Value (New-PrivatePassword)
        $generated++
    }
    $value = $state.Secrets.$name
    if ($value -isnot [string] -or $value.Length -lt 20 -or $value.Length -gt 128 -or $value -match '[\x00-\x1f\x7f]') {
        throw "Existing secret $name is missing or invalid; recover/import its actual value instead of rotating silently."
    }
}
if ([Text.Encoding]::UTF8.GetByteCount($state.Secrets.JwtKey) -lt 32) {
    throw 'The existing JWT key is too short; recover the actual configured key before continuing.'
}
Set-MissingProperty -Object $state.Secrets -Name 'AdminSeedName' -Value 'FCG Demo Admin'
Set-MissingProperty -Object $state.Secrets -Name 'AdminSeedEmail' -Value 'admin@fcg.example.test'
if ([string]::IsNullOrWhiteSpace($state.Secrets.AdminSeedName) -or
    [string]::IsNullOrWhiteSpace($state.Secrets.AdminSeedEmail)) {
    throw 'Existing synthetic admin seed fields must be recovered explicitly; they were not replaced.'
}

# Write-CloudJson protects a new file before writing sensitive content.
$directory = [IO.Path]::GetDirectoryName($resolvedPath)
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $directory -Force
}
Write-CloudJson -Path $resolvedPath -Value $state
Protect-CloudFile -Path $resolvedPath
Write-Host "Private local state prepared; generated $generated missing secrets. No cluster or AWS resources were changed."
