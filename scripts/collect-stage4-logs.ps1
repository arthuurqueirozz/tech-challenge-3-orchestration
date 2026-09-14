param([string]$Profile = 'fiap-fase3', [int]$TimeoutSeconds = 600)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$evidencePath = Join-Path $repo 'stage4-smoke.local.json'
$evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
$awsExe = if ($awsCommand) { $awsCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe' }
$startTime = ([DateTimeOffset]::Parse($evidence.startedUtc)).AddMinutes(-10).ToUnixTimeMilliseconds()
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $logs = New-Object 'System.Collections.Generic.List[object]'
    $nextToken = ''
    for ($page = 0; $page -lt 10; $page++) {
        $arguments = @('logs', 'filter-log-events', '--log-group-name', '/aws/lambda/fcg-fase3-notifications', '--start-time', $startTime, '--limit', 1000, '--no-paginate', '--profile', $Profile, '--region', 'us-east-1', '--output', 'json', '--no-cli-pager')
        if ($nextToken) { $arguments += @('--next-token', $nextToken) }
        $raw = & $awsExe @arguments
        if ($LASTEXITCODE -ne 0) { throw 'CloudWatch log collection failed.' }
        $result = ($raw -join "`n") | ConvertFrom-Json
        foreach ($entry in $result.events) {
            if (@($evidence.eventKeys | Where-Object { $entry.message.Contains($_) }).Count -gt 0) {
                $logs.Add(@{ timestamp = $entry.timestamp; message = $entry.message })
            }
        }
        if (!$result.nextToken -or $result.nextToken -eq $nextToken) { break }
        $nextToken = $result.nextToken
    }
    $missing = @($evidence.eventKeys | Where-Object {
        $key = $_
        @($logs | Where-Object { $_.message.Contains($key) }).Count -eq 0
    })
    if ($missing.Count -eq 0) { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw "CloudWatch still missing $($missing.Count) correlated events; retry this read-only script later." }
    Write-Host "Waiting for CloudWatch ingestion: $($missing.Count) events remaining. Lambda mappings may stay paused."
    Start-Sleep -Seconds 15
} while ($true)
$evidence.cloudLogs = @($logs.ToArray())
$description = 'CloudWatch logs correlated for all five integrated events'
$evidence.checks = @($evidence.checks | Where-Object check -ne $description) + @(@{ check = $description; atUtc = [DateTimeOffset]::UtcNow.ToString('O') })
[IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
Write-Host "PASS: $description ($($logs.Count) log entries)"
