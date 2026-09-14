param([string]$Profile = 'fiap-fase3')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$settings = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $repo 'stage4.local.env')) {
    if ($line -match '^([^#=]+)=(.*)$') { $settings[$matches[1]] = $matches[2] }
}
$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
$awsExe = if ($awsCommand) { $awsCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe' }
$utf8 = New-Object Text.UTF8Encoding($false)
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('fcg-stage4-smoke-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$started = [DateTimeOffset]::UtcNow
$checks = New-Object 'System.Collections.Generic.List[object]'
$usersUrl = 'http://127.0.0.1:18080'
$catalogUrl = 'http://127.0.0.1:18081'
$rabbitHeaders = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings.FCG_RABBIT_USER + ':' + $settings.FCG_RABBIT_PASSWORD)) }

function Assert-True([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw "FAIL: $Description" }
    Write-Host "PASS: $Description"
    $checks.Add(@{ check = $Description; atUtc = [DateTimeOffset]::UtcNow.ToString('O') })
}
function Wait-Until([scriptblock]$Condition, [string]$Description, [int]$Seconds = 120) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    throw "Timeout: $Description"
}
function Post-Json([string]$Url, [hashtable]$Body, [string]$Token = '') {
    $headers = @{}
    if ($Token) { $headers.Authorization = 'Bearer ' + $Token }
    return Invoke-RestMethod -Uri $Url -Method Post -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
}
function Invoke-AwsJson([string]$Service, [string]$Operation, [hashtable]$InputData) {
    $file = Join-Path $scratch 'request.json'
    [IO.File]::WriteAllText($file, ($InputData | ConvertTo-Json -Depth 20 -Compress), $utf8)
    $raw = & $awsExe $Service $Operation --cli-input-json ('file://' + $file) --profile $Profile --region us-east-1 --output json --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw "AWS $Service $Operation failed." }
    if ($raw) { return ($raw -join "`n") | ConvertFrom-Json }
}
function Read-Item([string]$Key) {
    return (Invoke-AwsJson dynamodb get-item @{ TableName = 'fcg-fase3-notification-events'; Key = @{ EventKey = @{ S = $Key } }; ConsistentRead = $true }).Item
}
function Wait-Item([string]$Key) {
    Wait-Until { (Read-Item $Key).ProcessingStatus.S -eq 'Completed' } "DynamoDB $Key"
    return Read-Item $Key
}
function Read-Outbox([string]$UserId) {
    $safeId = ([guid]$UserId).ToString()
    $query = "SET NOCOUNT ON; SELECT Id,ProcessedAtUtc,AttemptCount FROM dbo.IntegrationOutboxMessages WHERE COALESCE(JSON_VALUE(Payload,'$.userId'),JSON_VALUE(Payload,'$.UserId'))='$safeId' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER;"
    $sqlCommand = 'SQLCMDPASSWORD=$MSSQL_SA_PASSWORD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -y 4000 -w 4000 -b -d FcgUsersDb'
    # SQL text has only a validated GUID. The password is read inside the container, never printed.
    $raw = $query | docker compose --project-directory $repo --env-file (Join-Path $repo 'stage4.local.env') -f (Join-Path $repo 'compose.stage4.yaml') exec -T sqlserver bash -c $sqlCommand
    if ($LASTEXITCODE -ne 0) { throw 'Reading test outbox failed.' }
    $text = ($raw -join '').Trim()
    if ($text) { return $text | ConvertFrom-Json }
}
function Get-Library([string]$Token) {
    return @(Invoke-RestMethod -Uri "$catalogUrl/api/me/library/games" -Headers @{ Authorization = 'Bearer ' + $Token })
}
function Wait-Library([string]$Token, [string]$GameId) {
    Wait-Until { @((Get-Library $Token) | Where-Object id -eq $GameId).Count -eq 1 } 'Approved game in library'
}
function Wait-PaymentConsumer {
    Wait-Until {
        try { (Invoke-RestMethod -Uri 'http://127.0.0.1:15672/api/queues/%2F/payments-order-placed' -Headers $rabbitHeaders).consumers -gt 0 }
        catch { $false }
    } 'Payments RabbitMQ consumer'
}
function Recreate-Service([string]$Service, [string]$Override = '') {
    $composeArgs = @('compose', '--project-directory', $repo, '--env-file', (Join-Path $repo 'stage4.local.env'), '-f', (Join-Path $repo 'compose.stage4.yaml'))
    if ($Override) { $composeArgs += @('-f', $Override) }
    & docker @composeArgs up -d --no-deps --force-recreate $Service
    if ($LASTEXITCODE -ne 0) { throw "Recreating $Service failed." }
}
function Write-FailureOverride([string]$Service, [string]$QueueUrl) {
    if ($Service -notin @('users-api', 'payments-api') -or $QueueUrl -notmatch '^https://sqs\.us-east-1\.amazonaws\.com/\d{12}/fcg-fase3-[a-z-]+$') { throw 'Unexpected failure test target.' }
    $file = Join-Path $scratch "$Service.local.yaml"
    [IO.File]::WriteAllText($file, "services:`n  ${Service}:`n    environment:`n      Sqs__QueueUrl: $QueueUrl`n", $utf8)
    return $file
}

$mapping = Invoke-AwsJson lambda list-event-source-mappings @{ FunctionName = 'fcg-fase3-notifications' }
Assert-True (@($mapping.EventSourceMappings).Count -eq 2 -and @($mapping.EventSourceMappings | Where-Object State -ne 'Enabled').Count -eq 0) 'Both Lambda SQS mappings enabled'
foreach ($baseUrl in @($usersUrl, $catalogUrl)) {
    Wait-Until { try { (Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/health").StatusCode -eq 200 } catch { $false } } "Health $baseUrl" 180
}
Wait-PaymentConsumer
$runId = [guid]::NewGuid().ToString('N')
$admin = Post-Json "$usersUrl/api/auth/login" @{ email = 'admin@fcg.local'; password = $settings.FCG_ADMIN_PASSWORD }
$approvedGame = Post-Json "$catalogUrl/api/games" @{ title = "Stage4 approved $runId"; description = 'Synthetic stage 4 test'; developer = 'FIAP'; price = 59.90 } $admin.accessToken
$rejectedGame = Post-Json "$catalogUrl/api/games" @{ title = "Stage4 rejected $runId"; description = 'Synthetic stage 4 test'; developer = 'FIAP'; price = 150.00 } $admin.accessToken
$customer = Post-Json "$usersUrl/api/auth/register" @{ name = 'Stage4 synthetic'; email = "stage4-$runId@example.invalid"; password = 'Synthetic1!Pass' }
$customerId = $customer.user.id
Wait-Until { (Read-Outbox $customerId).ProcessedAtUtc } 'User outbox marked processed'
$welcomeRow = Read-Outbox $customerId
$welcomeKey = 'user-created:' + $welcomeRow.Id.ToLowerInvariant()
$welcome = Wait-Item $welcomeKey
Assert-True ($welcome.NotificationKind.S -eq 'Welcome') 'HTTP registration -> SQL outbox -> SQS -> Lambda -> DynamoDB'
$approvedOrder = Post-Json "$catalogUrl/api/me/library/games/$($approvedGame.id)" @{} $customer.accessToken
Wait-Library $customer.accessToken $approvedGame.id
$approved = Wait-Item ('payment-processed:' + $approvedOrder.orderId)
Assert-True ($approved.NotificationKind.S -eq 'PurchaseConfirmation') 'Approved purchase -> RabbitMQ catalog library and SQS Lambda confirmation'
$rejectedOrder = Post-Json "$catalogUrl/api/me/library/games/$($rejectedGame.id)" @{} $customer.accessToken
$rejected = Wait-Item ('payment-processed:' + $rejectedOrder.orderId)
Assert-True ($rejected.NotificationState.S -eq 'Skipped' -and @((Get-Library $customer.accessToken) | Where-Object id -eq $rejectedGame.id).Count -eq 0) 'Rejected payment recorded without adding game or confirmation'

# The users role cannot send to the payments queue. Registration must still commit its outbox.
$userOverride = Write-FailureOverride 'users-api' $settings.PAYMENT_PROCESSED_QUEUE_URL
try {
    Recreate-Service 'users-api' $userOverride
    Wait-Until { try { (Invoke-WebRequest -UseBasicParsing -Uri "$usersUrl/health").StatusCode -eq 200 } catch { $false } } 'Users healthy with unavailable notification destination'
    $retryCustomer = Post-Json "$usersUrl/api/auth/register" @{ name = 'Stage4 retry synthetic'; email = "retry-$runId@example.invalid"; password = 'Synthetic1!Pass' }
    Wait-Until { (Read-Outbox $retryCustomer.user.id).AttemptCount -gt 0 } 'Outbox failed attempt persisted'
    $pendingRow = Read-Outbox $retryCustomer.user.id
    $retryWelcomeKey = 'user-created:' + $pendingRow.Id.ToLowerInvariant()
    Assert-True (!$pendingRow.ProcessedAtUtc -and !(Read-Item $retryWelcomeKey)) 'SQS denial preserves registration and pending outbox without false success'
}
finally { Recreate-Service 'users-api' }
Wait-Until { (Read-Outbox $retryCustomer.user.id).ProcessedAtUtc } 'Outbox recovered after destination restoration'
$retryWelcome = Wait-Item $retryWelcomeKey
Assert-True ($retryWelcome.NotificationKind.S -eq 'Welcome' -and (Read-Outbox $retryCustomer.user.id).Id -eq $pendingRow.Id) 'Outbox recovery keeps original EventId and records welcome'

# RabbitMQ succeeds first; a denied SQS send must leave the order unacknowledged for retry.
$paymentOverride = Write-FailureOverride 'payments-api' $settings.USER_CREATED_QUEUE_URL
$recoveryGame = Post-Json "$catalogUrl/api/games" @{ title = "Stage4 recovery $runId"; description = 'Synthetic failure test'; developer = 'FIAP'; price = 49.90 } $admin.accessToken
try {
    Recreate-Service 'payments-api' $paymentOverride
    Wait-PaymentConsumer
    $recoveryOrder = Post-Json "$catalogUrl/api/me/library/games/$($recoveryGame.id)" @{} $customer.accessToken
    Wait-Library $customer.accessToken $recoveryGame.id
    $recoveryKey = 'payment-processed:' + $recoveryOrder.orderId
    Assert-True (!(Read-Item $recoveryKey)) 'Partial publication: catalog succeeded while SQS notification is pending'
}
finally { Recreate-Service 'payments-api' }
Wait-PaymentConsumer
$recoveredPayment = Wait-Item $recoveryKey
Assert-True ($recoveredPayment.NotificationKind.S -eq 'PurchaseConfirmation' -and @((Get-Library $customer.accessToken) | Where-Object id -eq $recoveryGame.id).Count -eq 1) 'RabbitMQ redelivery recovers notification with same OrderId and no duplicate library game'
$errorQueueCount = 0
try { $errorQueueCount = (Invoke-RestMethod -Uri 'http://127.0.0.1:15672/api/queues/%2F/payments-order-placed_error' -Headers $rabbitHeaders).messages }
catch { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
Assert-True ($errorQueueCount -eq 0) 'No payment left in RabbitMQ error queue'

$allKeys = @($welcomeKey, ('payment-processed:' + $approvedOrder.orderId), ('payment-processed:' + $rejectedOrder.orderId), $retryWelcomeKey, $recoveryKey)
foreach ($queueUrl in @($settings.USER_CREATED_QUEUE_URL, $settings.PAYMENT_PROCESSED_QUEUE_URL)) {
    Wait-Until {
        $attributes = (Invoke-AwsJson sqs get-queue-attributes @{ QueueUrl = $queueUrl; AttributeNames = @('ApproximateNumberOfMessages','ApproximateNumberOfMessagesNotVisible') }).Attributes
        [int]$attributes.ApproximateNumberOfMessages -eq 0 -and [int]$attributes.ApproximateNumberOfMessagesNotVisible -eq 0
    } 'SQS queue drained'
}
Assert-True ($true) 'Both SQS queues drained'
$evidence = @{ startedUtc = $started.ToString('O'); finishedUtc = [DateTimeOffset]::UtcNow.ToString('O'); checks = @($checks.ToArray()); eventKeys = $allKeys; cloudLogs = @(); outboxEventId = $pendingRow.Id; recoveredOrderId = $recoveryOrder.orderId }
[IO.File]::WriteAllText((Join-Path $repo 'stage4-smoke.local.json'), ($evidence | ConvertTo-Json -Depth 20), $utf8)
Write-Host 'Stage 4 smoke passed. Pause Lambda mappings, stop Compose, then run scripts/collect-stage4-logs.ps1 to capture correlated CloudWatch evidence.'
