$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$settings = Get-Content -Raw -LiteralPath (Join-Path $repo 'stage6-settings.local.json') | ConvertFrom-Json
$kube = @('--kubeconfig', (Join-Path $repo 'stage6.kubeconfig.local.yaml'), '--context', 'kind-fcg-fase3-stage6', '-n', 'fcg-stage6')
$started = [DateTimeOffset]::UtcNow
$checks = New-Object 'System.Collections.Generic.List[string]'
$expected = @{}
$queries = New-Object 'System.Collections.Generic.List[object]'
function Assert-True([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
    $checks.Add($Description)
}
function Wait-Until([scriptblock]$Condition, [string]$Description, [int]$Seconds = 120) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Seconds 2 } while ([DateTime]::UtcNow -lt $until)
    throw "Timeout: $Description"
}
function Query([string]$Expression) {
    $response = Invoke-RestMethod ('http://127.0.0.1:19090/api/v1/query?query=' + [Uri]::EscapeDataString($Expression))
    if ($response.status -ne 'success') { throw 'Prometheus query failed.' }
    return @($response.data.result)
}
function Get-Utf8Json([string]$Url) {
    $client = New-Object Net.WebClient
    $client.Encoding = [Text.Encoding]::UTF8
    try { return $client.DownloadString($Url) | ConvertFrom-Json }
    finally { $client.Dispose() }
}
function Count-Snapshot {
    $snapshot = @{}
    foreach ($row in @(Query 'sum by (job,status_code) (fcg_http_requests_total)')) { if ($row.metric) { $snapshot[$row.metric.job + ':' + $row.metric.status_code] = [double]$row.value[1] } }
    return $snapshot
}
function Request([string]$Service, [string]$Method, [string]$Path, [int]$Status, [hashtable]$Body = @{}) {
    $port = if ($Service -eq 'users-api') { 18080 } else { 18081 }
    $args = @{ Uri = "http://127.0.0.1:$port$Path"; Method = $Method; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($Method -eq 'Post') { $args.ContentType = 'application/json'; $args.Body = $Body | ConvertTo-Json -Compress }
    try { $actual = [int](Invoke-WebRequest @args).StatusCode }
    catch { if ($_.Exception.Response) { $actual = [int]$_.Exception.Response.StatusCode } else { throw } }
    if ($actual -ne $Status) { throw "Unexpected HTTP status for $Service $Method ($actual instead of $Status)." }
    $key = $Service + ':' + $actual
    $expected[$key] = [int]$expected[$key] + 1
}
function Sql([string]$Database, [string]$Statement) {
    $command = 'SQLCMDPASSWORD=$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d ' + $Database
    $null = $Statement | & kubectl @kube exec -i deployment/sqlserver -- bash -c $command
    if ($LASTEXITCODE -ne 0) { throw 'Controlled SQL operation failed.' }
}
foreach ($port in @(18080,18081)) { Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/health").StatusCode -eq 200 } catch { $false } } 'API ready' }
Wait-Until { try { @(Query 'up{job=~"users-api|catalog-api"}').Count -eq 2 -and @((Query 'up{job=~"users-api|catalog-api"}') | Where-Object { $_.value[1] -ne '1' }).Count -eq 0 } catch { $false } } 'Prometheus targets up'
Assert-True ($true) 'Prometheus scrapes both real APIs in Kubernetes'
$dashboard = Get-Utf8Json 'http://127.0.0.1:13000/api/dashboards/uid/fcg-http'
Assert-True ($dashboard.meta.provisioned -and $dashboard.dashboard.panels.Count -eq 6) 'Grafana dashboard provisioned from Git with six panels'
$datasource = Invoke-RestMethod 'http://127.0.0.1:13000/api/datasources/uid/fcg-prometheus'
Assert-True ($datasource.url -eq 'http://prometheus:9090') 'Provisioned Grafana datasource points to Prometheus'
$before = Count-Snapshot
$ids = @()
for ($round = 0; $round -lt 12; $round++) {
    $id = [guid]::NewGuid().ToString(); $ids += $id
    Request users-api Post '/api/auth/login' 200 @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
    Request users-api Post '/api/auth/login' 400 @{ email = 'invalid'; password = '' }
    Request users-api Get '/api/me/profile' 401
    Request users-api Get ('/api/unknown/' + $id) 404
    Request catalog-api Get '/api/games' 200
    Request catalog-api Get ('/api/games/' + $id) 404
    Request catalog-api Post '/api/games' 401 @{ title = 'Unauthorized test'; price = 10 }
    Start-Sleep -Milliseconds 500
}
Assert-True ($true) 'Controlled traffic returned expected 200/400/401/404 statuses'
# Isolated databases only: preserve rows and temporarily rename the queried table.
# Invalid-object errors fail immediately; restore both original names in finally.
$usersRenamed = $false; $catalogRenamed = $false
try {
    Sql FcgUsersDb "EXEC sp_rename 'dbo.Users', 'Users_stage6_fault';"; $usersRenamed = $true
    Sql FcgCatalogDb "EXEC sp_rename 'dbo.Games', 'Games_stage6_fault';"; $catalogRenamed = $true
    for ($round = 0; $round -lt 4; $round++) {
        Request users-api Post '/api/auth/login' 500 @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
        Request catalog-api Get ('/api/games/' + [guid]::NewGuid().ToString()) 500
        if ($round -eq 0) { Start-Sleep -Seconds 7 } else { Start-Sleep -Seconds 1 }
    }
}
finally {
    try { if ($usersRenamed) { Sql FcgUsersDb "EXEC sp_rename 'dbo.Users_stage6_fault', 'Users';" } }
    finally { if ($catalogRenamed) { Sql FcgCatalogDb "EXEC sp_rename 'dbo.Games_stage6_fault', 'Games';" } }
}
Assert-True ($true) 'Real SQL dependency faults produced 500 in both APIs; original tables restored'
Request users-api Post '/api/auth/login' 200 @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
Request catalog-api Get ('/api/games/' + [guid]::NewGuid().ToString()) 404
Assert-True ($true) 'Both APIs recovered after fault restoration'
Wait-Until {
    $current = Count-Snapshot
    @($expected.Keys | Where-Object { ([double]$current[$_] - [double]$before[$_]) -ne $expected[$_] }).Count -eq 0
} 'Exact request counts scraped'
$after = Count-Snapshot
foreach ($key in $expected.Keys) { Assert-True (($after[$key] - [double]$before[$key]) -eq $expected[$key]) ("Exact request delta ${key}: " + $expected[$key]) }
$series = Query 'fcg_http_requests_total'
$serialized = $series | ConvertTo-Json -Depth 10
Assert-True (@($ids | Where-Object { $serialized.Contains($_) }).Count -eq 0) 'Route labels contain no individual GUIDs'
Assert-True (@($series | Where-Object { $_.metric.route -notmatch '^/api|^unmatched$' }).Count -eq 0) 'Business metrics exclude health and metrics endpoints'
foreach ($job in @('users-api','catalog-api')) {
    $latency = @(Query ('histogram_quantile(0.95,sum by(le)(rate(fcg_http_request_duration_seconds_bucket{job="' + $job + '"}[2m])))'))
    Assert-True ($latency.Count -gt 0 -and [double]$latency[0].value[1] -gt 0) ("Positive measured p95 latency for $job")
}
foreach ($panel in $dashboard.dashboard.panels) {
    $expr = $panel.targets[0].expr.Replace('$service','.*')
    $proxy = Invoke-RestMethod ('http://127.0.0.1:13000/api/datasources/proxy/uid/fcg-prometheus/api/v1/query?query=' + [Uri]::EscapeDataString($expr))
    $values = @($proxy.data.result)
    Assert-True ($proxy.status -eq 'success') ("Grafana datasource executes query: " + $panel.title)
    Assert-True ($values.Count -gt 0 -and @($values | Where-Object { $_.value[1] -in @('NaN','+Inf','-Inf') }).Count -eq 0) ("Dashboard panel has finite data: " + $panel.title)
    if ($panel.id -in @(5,6)) { Assert-True (@($values | Where-Object { [double]$_.value[1] -gt 0 }).Count -eq 2) ("Error panel responds for both services: " + $panel.title) }
    $queries.Add(@{ panel = $panel.title; expression = $expr; results = @($values) })
}
$evidence = @{ startedUtc = $started.ToString('O'); finishedUtc = [DateTimeOffset]::UtcNow.ToString('O'); checks = @($checks.ToArray()); expectedDeltas = $expected; before = $before; after = $after; panels = @($queries.ToArray()); dashboardUid = 'fcg-http' }
[IO.File]::WriteAllText((Join-Path $repo 'stage6-smoke.local.json'), ($evidence | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
Write-Host 'Stage 6 smoke passed. Dashboard is available at http://127.0.0.1:13000/d/fcg-http while port-forwards are running.'
