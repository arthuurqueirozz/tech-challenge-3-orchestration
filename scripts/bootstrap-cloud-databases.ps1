[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Kubeconfig,
    [ValidateNotNullOrEmpty()][string]$Context = 'fcg-fase4',
    [ValidateRange(60, 600)][int]$TimeoutSeconds = 300,
    [string]$AwsExecutable = $env:FCG_AWS_EXECUTABLE
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')
if ($AwsExecutable) { $env:FCG_AWS_EXECUTABLE = $AwsExecutable }
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state

function Assert-CloudKubeTarget {
    param([object]$State, [string]$Kubeconfig, [string]$Context)
    $identity = Invoke-CloudAws -Arguments @('sts', 'get-caller-identity') -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($identity.Account -ne $State.AccountId) { throw 'The authenticated AWS account differs from the private state.' }
    if (-not $State.NetworkOutputs.ClusterName -or -not $State.NetworkOutputs.ClusterEndpoint) {
        throw 'Real network-compute cluster outputs are required before distributing credentials.'
    }
    $remote = Invoke-CloudAws -Arguments @('eks', 'describe-cluster', '--name', $State.NetworkOutputs.ClusterName) -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($remote.cluster.endpoint -ne $State.NetworkOutputs.ClusterEndpoint -or -not $remote.cluster.certificateAuthority.data) {
        throw 'The live EKS endpoint/CA does not match the expected cluster.'
    }
    $configuration = Invoke-CloudKubectl -Arguments @('config', 'view', '--minify', '--raw') -Kubeconfig $Kubeconfig -Context $Context -AsJson
    if (@($configuration.clusters).Count -ne 1) { throw 'The selected kubeconfig must resolve to exactly one cluster.' }
    $cluster = $configuration.clusters[0].cluster
    if ($cluster.'insecure-skip-tls-verify' -or
        $cluster.'certificate-authority-data' -cne $remote.cluster.certificateAuthority.data) {
        throw 'The kubeconfig must verify the actual EKS certificate authority.'
    }
    $expected = [uri]$remote.cluster.endpoint
    $server = [uri]$cluster.server
    $direct = $server.AbsoluteUri.TrimEnd('/') -ceq $expected.AbsoluteUri.TrimEnd('/')
    $tunnel = $server.Scheme -eq 'https' -and $server.Host -in @('127.0.0.1', 'localhost', '[::1]', '::1') -and
        $server.AbsolutePath -eq '/' -and $cluster.'tls-server-name' -ceq $expected.Host
    if ((-not $direct -and -not $tunnel) -or $server.UserInfo -or $server.Query -or $server.Fragment -or
        ($direct -and $cluster.'tls-server-name' -and $cluster.'tls-server-name' -cne $expected.Host)) {
        throw 'The kubeconfig target must be the actual EKS endpoint or a verified local TLS tunnel.'
    }
}

function Invoke-PlatformKubectl {
    param([string[]]$Arguments, [switch]$AsJson)
    return Invoke-CloudKubectl -Arguments $Arguments -Kubeconfig $Kubeconfig -Context $Context -Namespace 'fcg-platform' -AsJson:$AsJson
}

Assert-CloudKubeTarget -State $state -Kubeconfig $Kubeconfig -Context $Context
if (([DateTimeOffset]::Parse($state.WindowEndUtc) - [DateTimeOffset]::UtcNow).TotalSeconds -lt ($TimeoutSeconds + 60)) {
    throw 'The remaining approved window is too short to finish the database bootstrap.'
}
$passwordFields = [ordered]@{
    USERS_APP_PASSWORD_B64 = 'UsersAppPassword'
    USERS_MIGRATION_PASSWORD_B64 = 'UsersMigrationPassword'
    CATALOG_APP_PASSWORD_B64 = 'CatalogAppPassword'
    CATALOG_MIGRATION_PASSWORD_B64 = 'CatalogMigrationPassword'
}
$passwordData = [ordered]@{}
foreach ($key in $passwordFields.Keys) {
    $value = $state.Secrets.($passwordFields[$key])
    if ($value -isnot [string] -or $value.Length -lt 20 -or $value.Length -gt 128 -or $value -match '[\x00-\x1f\x7f]') {
        throw 'The four database credentials must be valid existing private-state passwords.'
    }
    # sqlcmd substitutes only base64's restricted alphabet. T-SQL decodes UTF-16LE.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($value))
    $passwordData[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encoded))
}
if ($state.Secrets.SqlSaPassword -isnot [string] -or [string]::IsNullOrWhiteSpace($state.Secrets.SqlSaPassword)) {
    throw 'The existing SQL administrator password is required in private state.'
}
$saList = Invoke-PlatformKubectl -Arguments @('get', 'secrets', '--field-selector', 'metadata.name=sql-bootstrap-secrets') -AsJson
$saItems = @($saList.items)
$expectedSa = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($state.Secrets.SqlSaPassword))
if ($saItems.Count -ne 1 -or $saItems[0].data.MSSQL_SA_PASSWORD -cne $expectedSa) {
    throw 'The SQL administrator Secret differs from private state; recover it before database bootstrap.'
}
$existingJobs = Invoke-PlatformKubectl -Arguments @('get', 'jobs', '-l', 'fcg.dev/operation=database-bootstrap') -AsJson
if ($existingJobs.PSObject.Properties.Name -notcontains 'items') { throw 'Job preflight returned malformed JSON.' }
foreach ($existing in @($existingJobs.items)) {
    $terminal = @($existing.status.conditions | Where-Object { $_.status -eq 'True' -and $_.type -in @('Complete', 'Failed') })
    if ($terminal.Count -eq 0) { throw 'A database bootstrap Job is still active or pending; wait and inspect its result.' }
}
$deployment = Invoke-PlatformKubectl -Arguments @('get', 'deployment', 'sqlserver') -AsJson
$sqlContainers = @($deployment.spec.template.spec.containers | Where-Object { $_.name -eq 'sqlserver' })
if ($sqlContainers.Count -ne 1 -or -not $sqlContainers[0].image) { throw 'The verified SQL Server deployment/image is required.' }
$sqlImage = $sqlContainers[0].image

# No actual credential is versioned in this SQL. All four values arrive as
# Secret-backed environment variables, separate from SQLCMDPASSWORD used by sa.
$sql = @'
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @lockResult int;
EXEC @lockResult = sys.sp_getapplock @Resource=N'fcg-database-bootstrap', @LockMode=N'Exclusive', @LockOwner=N'Session', @LockTimeout=0;
IF @lockResult < 0 THROW 51000, 'Another database bootstrap is running.', 1;

DECLARE @usersAppEncoded nvarchar(512) = N'$(USERS_APP_PASSWORD_B64)';
DECLARE @usersMigrationEncoded nvarchar(512) = N'$(USERS_MIGRATION_PASSWORD_B64)';
DECLARE @catalogAppEncoded nvarchar(512) = N'$(CATALOG_APP_PASSWORD_B64)';
DECLARE @catalogMigrationEncoded nvarchar(512) = N'$(CATALOG_MIGRATION_PASSWORD_B64)';
DECLARE @xml xml = N'';
DECLARE @usersApp nvarchar(128) = CONVERT(nvarchar(128), @xml.value('xs:base64Binary(sql:variable("@usersAppEncoded"))', 'varbinary(256)'));
DECLARE @usersMigration nvarchar(128) = CONVERT(nvarchar(128), @xml.value('xs:base64Binary(sql:variable("@usersMigrationEncoded"))', 'varbinary(256)'));
DECLARE @catalogApp nvarchar(128) = CONVERT(nvarchar(128), @xml.value('xs:base64Binary(sql:variable("@catalogAppEncoded"))', 'varbinary(256)'));
DECLARE @catalogMigration nvarchar(128) = CONVERT(nvarchar(128), @xml.value('xs:base64Binary(sql:variable("@catalogMigrationEncoded"))', 'varbinary(256)'));

DECLARE @expected TABLE (LoginName sysname NOT NULL, SecretValue nvarchar(128) NOT NULL, DatabaseName sysname NOT NULL, IsMigration bit NOT NULL);
INSERT INTO @expected VALUES
    (N'fcg_users_app', @usersApp, N'FcgUsersDb', 0),
    (N'fcg_users_migrate', @usersMigration, N'FcgUsersDb', 1),
    (N'fcg_catalog_app', @catalogApp, N'FcgCatalogDb', 0),
    (N'fcg_catalog_migrate', @catalogMigration, N'FcgCatalogDb', 1);
IF EXISTS (SELECT 1 FROM @expected WHERE DATALENGTH(SecretValue) < 40)
    THROW 51000, 'Missing or invalid database credentials.', 1;

-- Verify every existing credential before the first CREATE/ALTER statement.
IF EXISTS (
    SELECT 1 FROM @expected AS e
    JOIN sys.server_principals AS p ON p.name = e.LoginName
    LEFT JOIN sys.sql_logins AS l ON l.principal_id = p.principal_id
    WHERE p.type <> 'S' OR l.is_disabled = 1 OR ISNULL(PWDCOMPARE(e.SecretValue, l.password_hash), 0) <> 1
) THROW 51000, 'Existing login credentials differ; recover state without rotating.', 1;
IF EXISTS (
    SELECT 1 FROM @expected AS e
    JOIN sys.server_principals AS p ON p.name = e.LoginName
    JOIN sys.server_role_members AS r ON r.member_principal_id = p.principal_id
) THROW 51000, 'Unexpected server role membership; review the existing login.', 1;
IF EXISTS (
    SELECT 1 FROM @expected AS e
    JOIN sys.server_principals AS p ON p.name = e.LoginName
    JOIN sys.server_permissions AS r ON r.grantee_principal_id = p.principal_id
    WHERE r.permission_name <> N'CONNECT SQL' OR r.state <> 'G'
) THROW 51000, 'Unexpected server permissions; review the existing login.', 1;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name IN (N'FcgUsersDb', N'FcgCatalogDb') AND state <> 0)
    THROW 51000, 'An existing application database is not online.', 1;

IF DB_ID(N'FcgUsersDb') IS NULL EXEC(N'CREATE DATABASE [FcgUsersDb]');
IF DB_ID(N'FcgCatalogDb') IS NULL EXEC(N'CREATE DATABASE [FcgCatalogDb]');

DECLARE @login sysname, @secret nvarchar(128), @database sysname, @isMigration bit, @command nvarchar(max);
DECLARE expected_logins CURSOR LOCAL FAST_FORWARD FOR SELECT LoginName, SecretValue, DatabaseName, IsMigration FROM @expected ORDER BY LoginName;
OPEN expected_logins;
FETCH NEXT FROM expected_logins INTO @login, @secret, @database, @isMigration;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF SUSER_ID(@login) IS NULL
    BEGIN
        SET @command = N'CREATE LOGIN ' + QUOTENAME(@login) + N' WITH PASSWORD = N' + QUOTENAME(@secret, '''') + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = ' + QUOTENAME(@database) + N';';
        EXEC sys.sp_executesql @command;
    END;
    SET @command = N'USE ' + QUOTENAME(@database) + N';
        DECLARE @statement nvarchar(max);
        IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @LoginName AND sid <> SUSER_SID(@LoginName))
            THROW 51000, ''Existing database user maps to another login.'', 1;
        IF DATABASE_PRINCIPAL_ID(@LoginName) IS NULL
        BEGIN
            SET @statement = N''CREATE USER '' + QUOTENAME(@LoginName) + N'' FOR LOGIN '' + QUOTENAME(@LoginName);
            EXEC sys.sp_executesql @statement;
        END;
        IF EXISTS (
            SELECT 1 FROM sys.database_role_members AS m
            JOIN sys.database_principals AS r ON r.principal_id = m.role_principal_id
            WHERE m.member_principal_id = DATABASE_PRINCIPAL_ID(@LoginName)
                AND ((@Migration = 0 AND r.name NOT IN (N''db_datareader'', N''db_datawriter''))
                  OR (@Migration = 1 AND r.name <> N''db_owner''))
        ) THROW 51000, ''Unexpected database role membership; review the existing user.'', 1;
        IF EXISTS (SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(@LoginName)
            AND (permission_name <> N''CONNECT'' OR state <> ''G''))
            THROW 51000, ''Unexpected direct database permissions; review the existing user.'', 1;
        IF EXISTS (SELECT 1 FROM sys.schemas WHERE principal_id = DATABASE_PRINCIPAL_ID(@LoginName))
            THROW 51000, ''Unexpected schema ownership; review the existing user.'', 1;
        IF @Migration = 1
        BEGIN
            IF ISNULL(IS_ROLEMEMBER(N''db_owner'', @LoginName), 0) <> 1
            BEGIN
                SET @statement = N''ALTER ROLE [db_owner] ADD MEMBER '' + QUOTENAME(@LoginName);
                EXEC sys.sp_executesql @statement;
            END;
        END
        ELSE
        BEGIN
            IF ISNULL(IS_ROLEMEMBER(N''db_datareader'', @LoginName), 0) <> 1
            BEGIN
                SET @statement = N''ALTER ROLE [db_datareader] ADD MEMBER '' + QUOTENAME(@LoginName);
                EXEC sys.sp_executesql @statement;
            END;
            IF ISNULL(IS_ROLEMEMBER(N''db_datawriter'', @LoginName), 0) <> 1
            BEGIN
                SET @statement = N''ALTER ROLE [db_datawriter] ADD MEMBER '' + QUOTENAME(@LoginName);
                EXEC sys.sp_executesql @statement;
            END;
        END;';
    EXEC sys.sp_executesql @command, N'@LoginName sysname, @Migration bit', @LoginName = @login, @Migration = @isMigration;
    FETCH NEXT FROM expected_logins INTO @login, @secret, @database, @isMigration;
END;
CLOSE expected_logins;
DEALLOCATE expected_logins;
PRINT N'Database bootstrap completed.';
'@
$shell = @'
set -eu
umask 077
trap 'rm -f /tmp/fcg-bootstrap.log' EXIT
tool=/opt/mssql-tools18/bin/sqlcmd
if [ ! -x "$tool" ]; then tool=/opt/mssql-tools/bin/sqlcmd; fi
if [ ! -x "$tool" ]; then echo 'The SQL Server image lacks sqlcmd.' >&2; exit 1; fi
if "$tool" -S tcp:sqlserver.fcg-platform.svc.cluster.local,1433 -U sa -d master -C -b -l 15 -t 180 -i /bootstrap/init.sql >/tmp/fcg-bootstrap.log 2>&1; then
    echo 'Database credentials and role memberships verified.'
else
    echo 'Database bootstrap failed; SQL diagnostics suppressed to protect credentials. Recover the private state or review permissions.' >&2
    exit 1
fi
'@
$jobName = 'sql-bootstrap-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$secretName = "$jobName-credentials"
$configName = "$jobName-sql"
$labels = @{ 'app.kubernetes.io/part-of' = 'fcg'; 'fcg.dev/operation' = 'database-bootstrap' }
$configuration = @{ apiVersion = 'v1'; kind = 'ConfigMap'; metadata = @{ name = $configName; namespace = 'fcg-platform'; labels = $labels }; data = @{ 'init.sql' = $sql } }
$credentials = @{ apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = $secretName; namespace = 'fcg-platform'; labels = $labels }; type = 'Opaque'; data = $passwordData }
$job = @{
    apiVersion = 'batch/v1'; kind = 'Job'; metadata = @{ name = $jobName; namespace = 'fcg-platform'; labels = $labels }
    spec = @{
        backoffLimit = 0; activeDeadlineSeconds = $TimeoutSeconds
        template = @{
            metadata = @{ labels = $labels }
            spec = @{
                restartPolicy = 'Never'; serviceAccountName = 'sqlserver'; automountServiceAccountToken = $false; terminationGracePeriodSeconds = 15
                securityContext = @{ runAsUser = 10001; runAsGroup = 0; runAsNonRoot = $true }
                containers = @(@{
                    name = 'sql-bootstrap'; image = $sqlImage; imagePullPolicy = 'IfNotPresent'; command = @('/bin/sh', '-c', $shell)
                    env = @(@{ name = 'SQLCMDPASSWORD'; valueFrom = @{ secretKeyRef = @{ name = 'sql-bootstrap-secrets'; key = 'MSSQL_SA_PASSWORD' } } })
                    envFrom = @(@{ secretRef = @{ name = $secretName } })
                    resources = @{ requests = @{ cpu = '50m'; memory = '64Mi' }; limits = @{ cpu = '500m'; memory = '256Mi' } }
                    securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') }; seccompProfile = @{ type = 'RuntimeDefault' } }
                    volumeMounts = @(@{ name = 'script'; mountPath = '/bootstrap'; readOnly = $true })
                })
                volumes = @(@{ name = 'script'; configMap = @{ name = $configName } })
            }
        }
    }
}
$tempPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))) ("$jobName.local.json")
$createdConfiguration = $false
$createdCredentials = $false
$createdJob = $false
$terminalJob = $false
try {
    Assert-CloudWindow -State $state
    Write-CloudJson -Path $tempPath -Value $configuration
    $null = Invoke-PlatformKubectl -Arguments @('create', '-f', $tempPath)
    $createdConfiguration = $true
    Write-CloudJson -Path $tempPath -Value $credentials
    $null = Invoke-PlatformKubectl -Arguments @('create', '-f', $tempPath)
    $createdCredentials = $true
    Write-CloudJson -Path $tempPath -Value $job
    Assert-CloudWindow -State $state
    $null = Invoke-PlatformKubectl -Arguments @('create', '-f', $tempPath)
    $createdJob = $true
    Write-Host "Waiting for database bootstrap Job $jobName."
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds + 30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $observed = Invoke-PlatformKubectl -Arguments @('get', 'job', $jobName) -AsJson
        if (@($observed.status.conditions | Where-Object { $_.type -eq 'Complete' -and $_.status -eq 'True' }).Count -gt 0) {
            $terminalJob = $true
            Write-Host 'Both application databases and their separate runtime/migration identities are ready.'
            break
        }
        if (@($observed.status.conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0) {
            $terminalJob = $true
            throw 'Database bootstrap Job failed. No login password was rotated; inspect the private-state credentials and existing privileges.'
        }
        Start-Sleep -Seconds 2
    }
    if (-not $terminalJob) { throw "Database bootstrap timed out; Job $jobName and its inputs are retained until its terminal state is verified." }
}
finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    if (-not $createdJob -or $terminalJob) {
        # Only objects created by this invocation are eligible for removal.
        if ($createdJob) { $null = Invoke-PlatformKubectl -Arguments @('delete', 'job', $jobName, '--wait=true', '--timeout=30s') }
        if ($createdCredentials) { $null = Invoke-PlatformKubectl -Arguments @('delete', 'secret', $secretName, '--wait=true', '--timeout=30s') }
        if ($createdConfiguration) { $null = Invoke-PlatformKubectl -Arguments @('delete', 'configmap', $configName, '--wait=true', '--timeout=30s') }
    }
    else {
        Write-Warning "Job $jobName may still be running. Its own Secret/ConfigMap remain available; never delete another active bootstrap Job."
    }
}
