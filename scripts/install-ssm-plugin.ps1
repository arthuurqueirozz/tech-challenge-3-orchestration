[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$DestinationPath)
$ErrorActionPreference = 'Stop'
$version = '1.2.896.0'
$destination = [IO.Path]::GetFullPath($DestinationPath)
$windows = $env:OS -eq 'Windows_NT'
$relativeBinary = if ($windows) { 'bin/session-manager-plugin.exe' } else { 'usr/local/sessionmanagerplugin/bin/session-manager-plugin' }
$binary = Join-Path $destination $relativeBinary
if (Test-Path -LiteralPath $binary -PathType Leaf) {
    $actual = (& $binary --version) -join ''
    if ($LASTEXITCODE -ne 0 -or $actual.Trim() -ne $version) { throw 'An incompatible plugin already exists at DestinationPath.' }
    return (Split-Path $binary -Parent)
}
if (Test-Path -LiteralPath $destination) { throw 'DestinationPath exists without a verified plugin; inspect it before retrying.' }
$null = New-Item -ItemType Directory -Path $destination
$package = Join-Path $destination $(if ($windows) { 'download.zip' } else { 'download.deb' })
$suffix = if ($windows) { 'windows/SessionManagerPlugin.zip' } else { 'ubuntu_64bit/session-manager-plugin.deb' }
$expected = if ($windows) { 'B09ADC18721B6E7A9888C98CB1A3AA55B681B8F12391FC1A983410CB1163F670' } else { '53F51FCC67314A4BF85888A38A3967CD41F8D0F28A60A9469A63ACF935BA713E' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri "https://s3.amazonaws.com/session-manager-downloads/plugin/$version/$suffix" -OutFile $package
if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne $expected) { throw 'Session Manager package checksum mismatch.' }
if ($windows) {
    $outer = Join-Path $destination 'archive'
    Expand-Archive -LiteralPath $package -DestinationPath $outer
    Expand-Archive -LiteralPath (Join-Path $outer 'package.zip') -DestinationPath $destination
    $signature = Get-AuthenticodeSignature -LiteralPath $binary
    if ($signature.Status -ne 'Valid') { throw 'Session Manager executable has no valid Authenticode signature.' }
}
else {
    & dpkg-deb --extract $package $destination
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract the pinned Session Manager package.' }
}
$actual = (& $binary --version) -join ''
if ($LASTEXITCODE -ne 0 -or $actual.Trim() -ne $version) { throw 'Installed Session Manager version differs from the pinned version.' }
return (Split-Path $binary -Parent)
