$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$config = Join-Path $repo 'stage6.kubeconfig.local.yaml'
$processFile = Join-Path $repo 'stage6-access.local.json'
if (Test-Path -LiteralPath $processFile) { throw 'Run stop-stage6-access.ps1 before starting another access session.' }
$kubectl = (Get-Command kubectl).Source
$processes = @()
try {
    foreach ($target in @(@('users-api',18080,8080), @('catalog-api',18081,8080), @('prometheus',19090,9090), @('grafana',13000,3000))) {
        if (Get-NetTCPConnection -LocalPort $target[1] -State Listen -ErrorAction SilentlyContinue) { throw ('Port already in use: ' + $target[1]) }
        $arguments = '--kubeconfig "' + $config + '" --context kind-fcg-fase3-stage6 -n fcg-stage6 port-forward --address 127.0.0.1 service/' + $target[0] + ' ' + $target[1] + ':' + $target[2]
        $process = Start-Process -FilePath $kubectl -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $repo ($target[0] + '-stage6.local.log')) -RedirectStandardError (Join-Path $repo ($target[0] + '-stage6-error.local.log'))
        $processes += @{ id = $process.Id; service = $target[0]; port = $target[1] }
    }
    [IO.File]::WriteAllText($processFile, (ConvertTo-Json -InputObject @($processes)), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Local access: Users 18080, Catalog 18081, Prometheus 19090, Grafana 13000. Stop with stop-stage6-access.ps1.'
}
catch { foreach ($entry in $processes) { Stop-Process -Id $entry.id -ErrorAction SilentlyContinue }; throw }
