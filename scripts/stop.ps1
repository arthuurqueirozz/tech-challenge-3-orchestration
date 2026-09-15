param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3'
)
. (Join-Path $PSScriptRoot 'common.ps1')
try { & (Join-Path $PSScriptRoot 'set-notifications.ps1') -Enabled false -AccountId $AccountId -Profile $Profile }
finally {
    try { & (Join-Path $PSScriptRoot 'stop-access.ps1') }
    finally {
        & docker stop fcg-fase3-control-plane
        Check-Exit 'Stop Kind (data preserved)'
    }
}
