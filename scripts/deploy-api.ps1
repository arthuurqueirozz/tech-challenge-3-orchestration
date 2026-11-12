[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('users', 'catalog')][string]$Service,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Kubeconfig,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Context,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')][string]$Namespace,
    [Parameter(Mandatory = $true)][ValidatePattern('^(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?/)?[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[a-f0-9]{64}$')][string]$Image,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$BuildSha,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$OrchestrationRef,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]([a-z0-9-]{0,29}[a-z0-9])?$')][string]$DeploymentId,
    [ValidateRange(30, 600)][int]$MigrationTimeoutSeconds = 300,
    [ValidateRange(30, 600)][int]$RolloutTimeoutSeconds = 300,
    [uri]$SmokeUrl,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$phase = 'validation'
$tempDirectory = $null
$resultOutputPath = $null
$jobName = '{0}-migrate-{1}-{2}' -f $Service, $BuildSha.Substring(0, 12), $DeploymentId
$applicationName = "$Service-api"
$result = [ordered]@{
    Status = 'failed'
    Service = $Service
    Namespace = $Namespace
    Context = $Context
    Image = $Image
    BuildSha = $BuildSha
    OrchestrationRef = $OrchestrationRef
    DeploymentId = $DeploymentId
    MigrationJob = $jobName
    Migration = 'not-started'
    Rollout = 'not-started'
    Smoke = 'skipped'
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
}

function Invoke-Kubectl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $invocationArguments = @('--kubeconfig', $script:Kubeconfig, '--context', $script:Context, '--namespace', $script:Namespace) + $Arguments
    $requestTimeout = if ($Arguments[0] -eq 'rollout') { $script:RolloutTimeoutSeconds + 30 } else { 30 }
    $invocationArguments += "--request-timeout=$($requestTimeout)s"
    # Windows PowerShell can treat a native stderr record as a terminating error.
    # Always capture the actual native exit code before interpreting the output.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $captured = @(& kubectl @invocationArguments 2>&1)
        $nativeExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($nativeExitCode -ne 0) {
        throw "kubectl $($Arguments[0]) failed (exit $nativeExitCode); phase $script:phase."
    }
    return ($captured -join [Environment]::NewLine)
}

function Read-Manifest {
    param([string]$FileName)
    $path = Join-Path $PSScriptRoot "../k8s/cloud/$Service/$FileName.json"
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Write-Manifest {
    param([object]$Manifest, [string]$FileName)
    $path = Join-Path $script:tempDirectory "$FileName.json"
    [IO.File]::WriteAllText($path, ($Manifest | ConvertTo-Json -Depth 40), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Test-JobCondition {
    param([object]$Job, [string]$Condition)
    return @($Job.status.conditions | Where-Object { $_.type -eq $Condition -and $_.status -eq 'True' }).Count -gt 0
}

function Assert-ExistingJob {
    param([object]$Job)
    $pod = $Job.spec.template.spec
    $containers = @($pod.containers)
    $container = $containers[0]
    $labels = $Job.metadata.labels
    $annotations = $Job.metadata.annotations
    $valid = $containers.Count -eq 1 -and $container.name -eq 'migration' `
        -and $container.image -eq $script:Image `
        -and @($container.args).Count -eq 1 -and $container.args[0] -eq '--migrate' `
        -and -not $container.command `
        -and @($container.envFrom).Count -eq 1 `
        -and $container.envFrom[0].secretRef.name -eq "$Service-migration-secrets" `
        -and @($container.env).Count -eq 1 `
        -and $container.env[0].name -eq 'ASPNETCORE_ENVIRONMENT' -and $container.env[0].value -eq 'Production' `
        -and $pod.serviceAccountName -eq "$Service-migration" `
        -and $Job.spec.template.metadata.labels.app -eq "$Service-migration" `
        -and $pod.automountServiceAccountToken -eq $false -and $pod.restartPolicy -eq 'Never' `
        -and $Job.spec.backoffLimit -eq 0 -and $Job.spec.activeDeadlineSeconds -eq $MigrationTimeoutSeconds `
        -and $Job.spec.suspend -ne $true `
        -and $labels.app -eq $applicationName -and $labels.'fcg.dev/operation' -eq 'migration' `
        -and $annotations.'fcg.dev/build-sha' -eq $BuildSha `
        -and $annotations.'fcg.dev/orchestration-ref' -eq $OrchestrationRef `
        -and $annotations.'fcg.dev/deployment-id' -eq $DeploymentId
    if (-not $valid) { throw 'Existing migration Job differs from the requested deployment; use a new DeploymentId after inspection.' }
}

function Write-LimitedDiagnostics {
    try {
        $summary = Invoke-Kubectl -Arguments @('get', 'pods', '--selector', "app=$applicationName", '--output', 'custom-columns=NAME:.metadata.name,PHASE:.status.phase', '--no-headers')
        if ($summary) { Write-Host $summary }
    }
    catch { Write-Warning 'Pod phase summary unavailable.' }
}

try {
    $null = Get-Command kubectl -ErrorAction Stop
    $Kubeconfig = (Resolve-Path -LiteralPath $Kubeconfig -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $Kubeconfig -PathType Leaf)) { throw 'Kubeconfig must be an existing file.' }
    if ($OutputPath) {
        $candidateOutputPath = [IO.Path]::GetFullPath($OutputPath)
        if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidateOutputPath)) -PathType Container) `
            -or (Test-Path -LiteralPath $candidateOutputPath -PathType Container)) {
            throw 'OutputPath must refer to a file in an existing directory.'
        }
        $resultOutputPath = $candidateOutputPath
    }
    if ($SmokeUrl) {
        if (-not $SmokeUrl.IsAbsoluteUri -or $SmokeUrl.UserInfo -or $SmokeUrl.Query -or $SmokeUrl.Fragment) {
            throw 'SmokeUrl must be an absolute URL without credentials, query or fragment.'
        }
        if ($SmokeUrl.Scheme -ne 'https' -and -not ($SmokeUrl.Scheme -eq 'http' -and $SmokeUrl.IsLoopback)) {
            throw 'SmokeUrl requires HTTPS; HTTP is allowed only on loopback for isolated QA.'
        }
    }
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempDirectory = Join-Path $temporaryRoot ('fcg-deploy-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempDirectory

    $phase = 'guard'
    $jobs = Invoke-Kubectl -Arguments @('get', 'jobs', '--selector', "app=$applicationName,fcg.dev/operation=migration", '--output', 'json') | ConvertFrom-Json
    foreach ($otherJob in @($jobs.items)) {
        if ($otherJob.metadata.name -and $otherJob.metadata.name -ne $jobName `
            -and -not (Test-JobCondition $otherJob 'Complete') -and -not (Test-JobCondition $otherJob 'Failed')) {
            throw 'Another migration Job for this API is active. Wait for it; do not delete an active Job.'
        }
    }

    $annotations = @{
        'fcg.dev/build-sha' = $BuildSha
        'fcg.dev/orchestration-ref' = $OrchestrationRef
        'fcg.dev/deployment-id' = $DeploymentId
    }
    $phase = 'migration'
    $jobJson = Invoke-Kubectl -Arguments @('get', 'job', $jobName, '--ignore-not-found', '--output', 'json')
    if ([string]::IsNullOrWhiteSpace($jobJson)) {
        $job = Read-Manifest 'migration-job'
        $job.metadata.name = $jobName
        $job.metadata | Add-Member -MemberType NoteProperty -Name annotations -Value $annotations -Force
        $job.spec.activeDeadlineSeconds = $MigrationTimeoutSeconds
        $job.spec.template.spec.containers[0].image = $Image
        $jobFile = Write-Manifest $job 'job'
        # create, rather than apply, cannot mutate a racing or pre-existing Job.
        $null = Invoke-Kubectl -Arguments @('create', '--filename', $jobFile)
    }
    else { Assert-ExistingJob ($jobJson | ConvertFrom-Json) }

    $result.Migration = 'waiting'
    $migrationWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $job = Invoke-Kubectl -Arguments @('get', 'job', $jobName, '--output', 'json') | ConvertFrom-Json
        Assert-ExistingJob $job
        if (Test-JobCondition $job 'Failed') { throw 'Migration Job failed; Deployment has not been changed.' }
        if (Test-JobCondition $job 'Complete') { break }
        if ($migrationWatch.Elapsed.TotalSeconds -ge $MigrationTimeoutSeconds) { throw 'Migration Job timed out; Deployment has not been changed. Inspect the Job before retrying.' }
        Start-Sleep -Seconds 2
    }
    $result.Migration = 'complete'

    $phase = 'deployment'
    $deployment = Read-Manifest 'deployment'
    $deployment.metadata | Add-Member -MemberType NoteProperty -Name annotations -Value $annotations -Force
    $deployment.spec.template.metadata | Add-Member -MemberType NoteProperty -Name annotations -Value @{
        'fcg.dev/build-sha' = $BuildSha
        'fcg.dev/orchestration-ref' = $OrchestrationRef
    } -Force
    $deployment.spec.template.spec.containers[0].image = $Image
    $deployment.spec.progressDeadlineSeconds = $RolloutTimeoutSeconds
    $serviceFile = Write-Manifest (Read-Manifest 'service') 'service'
    $deploymentFile = Write-Manifest $deployment 'deployment'
    $null = Invoke-Kubectl -Arguments @('apply', '--filename', $serviceFile)
    $null = Invoke-Kubectl -Arguments @('apply', '--filename', $deploymentFile)

    $phase = 'rollout'
    $result.Rollout = 'waiting'
    $null = Invoke-Kubectl -Arguments @('rollout', 'status', "deployment/$applicationName", "--timeout=$($RolloutTimeoutSeconds)s")
    $result.Rollout = 'complete'

    $phase = 'smoke'
    if ($SmokeUrl) {
        $result.Smoke = 'failed'
        $expectedService = if ($Service -eq 'users') { 'FCG Users API' } else { 'FCG Catalog API' }
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri $SmokeUrl.AbsoluteUri -Method Get -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 10 -ErrorAction Stop
                $body = $response.Content | ConvertFrom-Json
                if ([int]$response.StatusCode -eq 200 -and $response.Headers['X-Build-Sha'] -eq $BuildSha `
                    -and $body.service -eq $expectedService -and $body.status -eq 'running') {
                    $result.Smoke = 'passed'
                    break
                }
            }
            catch { } # Retry without printing URLs, response bodies or headers.
            if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
        }
        if ($result.Smoke -ne 'passed') { throw 'Gateway smoke failed: expected API status, body and X-Build-Sha were not observed.' }
    }
    else { Write-Warning 'Smoke skipped: no SmokeUrl supplied. This is not complete deployment acceptance.' }
    $result.Status = 'succeeded'
    Write-Host "Deployment completed: $Service, build $BuildSha, migration $jobName, smoke $($result.Smoke)."
}
catch {
    $result['FailurePhase'] = $phase
    if ($phase -ne 'validation') { Write-LimitedDiagnostics }
    throw
}
finally {
    $result['FinishedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    if ($resultOutputPath) {
        [IO.File]::WriteAllText($resultOutputPath, ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    }
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        $resolvedTemporary = [IO.Path]::GetFullPath($tempDirectory)
        $permittedPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'fcg-deploy-'
        if (-not $resolvedTemporary.StartsWith($permittedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the generated deployment directory.' }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
