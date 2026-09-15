. (Join-Path $PSScriptRoot 'common.ps1')
$file = Join-Path $repo 'fase3-access.local.json'
if (!(Test-Path -LiteralPath $file)) { Write-Host 'No final-stack access session recorded.'; return }
foreach ($entry in (Get-Content -Raw -LiteralPath $file | ConvertFrom-Json)) {
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$entry.id)
    if (!$process) { continue }
    if ($process.Name -ne 'kubectl.exe' -or !$process.CommandLine.Contains($config) -or !$process.CommandLine.Contains('port-forward')) { throw 'PID identity changed; inspect the stale local record before removing it.' }
    Stop-Process -Id $entry.id
}
Remove-Item -LiteralPath $file
Write-Host 'Final-stack port-forwards stopped.'
