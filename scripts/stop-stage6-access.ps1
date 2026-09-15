$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$file = Join-Path $repo 'stage6-access.local.json'
if (!(Test-Path -LiteralPath $file)) { Write-Host 'No recorded access session.'; return }
foreach ($entry in (Get-Content -Raw -LiteralPath $file | ConvertFrom-Json)) {
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$entry.id)
    if (!$process) { continue }
    if ($process.Name -ne 'kubectl.exe' -or !$process.CommandLine.Contains((Join-Path $repo 'stage6.kubeconfig.local.yaml')) -or !$process.CommandLine.Contains('port-forward')) { throw 'Process identity changed; refusing to stop it.' }
    Stop-Process -Id $entry.id
}
Remove-Item -LiteralPath $file
Write-Host 'Stage 6 port-forwards stopped.'
