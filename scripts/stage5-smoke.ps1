$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$compose = @('compose', '--project-directory', $repo, '--env-file', (Join-Path $repo 'stage5.local.env'), '-f', (Join-Path $repo 'compose.stage5.yaml'))
$settings = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $repo 'stage5.local.env')) {
    if ($line -match '^([^#=]+)=(.*)$') { $settings[$matches[1]] = $matches[2] }
}
$checks = New-Object 'System.Collections.Generic.List[object]'
$readEvidence = New-Object 'System.Collections.Generic.List[object]'
$started = [DateTimeOffset]::UtcNow
$baseUrl = 'http://127.0.0.1:18081'
$listKey = 'fcg:catalog:v1:games:active:title-asc'
function Assert-True([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
    $checks.Add(@{ check = $Description; atUtc = [DateTimeOffset]::UtcNow.ToString('O') })
}
function Wait-Until([scriptblock]$Condition, [string]$Description, [int]$Seconds = 120) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Seconds 1 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout: $Description"
}
function Base64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
# Synthetic local admin JWT signed with this isolated environment's key. Never print or persist it.
$header = Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"HS256","typ":"JWT"}'))
$claims = @{ iss = 'FCG'; aud = 'FCG'; sub = [guid]::NewGuid().ToString(); role = 'Admin'; name = 'Stage5 synthetic'; nbf = $started.AddMinutes(-10).ToUnixTimeSeconds(); exp = $started.AddMinutes(20).ToUnixTimeSeconds() }
$payload = Base64Url ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
$signer = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($settings.FCG_JWT_KEY))
try { $token = $header + '.' + $payload + '.' + (Base64Url ($signer.ComputeHash([Text.Encoding]::UTF8.GetBytes($header + '.' + $payload)))) } finally { $signer.Dispose() }
function Api([string]$Method, [string]$Path, [hashtable]$Body = @{}) {
    $arguments = @{ Uri = $baseUrl + $Path; Method = $Method }
    if ($Method -ne 'Get') { $arguments.Headers = @{ Authorization = 'Bearer ' + $token } }
    if ($Method -in @('Post','Put')) { $arguments.ContentType = 'application/json'; $arguments.Body = $Body | ConvertTo-Json -Compress }
    return Invoke-RestMethod @arguments
}
function Redis([string[]]$Command) {
    $result = & docker @compose exec -T redis redis-cli --raw @Command
    if ($LASTEXITCODE -ne 0) { throw 'Redis inspection failed.' }
    return ($result -join "`n").Trim()
}
function SqlReads {
    $lines = & docker @compose logs --no-color --no-log-prefix catalog-api
    if ($LASTEXITCODE -ne 0) { throw 'SQL command log inspection failed.' }
    return @($lines | Where-Object { $_ -match '^\s*SELECT\s' }).Count
}
function Assert-ReadDelta([int]$Before, [int]$Expected, [string]$Description) {
    $after = SqlReads
    $readEvidence.Add(@{ case = $Description; before = $Before; after = $after; sqlSelects = $after - $Before })
    Assert-True (($after - $Before) -eq $Expected) $Description
}
Wait-Until { try { (Invoke-RestMethod "$baseUrl/health") -eq 'Healthy' } catch { $false } } 'Catalog healthy' 180
Assert-True ((Redis @('PING')) -eq 'PONG') 'Real Redis responds'
$runId = [guid]::NewGuid().ToString('N')
$gameId = $null
$secondId = $null
try {
    # Warm the list before creating a game to prove create invalidation.
    $null = Api Get '/api/games'
    Assert-True ((Redis @('EXISTS', $listKey)) -eq '1') 'Public list stored in Redis'
    $game = Api Post '/api/games' @{ title = "Stage5 $runId"; description = 'Synthetic cache test'; developer = 'FIAP'; price = 59.90 }
    $gameId = $game.id
    $detailKey = 'fcg:catalog:v1:game:' + $gameId
    Assert-True ((Redis @('EXISTS', $listKey)) -eq '0') 'Create invalidates previously cached list'

    $before = SqlReads
    $list = Api Get '/api/games'
    Assert-ReadDelta $before 1 'List miss executes one SQL SELECT'
    Assert-True (@($list | Where-Object id -eq $gameId).Count -eq 1) 'Created game appears in public list'
    $before = SqlReads
    $null = Api Get '/api/games'
    Assert-ReadDelta $before 0 'List hit executes zero SQL SELECTs'
    $before = SqlReads
    $detail = Api Get "/api/games/$gameId"
    Assert-ReadDelta $before 1 'Detail miss executes one SQL SELECT'
    $before = SqlReads
    $cachedDetail = Api Get "/api/games/$gameId"
    Assert-ReadDelta $before 0 'Detail hit executes zero SQL SELECTs'
    Assert-True ($detail.title -eq $cachedDetail.title -and $cachedDetail.price -eq 59.90) 'Cache preserves HTTP response data'
    $ttl = [int](Redis @('PTTL', $detailKey))
    Assert-True ($ttl -gt 0 -and $ttl -le 5000) 'Redis entry has absolute five-second test TTL'
    Wait-Until { (Redis @('EXISTS', $detailKey)) -eq '0' } 'Real TTL expiry' 15
    $before = SqlReads
    $null = Api Get "/api/games/$gameId"
    Assert-ReadDelta $before 1 'Expired detail reloads from SQL'

    $null = Api Get '/api/games'
    $null = Api Put "/api/games/$gameId" @{ title = "Updated $runId"; description = 'Updated'; developer = 'FIAP'; price = 79.90 }
    Assert-True ((Redis @('EXISTS', $listKey, $detailKey)) -eq '0') 'Update removes list and affected detail'
    $updated = Api Get "/api/games/$gameId"
    $updatedList = Api Get '/api/games'
    Assert-True ($updated.price -eq 79.90 -and @($updatedList | Where-Object { $_.id -eq $gameId -and $_.title -eq "Updated $runId" }).Count -eq 1) 'Updated values appear in detail and list'

    & docker @compose stop redis
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stop Redis for outage test.' }
    try {
        Wait-Until { try { (Invoke-RestMethod "$baseUrl/health") -eq 'Degraded' } catch { $false } } 'Cache health degraded with HTTP 200'
        Assert-True ((Invoke-WebRequest -UseBasicParsing "$baseUrl/health").StatusCode -eq 200) 'Redis outage keeps readiness HTTP 200 (Degraded)'
        $before = SqlReads
        $fallback = Api Get "/api/games/$gameId"
        Assert-ReadDelta $before 1 'Redis outage reads detail from SQL'
        Assert-True ($fallback.price -eq 79.90) 'SQL fallback returns current values'
        $second = Api Post '/api/games' @{ title = "During outage $runId"; price = 39.90 }
        $secondId = $second.id
        $outageList = Api Get '/api/games'
        Assert-True (@($outageList | Where-Object id -eq $secondId).Count -eq 1) 'Writes commit and list works while Redis is down'
        & docker @compose up -d --no-deps --force-recreate catalog-api
        if ($LASTEXITCODE -ne 0) { throw 'Catalog restart failed.' }
        Wait-Until { try { (Invoke-RestMethod "$baseUrl/health") -eq 'Degraded' } catch { $false } } 'Catalog starts without Redis'
        Assert-True ((Api Get "/api/games/$gameId").price -eq 79.90) 'Catalog starts and reads SQL with Redis unavailable'
    }
    finally {
        & docker @compose start redis
        if ($LASTEXITCODE -ne 0) { throw 'Restore Redis manually; restart failed.' }
    }
    Wait-Until { try { (Invoke-RestMethod "$baseUrl/health") -eq 'Healthy' } catch { $false } } 'Redis reconnects' 120
    $null = Api Get "/api/games/$gameId"
    $before = SqlReads
    $null = Api Get "/api/games/$gameId"
    Assert-ReadDelta $before 0 'Cache hits resume after Redis recovery'

    $null = Api Get '/api/games'
    $null = Api Delete "/api/games/$gameId"
    Assert-True ((Redis @('EXISTS', $listKey, $detailKey)) -eq '0') 'Delete invalidates list and detail'
    $notFound = $false
    try { $null = Api Get "/api/games/$gameId" } catch { if ([int]$_.Exception.Response.StatusCode -eq 404) { $notFound = $true } else { throw } }
    Assert-True ($notFound -and @((Api Get '/api/games') | Where-Object id -eq $gameId).Count -eq 0) 'Deleted game returns 404 and disappears from list'
    $gameId = $null

    $evidence = @{ startedUtc = $started.ToString('O'); finishedUtc = [DateTimeOffset]::UtcNow.ToString('O'); checks = @($checks.ToArray()); sqlReads = @($readEvidence.ToArray()); gameId = $game.id; redisImage = 'redis:7.4-alpine'; ttlSeconds = 5 }
    [IO.File]::WriteAllText((Join-Path $repo 'stage5-smoke.local.json'), ($evidence | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Stage 5 smoke passed. Evidence saved without secrets. Stop Compose to end the session.'
}
finally {
    # Only delete this run's synthetic games, preserving unrelated SQL data.
    foreach ($id in @($gameId, $secondId)) {
        if ($id) { try { $null = Api Delete "/api/games/$id" } catch { Write-Warning 'Synthetic game cleanup failed; inspect this run manually.' } }
    }
}
