. (Join-Path $PSScriptRoot 'common.ps1')
$processFile = Join-Path $repo 'fase3-access.local.json'
if (Test-Path -LiteralPath $processFile) { throw 'Run stop-access.ps1 before opening another access session.' }
& (Join-Path $PSScriptRoot 'stop-stage6-access.ps1')
& (Join-Path $PSScriptRoot 'stop-stage7-access.ps1')
$kubectlExe = Resolve-Tool kubectl ''
$processes = @()
try {
    foreach ($target in @(@('kong',18000,8000),@('prometheus',19090,9090),@('grafana',13000,3000))) {
        if (Get-NetTCPConnection -LocalPort $target[1] -State Listen -ErrorAction SilentlyContinue) { throw ('Port already in use: ' + $target[1]) }
        $arguments = '--kubeconfig "' + $config + '" --context kind-fcg-fase3 -n fcg port-forward --address 127.0.0.1 service/' + $target[0] + ' ' + $target[1] + ':' + $target[2]
        $process = Start-Process -FilePath $kubectlExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $repo ($target[0] + '-fase3.local.log')) -RedirectStandardError (Join-Path $repo ($target[0] + '-fase3-error.local.log'))
        $processes += @{ id = $process.Id; service = $target[0]; port = $target[1] }
    }
    Write-LocalJson $processFile @($processes)
    Wait-Until { @(Get-NetTCPConnection -LocalPort 18000,19090,13000 -State Listen -ErrorAction SilentlyContinue).Count -eq 3 } 'Local port-forwards' 30
    Write-Host 'Kong http://127.0.0.1:18000 | Grafana http://127.0.0.1:13000/d/fcg-http | Prometheus http://127.0.0.1:19090'
} catch { foreach ($entry in $processes) { Stop-Process -Id $entry.id -ErrorAction SilentlyContinue }; if (Test-Path -LiteralPath $processFile) { Remove-Item -LiteralPath $processFile }; throw }
