param([string]$Profile = 'fiap-fase3')
. (Join-Path $PSScriptRoot 'common.ps1')
$settings = Get-Content -Raw (Join-Path $repo 'fase3-settings.local.json') | ConvertFrom-Json
$cloud = Get-Content -Raw (Join-Path $repo 'fase3-cloud.local.json') | ConvertFrom-Json
$checks = New-Object 'System.Collections.Generic.List[object]'
$started = [DateTimeOffset]::UtcNow
$url = 'http://127.0.0.1:18000'
function Assert-True([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
    $checks.Add(@{ check = $Description; atUtc = [DateTimeOffset]::UtcNow.ToString('O') })
}
function Api([string]$Method, [string]$Path, [object]$Body = $null, [string]$Token = '') {
    $arguments = @{ Uri = $url + $Path; Method = $Method; TimeoutSec = 45 }
    if ($Token) { $arguments.Headers = @{ Authorization = 'Bearer ' + $Token } }
    if ($null -ne $Body) { $arguments.ContentType = 'application/json'; $arguments.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
    return Invoke-RestMethod @arguments
}
function Sql([string]$Database, [string]$Statement) {
    if ($Database -notin @('FcgUsersDb','FcgCatalogDb')) { throw 'Unexpected database.' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Statement))
    $cmd = 'printf %s ' + $encoded + ' | base64 -d | SQLCMDPASSWORD=$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -y 4000 -w 4000 -b -d ' + $Database
    $raw = & kubectl @kube exec deployment/sqlserver -- bash -c $cmd
    Check-Exit 'SQL smoke inspection'
    return ($raw -join '').Trim()
}
function Outbox([string]$UserId) {
    $id = ([guid]$UserId).ToString()
    $raw = Sql FcgUsersDb "SET NOCOUNT ON; SELECT Id,ProcessedAtUtc,AttemptCount FROM dbo.IntegrationOutboxMessages WHERE COALESCE(JSON_VALUE(Payload,'$.userId'),JSON_VALUE(Payload,'$.UserId'))='$id' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER;"
    if ($raw) { return $raw | ConvertFrom-Json }
}
function Item([string]$Key) { return (Aws dynamodb get-item @{ TableName = $cloud.Outputs.EventsTableName; Key = @{ EventKey = @{ S = $Key } }; ConsistentRead = $true }).Item }
function Wait-Item([string]$Key) {
    Wait-Until { (Item $Key).ProcessingStatus.S -eq 'Completed' } 'Lambda DynamoDB completion' 180
    return Item $Key
}
function Redis([string[]]$Command) {
    $raw = & kubectl @kube exec deployment/redis -- redis-cli --raw @Command
    Check-Exit 'Redis inspection'
    return ($raw -join "`n").Trim()
}
function Cache-Hits {
    $info = Redis @('INFO','stats')
    if ($info -notmatch '(?m)^keyspace_hits:(\d+)') { throw 'Redis hit counter missing.' }
    return [long]$matches[1]
}
function Query([string]$Expression) {
    $result = Invoke-RestMethod ('http://127.0.0.1:19090/api/v1/query?query=' + [Uri]::EscapeDataString($Expression))
    if ($result.status -ne 'success') { throw 'Prometheus query failed.' }
    return $result.data.result
}
function Json-Utf8([string]$Uri) {
    $client = New-Object Net.WebClient
    $client.Encoding = [Text.Encoding]::UTF8
    try { return ($client.DownloadString($Uri) | ConvertFrom-Json) } finally { $client.Dispose() }
}
$deployments = (& kubectl @kube get deployments -o json | ConvertFrom-Json).items
Check-Exit 'Deployment inventory'
Assert-True ($deployments.Count -eq 9 -and @($deployments | Where-Object { $_.status.availableReplicas -ne 1 }).Count -eq 0) 'Nine final deployments available; historical NotificationsAPI absent'
$mappings = (Aws lambda list-event-source-mappings @{ FunctionName = $cloud.Outputs.FunctionName }).EventSourceMappings
Assert-True (@($mappings).Count -eq 2 -and @($mappings | Where-Object State -ne 'Enabled').Count -eq 0) 'Both real SQS triggers enabled'
Wait-Until { @(Query 'up{job=~"users-api|catalog-api"}').Count -eq 2 -and @((Query 'up{job=~"users-api|catalog-api"}') | Where-Object { $_.value[1] -ne '1' }).Count -eq 0 } 'Both Prometheus targets up'
Assert-True $true 'Prometheus scrapes UsersAPI and CatalogAPI in the final stack'
$run = [guid]::NewGuid().ToString('N')
$admin = Api POST '/api/auth/login' @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
$customer = Api POST '/api/auth/register' @{ name = 'Integrated synthetic'; email = "integrated-$run@example.invalid"; password = 'Synthetic1!Pass' }
$login = Api POST '/api/auth/login' @{ email = "integrated-$run@example.invalid"; password = 'Synthetic1!Pass' }
$userProfile = Api GET '/api/me/profile' $null $login.accessToken
Assert-True ($customer.user.id -eq $userProfile.id -and $login.user.role -eq 'User') 'Registration, login and profile succeed through Kong with real User JWT'
Wait-Until { (Outbox $customer.user.id).ProcessedAtUtc } 'Users outbox sent to SQS'
$welcomeKey = 'user-created:' + (Outbox $customer.user.id).Id.ToLowerInvariant()
$welcome = Wait-Item $welcomeKey
Assert-True ($welcome.NotificationKind.S -eq 'Welcome' -and $welcome.NotificationState.S -eq 'Simulated') 'Registration -> SQL outbox -> SQS -> Lambda -> DynamoDB welcome'
$approvedBody = @{ title = "Integrated approved $run"; description = 'Synthetic end-to-end test'; developer = 'FIAP'; price = 59.90 }
$approvedGame = Api POST '/api/games' $approvedBody $admin.accessToken
$rejectedGame = Api POST '/api/games' @{ title = "Integrated rejected $run"; developer = 'FIAP'; price = 150.00 } $admin.accessToken
$approvedOrder = Api POST ('/api/me/library/games/' + $approvedGame.id) @{} $login.accessToken
Wait-Until { @((Api GET '/api/me/library/games' $null $login.accessToken) | Where-Object id -eq $approvedGame.id).Count -eq 1 } 'Approved purchase in catalog library'
$approvedKey = 'payment-processed:' + $approvedOrder.orderId
$approved = Wait-Item $approvedKey
Assert-True ($approved.NotificationKind.S -eq 'PurchaseConfirmation' -and $approved.NotificationState.S -eq 'Simulated') 'Approved purchase -> RabbitMQ library update and SQS Lambda confirmation'
$rejectedOrder = Api POST ('/api/me/library/games/' + $rejectedGame.id) @{} $login.accessToken
$rejectedKey = 'payment-processed:' + $rejectedOrder.orderId
$rejected = Wait-Item $rejectedKey
Assert-True ($rejected.NotificationState.S -eq 'Skipped' -and @((Api GET '/api/me/library/games' $null $login.accessToken) | Where-Object id -eq $rejectedGame.id).Count -eq 0) 'Rejected payment stored in DynamoDB without library game or confirmation'
$key = 'fcg:catalog:v1:game:' + $approvedGame.id
$null = Api GET ('/api/games/' + $approvedGame.id)
Assert-True ((Redis @('EXISTS',$key)) -eq '1') 'Public catalog read populates real Redis'
$hits = Cache-Hits
$null = Api GET ('/api/games/' + $approvedGame.id)
Assert-True ((Cache-Hits) -gt $hits) 'Repeated gateway read produces a real Redis hit'
$ttl = [int](Redis @('PTTL',$key))
Assert-True ($ttl -gt 0 -and $ttl -le 60000) 'Cache uses the configured absolute 60-second TTL'
$approvedBody.title = "Integrated updated $run"
$null = Api PUT ('/api/games/' + $approvedGame.id) $approvedBody $admin.accessToken
Assert-True ((Redis @('EXISTS',$key)) -eq '0') 'Admin update invalidates cached detail'
$updated = Api GET ('/api/games/' + $approvedGame.id)
Assert-True ($updated.title -eq $approvedBody.title) 'Public read reflects persisted Admin update'
$null = Api DELETE ('/api/games/' + $rejectedGame.id) $null $admin.accessToken
Assert-True (@((Api GET '/api/games') | Where-Object id -eq $rejectedGame.id).Count -eq 0) 'Admin delete removes the rejected game from public catalog'
# Exercise real server errors via Kong; rename only final-stack tables and always restore.
$usersRenamed = $false; $gamesRenamed = $false
try {
    $null = Sql FcgUsersDb "EXEC sp_rename 'dbo.Users', 'Users_integrated_fault';"; $usersRenamed = $true
    $null = Sql FcgCatalogDb "EXEC sp_rename 'dbo.Games', 'Games_integrated_fault';"; $gamesRenamed = $true
    foreach ($target in @(@('POST','/api/auth/login'),@('GET',('/api/games/' + [guid]::NewGuid())))) {
        $status = 0
        try { $null = Api $target[0] $target[1] $(if ($target[0] -eq 'POST') { @{ email = 'admin@fcg.local'; password = $settings.AdminPassword } } else { $null }) }
        catch { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { throw } }
        Assert-True ($status -eq 500) ('Real SQL failure produces 500 via Kong: ' + $target[1])
    }
} finally {
    try { if ($usersRenamed) { $null = Sql FcgUsersDb "EXEC sp_rename 'dbo.Users_integrated_fault', 'Users';" } }
    finally { if ($gamesRenamed) { $null = Sql FcgCatalogDb "EXEC sp_rename 'dbo.Games_integrated_fault', 'Games';" } }
}
$null = Api POST '/api/auth/login' @{ email = 'admin@fcg.local'; password = $settings.AdminPassword }
$null = Api GET ('/api/games/' + $approvedGame.id)
Assert-True $true 'Both APIs recover after restoring SQL tables'
Wait-Until { @((Query 'sum by(job)(fcg_http_requests_total{status_code="500"})') | Where-Object { [double]$_.value[1] -ge 1 }).Count -eq 2 } '500 counts scraped'
$dashboard = Json-Utf8 'http://127.0.0.1:13000/api/dashboards/uid/fcg-http'
Assert-True ($dashboard.meta.provisioned -and $dashboard.dashboard.panels.Count -eq 6) 'Grafana dashboard provisioned from Git with six panels'
foreach ($panel in $dashboard.dashboard.panels) {
    $expression = $panel.targets[0].expr.Replace('$service','.*')
    Wait-Until {
        $script:panelData = Invoke-RestMethod ('http://127.0.0.1:13000/api/datasources/proxy/uid/fcg-prometheus/api/v1/query?query=' + [Uri]::EscapeDataString($expression))
        @($panelData.data.result | Where-Object { $_.value[1] -notin @('NaN','+Inf','-Inf') }).Count -gt 0
    } 'Finite dashboard data' 30
    Assert-True ($panelData.status -eq 'success') ('Grafana datasource executes panel: ' + $panel.title)
}
Wait-Until { (Redis @('EXISTS',$key)) -eq '0' } 'Real Redis TTL expiration' 75
$null = Api GET ('/api/games/' + $approvedGame.id)
Assert-True ((Redis @('EXISTS',$key)) -eq '1') 'Expired cache entry repopulates from the catalog source'
foreach ($queue in @($cloud.Outputs.UserCreatedQueueUrl,$cloud.Outputs.PaymentProcessedQueueUrl)) {
    Wait-Until { $a = (Aws sqs get-queue-attributes @{ QueueUrl = $queue; AttributeNames = @('ApproximateNumberOfMessages','ApproximateNumberOfMessagesNotVisible') }).Attributes; [int]$a.ApproximateNumberOfMessages -eq 0 -and [int]$a.ApproximateNumberOfMessagesNotVisible -eq 0 } 'SQS queue drained' 180
}
Assert-True $true 'Both SQS queues drained before pausing triggers'
$queueRows = & kubectl @kube exec deployment/rabbitmq -- rabbitmqctl list_queues name messages --quiet
Check-Exit 'RabbitMQ queues'
Assert-True (@($queueRows | Where-Object { $_ -match '_error\s+[1-9]\d*' }).Count -eq 0) 'No message remains in a RabbitMQ error queue'
$evidence = @{ startedUtc = $started.ToString('O'); finishedUtc = [DateTimeOffset]::UtcNow.ToString('O'); checks = $checks.ToArray(); eventKeys = @($welcomeKey,$approvedKey,$rejectedKey); cloudLogs = @(); userId = $customer.user.id; approvedOrderId = $approvedOrder.orderId; rejectedOrderId = $rejectedOrder.orderId; gateway = $url }
Write-LocalJson (Join-Path $repo 'integrated-smoke.local.json') $evidence
Write-Host ("Integrated smoke passed: " + $checks.Count + ' checks. Synthetic data is retained as evidence.')
