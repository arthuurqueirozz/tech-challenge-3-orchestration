[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$StatePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-tunnel.ps1')
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state
$directory = Split-Path ([IO.Path]::GetFullPath($StatePath)) -Parent
$curl = if ($env:OS -eq 'Windows_NT') { 'curl.exe' } else { 'curl' }
$null = Get-Command $curl -ErrorAction Stop
$id = [Guid]::NewGuid().ToString('N')
$curlConfig = Join-Path $directory "$id.curl.local.conf"
$bodyPath = Join-Path $directory "$id.body.local.json"
$responsePath = Join-Path $directory "$id.response.local.json"
$handle = $null
function Quote-CurlConfig([string]$Value) {
    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Invalid credential or curl configuration value.' }
    return '"' + $Value.Replace('\','\\').Replace('"','\"') + '"'
}
try {
    $handle = Start-CloudTunnel -State $state -Purpose Search -DirectoryPath $directory
    # Export only to process memory; never place credentials in argv, Git, output or evidence.
    $credentials = Invoke-CloudAws -Arguments @('configure','export-credentials','--format','process') -Profile $state.AwsProfile -Region $state.Region -AsJson
    foreach ($name in @('AccessKeyId','SecretAccessKey','SessionToken')) { if (-not $credentials.$name) { throw 'An authenticated temporary operator session is required.' } }
    $endpoint = [uri]$state.SearchOutputs.DomainEndpoint
    $settingsUrl = $endpoint.AbsoluteUri.TrimEnd('/') + '/_cluster/settings'
    $lines = @(
        'silent', 'show-error', 'fail', 'connect-timeout = 10', 'max-time = 40',
        ('aws-sigv4 = ' + (Quote-CurlConfig "aws:amz:$($state.Region):es")),
        ('user = ' + (Quote-CurlConfig "$($credentials.AccessKeyId):$($credentials.SecretAccessKey)")),
        ('header = ' + (Quote-CurlConfig "X-Amz-Security-Token: $($credentials.SessionToken)")),
        ('header = "Content-Type: application/json"'),
        ('connect-to = ' + (Quote-CurlConfig "$($endpoint.Host):443:127.0.0.1:9443"))
    )
    Write-CloudPrivateText -Path $curlConfig -Text ($lines -join [Environment]::NewLine)
    Write-CloudPrivateText -Path $responsePath -Text ''
    Write-CloudJson -Path $bodyPath -Value @{persistent=@{'action.auto_create_index'='false'};transient=@{'action.auto_create_index'=$null}}
    $null = Invoke-CloudNative -Executable $curl -Arguments @('--config',$curlConfig,'--request','PUT','--data-binary',('@'+$bodyPath),'--output',$responsePath,'--url',$settingsUrl)
    $null = Invoke-CloudNative -Executable $curl -Arguments @('--config',$curlConfig,'--request','GET','--output',$responsePath,'--url',($settingsUrl+'?flat_settings=true&include_defaults=true'))
    $response = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
    if ([string]$response.persistent.'action.auto_create_index' -ne 'false' -or $response.transient.'action.auto_create_index') { throw 'Managed auto_create_index=false was not verified; do not start Catalog writers.' }
    $state | Add-Member -NotePropertyName SearchSettingsConfirmedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-CloudJson -Path $StatePath -Value $state
    Write-Host 'Verified persistent action.auto_create_index=false on the actual managed domain.'
}
finally {
    $credentials = $null
    if ($handle) { Stop-CloudTunnel -Handle $handle }
    foreach ($path in @($curlConfig,$bodyPath,$responsePath)) { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force } }
}
