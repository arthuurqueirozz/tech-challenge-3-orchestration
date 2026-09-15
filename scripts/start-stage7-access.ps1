$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$config = Join-Path $repo 'stage6.kubeconfig.local.yaml'
$processFile = Join-Path $repo 'stage7-access.local.json'
if (Test-Path -LiteralPath $processFile) { throw 'Run stop-stage7-access.ps1 before starting another access session.' }
& (Join-Path $PSScriptRoot 'stop-stage6-access.ps1')
$kubectl = (Get-Command kubectl).Source
$processes = @()
try {
    foreach ($target in ,@('kong',18000,8000)) {
        if (Get-NetTCPConnection -LocalPort $target[1] -State Listen -ErrorAction SilentlyContinue) { throw ('Port already in use: ' + $target[1]) }
        $arguments = '--kubeconfig "' + $config + '" --context kind-fcg-fase3-stage6 -n fcg-stage6 port-forward --address 127.0.0.1 service/' + $target[0] + ' ' + $target[1] + ':' + $target[2]
        $process = Start-Process -FilePath $kubectl -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $repo ($target[0] + '-stage7.local.log')) -RedirectStandardError (Join-Path $repo ($target[0] + '-stage7-error.local.log'))
        $processes += @{ id = $process.Id; service = $target[0]; port = $target[1] }
    }
    [IO.File]::WriteAllText($processFile, (ConvertTo-Json -InputObject @($processes)), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Business access: Kong http://127.0.0.1:18000. Stop with stop-stage7-access.ps1.'
}
catch { foreach ($entry in $processes) { Stop-Process -Id $entry.id -ErrorAction SilentlyContinue }; throw }
