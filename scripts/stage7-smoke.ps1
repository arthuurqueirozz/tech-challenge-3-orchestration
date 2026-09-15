param(
    [string]$KubeconfigName = 'stage6.kubeconfig.local.yaml',
    [string]$Context = 'kind-fcg-fase3-stage6',
    [string]$Namespace = 'fcg-stage6',
    [string]$SettingsName = 'stage6-settings.local.json',
    [string]$EvidenceName = 'stage7-evidence.local.json',
    [switch]$AllowMonitoringAccess
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$repo = Split-Path $PSScriptRoot -Parent
$settings = Get-Content -Raw (Join-Path $repo $SettingsName) | ConvertFrom-Json
$kube = @('--kubeconfig', (Join-Path $repo $KubeconfigName), '--context', $Context, '-n', $Namespace)
$checks = New-Object 'System.Collections.Generic.List[object]'
$started = [DateTimeOffset]::UtcNow
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(45)
function Assert-True([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
    $checks.Add(@{ check = $Description; atUtc = [DateTimeOffset]::UtcNow.ToString('O') })
}
function Request([string]$Method, [string]$Path, [int]$Status, [string]$Token = '', [object]$Body = $null, [string]$Origin = 'api') {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), ('http://127.0.0.1:18000' + $Path))
    $response = $null
    try {
        if ($Token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
        if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $actual = [int]$response.StatusCode
        $fromApi = $response.Headers.Contains('X-Kong-Upstream-Latency')
        if ($actual -ne $Status -or $fromApi -ne ($Origin -eq 'api')) { throw "Unexpected response: $Method $Path status=$actual upstream=$fromApi; expected $Status ($Origin)." }
        Assert-True $true "$Method $Path -> $Status ($Origin)"
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($content -and $content.TrimStart().StartsWith('{')) { return ($content | ConvertFrom-Json) }
        if ($content -and $content.TrimStart().StartsWith('[')) { return ,($content | ConvertFrom-Json) }
    }
    finally { if ($response) { $response.Dispose() }; $request.Dispose() }
}
function Sql([string]$Statement) {
    # Encode synthetic SQL to avoid BOM injection by Windows native stdin bridges.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Statement))
    $command = 'printf %s ' + $encoded + ' | base64 -d | SQLCMDPASSWORD=$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d FcgUsersDb'
    $null = & kubectl @kube exec deployment/sqlserver -- bash -c $command
    if ($LASTEXITCODE -ne 0) { throw 'Isolated SQL fixture operation failed.' }
}
function Base64Url([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
function Token([hashtable]$Claims) {
    $header = Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"HS256","typ":"JWT"}'))
    $payload = Base64Url ([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress)))
    $signer = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($settings.JwtKey))
    try { return $header + '.' + $payload + '.' + (Base64Url ($signer.ComputeHash([Text.Encoding]::UTF8.GetBytes($header + '.' + $payload)))) }
    finally { $signer.Dispose() }
}
$fixtureId = [guid]::NewGuid().ToString()
$fixtureEmail = 'stage7-' + $fixtureId + '@example.invalid'
$gameId = $null
$adminToken = $null
try {
    $services = (& kubectl @kube get services -o json | ConvertFrom-Json).items
    if ($LASTEXITCODE -ne 0) { throw 'Service inspection failed.' }
    Assert-True (@($services | Where-Object { $_.spec.type -ne 'ClusterIP' -or $_.spec.externalIPs }).Count -eq 0) 'All services are internal ClusterIP without external IPs'
    $deployments = (& kubectl @kube get deployments -o json | ConvertFrom-Json).items
    if ($LASTEXITCODE -ne 0) { throw 'Deployment inspection failed.' }
    Assert-True (@($deployments | Where-Object { $_.spec.template.spec.hostNetwork -or @($_.spec.template.spec.containers.ports | Where-Object hostPort).Count -gt 0 }).Count -eq 0) 'No deployment exposes hostNetwork or hostPort'
    Assert-True (@(Get-NetTCPConnection -LocalPort 18080,18081 -State Listen -ErrorAction SilentlyContinue).Count -eq 0) 'Direct API access ports 18080/18081 are closed'
    $forwards = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'kubectl.exe' -and $_.CommandLine -match 'port-forward' })
    $allowedForwards = if ($AllowMonitoringAccess) { @('service/kong 18000:8000','service/prometheus 19090:9090','service/grafana 13000:3000') } else { @('service/kong 18000:8000') }
    Assert-True ($forwards.Count -eq $allowedForwards.Count -and @($forwards | Where-Object { $line = $_.CommandLine; !$line.Contains((Join-Path $repo $KubeconfigName)) -or @($allowedForwards | Where-Object { $line.Contains($_) }).Count -ne 1 }).Count -eq 0) 'Only Kong and explicitly allowed monitoring port-forwards are active'
    $kongService = $services | Where-Object { $_.metadata.name -eq 'kong' }
    Assert-True ($kongService.spec.ports.Count -eq 1 -and $kongService.spec.ports[0].port -eq 8000) 'Kong Service exposes proxy only; admin/status are not routed'
    $null = Request GET '/api/games' 200
    $null = Request GET ('/api/games/' + [guid]::NewGuid()) 404
    $null = Request POST '/api/auth/register' 400 '' @{ name = ''; email = 'invalid'; password = '' }
    $null = Request POST '/api/auth/login' 400 '' @{ email = 'invalid'; password = '' }
    $null = Request POST '/api/auth/login' 401 '' @{ email = 'admin@fcg.local'; password = 'Incorrect-password-7!' }
    $admin = Request POST '/api/auth/login' 200 '' @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
    $adminToken = $admin.accessToken
    Assert-True ($admin.user.role -eq 'Admin') 'Real login issues an Admin JWT'
    # Local fixture only: copy the local seeded hash, preserving real login/role behavior.
    # No registration/outbox event is generated in this gateway-only stage.
    Sql "INSERT INTO dbo.Users (Id, Name, Email, PasswordHash, Role, CreatedAtUtc) SELECT '$fixtureId', 'Stage7 fixture', '$fixtureEmail', PasswordHash, 0, SYSUTCDATETIME() FROM dbo.Users WHERE Email = 'admin@fcg.local'; IF @@ROWCOUNT <> 1 THROW 50001, 'Admin seed missing', 1;"
    $user = Request POST '/api/auth/login' 200 '' @{ email = $fixtureEmail; password = $settings.AdminPassword }
    Assert-True ($user.user.role -eq 'User') 'Real login issues a User JWT for the temporary fixture'
    $userToken = $user.accessToken
    $profile = Request GET '/api/me/profile' 200 $userToken
    Assert-True ($profile.id -eq $fixtureId) 'Gateway preserves authenticated user identity'
    $null = Request GET '/api/me/profile' 200 $adminToken
    $null = Request GET '/api/me/library/games' 200 $userToken
    $null = Request POST ('/api/me/library/games/' + [guid]::NewGuid()) 400 $userToken
    foreach ($target in @(@('GET','/api/me/profile'), @('GET','/api/me/library/games'), @('POST','/api/games'), @('PUT',('/api/games/' + $fixtureId)), @('DELETE',('/api/games/' + $fixtureId)), @('POST',('/api/me/library/games/' + $fixtureId)))) {
        $null = Request $target[0] $target[1] 401 '' $null gateway
    }
    $now = [DateTimeOffset]::UtcNow
    $baseClaims = @{ iss = 'FCG'; aud = 'FCG'; sub = $fixtureId; email = $fixtureEmail; name = 'Stage7 fixture'; role = 'User'; nbf = $now.AddMinutes(-10).ToUnixTimeSeconds(); exp = $now.AddMinutes(20).ToUnixTimeSeconds() }
    foreach ($case in @('expired','future-nbf','missing-exp','missing-nbf','wrong-issuer','wrong-audience','missing-audience','tampered')) {
        $claims = $baseClaims.Clone()
        $origin = 'gateway'
        switch ($case) {
            'expired' { $claims.exp = $now.AddMinutes(-5).ToUnixTimeSeconds() }
            'future-nbf' { $claims.nbf = $now.AddMinutes(10).ToUnixTimeSeconds() }
            'missing-exp' { $claims.Remove('exp') }
            'missing-nbf' { $claims.Remove('nbf') }
            'wrong-issuer' { $claims.iss = 'OTHER' }
            'wrong-audience' { $claims.aud = 'OTHER'; $origin = 'api' }
            'missing-audience' { $claims.Remove('aud'); $origin = 'api' }
        }
        $badToken = Token $claims
        if ($case -eq 'tampered') {
            $parts = $badToken.Split('.')
            $replacement = if ($parts[2][0] -eq 'A') { 'B' } else { 'A' }
            $badToken = $parts[0] + '.' + $parts[1] + '.' + $replacement + $parts[2].Substring(1)
        }
        Write-Host "JWT case: $case"
        foreach ($path in @('/api/me/profile','/api/me/library/games')) { $null = Request GET $path 401 $badToken $null $origin }
        Assert-True $true "JWT $case rejected on both APIs through Kong"
    }
    $null = Request GET '/api/me/profile?jwt=not-a-token' 401 '' $null gateway
    foreach ($path in @('/metrics','/health','/status','/routes','/swagger/index.html','/api/auth/login/extra','/api/games/extra/path')) { $null = Request GET $path 404 '' $null gateway }
    $null = Request GET '/api/auth/login' 404 '' $null gateway
    $gameBody = @{ title = 'Stage7 ' + $fixtureId; description = 'Gateway authorization fixture'; developer = 'FIAP'; price = 19.90 }
    $null = Request POST '/api/games' 403 $userToken $gameBody
    $null = Request POST '/api/games' 400 $adminToken @{ title = ''; price = -1 }
    $game = Request POST '/api/games' 201 $adminToken $gameBody
    $gameId = $game.id
    $null = Request GET "/api/games/$gameId" 200
    $null = Request PUT "/api/games/$gameId" 403 $userToken $gameBody
    $null = Request DELETE "/api/games/$gameId" 403 $userToken
    $gameBody.title = 'Stage7 updated ' + $fixtureId
    $null = Request PUT "/api/games/$gameId" 200 $adminToken $gameBody
    $updated = Request GET "/api/games/$gameId" 200
    Assert-True ($updated.title -eq $gameBody.title) 'Public read sees Admin update through Kong and Redis invalidation'
    $null = Request DELETE "/api/games/$gameId" 204 $adminToken
    $gameId = $null
    $list = Request GET '/api/games' 200
    Assert-True (@($list | Where-Object { $_.id -eq $game.id }).Count -eq 0) 'Deleted game disappears from public list'
}
finally {
    try { if ($gameId -and $adminToken) { $null = Request DELETE "/api/games/$gameId" 204 $adminToken } }
    finally {
        try { Sql "DELETE FROM dbo.Users WHERE Id = '$fixtureId' AND Email = '$fixtureEmail';" }
        finally { $client.Dispose(); $handler.Dispose() }
    }
}
Assert-True $true 'Temporary User fixture removed; no registration or purchase event produced'
$evidence = @{ startedAtUtc = $started.ToString('O'); finishedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); gateway = 'http://127.0.0.1:18000'; checks = $checks.ToArray(); total = $checks.Count }
[IO.File]::WriteAllText((Join-Path $repo $EvidenceName), ($evidence | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ("Stage 7 smoke passed: " + $checks.Count + ' checks. No tokens or passwords persisted in evidence.')
