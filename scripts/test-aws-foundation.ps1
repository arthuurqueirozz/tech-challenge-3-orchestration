[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Profile = 'fiap-fase4',
    [ValidateSet('us-east-2')][string]$Region = 'us-east-2',
    [string]$AwsExecutable = 'aws'
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()
$needsLogin = $false
$report = [ordered]@{
    SchemaVersion = 1
    ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    ExpectedAccountId = $ExpectedAccountId
    Region = $Region
    ReadOnly = $true
    CreationPermissionsVerified = $false
    ReadyToProvision = $false
    GateStatus = 'blocked'
    PendingGates = @('Current price estimate and accepted window/credit coverage', 'Creation permissions and service-linked roles', 'Runner connectivity and IAM/RBAC', 'Explicit provisioning operation after review')
}

function Add-Check([string]$Name, [bool]$Passed, [string]$Observed, [bool]$Required = $true) {
    $checks.Add([pscustomobject]@{Name=$Name; Passed=$Passed; Required=$Required; Observed=$Observed})
}

function Read-Aws([string]$Name, [string[]]$ApiArguments, [string]$ApiRegion = $Region, [bool]$Required = $true) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $captured = @(& $AwsExecutable @ApiArguments --profile $Profile --region $ApiRegion --output json --no-cli-pager --cli-connect-timeout 5 --cli-read-timeout 15 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prior }
    $raw = $captured -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        $reason = 'API unavailable or request rejected; inspect privately.'
        if ($raw -match '(?i)expired|reauthenticate|aws login|SSO session|ExpiredToken') {
            $script:needsLogin = $true
            $reason = 'Session expired; renew using aws login.'
        }
        elseif ($raw -match 'AccessDenied|UnauthorizedOperation|explicit deny') { $reason = 'Access denied; permissions/SCP not verified.' }
        elseif ($raw -match 'NoSuchEntity') { $reason = 'Role does not exist; creation permission remains unverified.' }
        Add-Check $Name $false $reason $Required
        return $null
    }
    try {
        if ($raw -notmatch '^\s*\{') { throw 'Expected an AWS JSON object root.' }
        $response = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $response -or $response -isnot [pscustomobject]) {
            throw 'Expected an AWS JSON object response.'
        }
        return $response
    }
    catch { Add-Check $Name $false 'Invalid or unexpected JSON response; no raw response recorded.' $Required; return $null }
}

$absoluteOutput = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath (Split-Path $absoluteOutput -Parent) -PathType Container)) {
    throw 'OutputPath parent directory must exist.'
}
$null = Get-Command $AwsExecutable -ErrorAction Stop
$oldAttempts = $env:AWS_MAX_ATTEMPTS
$env:AWS_MAX_ATTEMPTS = '1'
try {
    $identity = Read-Aws 'identity' @('sts','get-caller-identity')
    if ($null -ne $identity) {
        $identityMatches = $identity.Account -eq $ExpectedAccountId
        Add-Check 'expected-account' $identityMatches 'Caller account compared with the explicit expected account.'
        if ($identityMatches) {
            $report['CallerArn'] = $identity.Arn
            $plan = Read-Aws 'free-plan' @('freetier','get-account-plan-state') 'us-east-1'
            if ($null -ne $plan) {
                $report['AccountPlan'] = $plan
                $expiryOk = $false
                try { $expiryOk = [DateTimeOffset]::Parse($plan.accountPlanExpirationDate) -gt [DateTimeOffset]::UtcNow } catch { }
                $balance = [decimal]0
                $balanceOk = [decimal]::TryParse([Convert]::ToString($plan.accountPlanRemainingCredits.amount, [Globalization.CultureInfo]::InvariantCulture), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$balance)
                $planOk = $plan.accountId -eq $ExpectedAccountId -and $plan.accountPlanType -eq 'FREE' `
                    -and $plan.accountPlanStatus -eq 'ACTIVE' -and $plan.accountPlanRemainingCredits.unit -eq 'USD' `
                    -and $balanceOk -and $balance -gt 0 -and $expiryOk
                Add-Check 'free-active-with-credit' $planOk 'Require FREE, ACTIVE, unexpired plan and positive USD credit; not a price/coverage guarantee.'
            }

            if ($identity.Arn -match '^arn:aws:sts::[0-9]{12}:assumed-role/([^/]+)/[^/]+$') {
                $role = Read-Aws 'operator-role' @('iam','get-role','--role-name',$Matches[1])
                if ($null -ne $role) {
                    $roleOk = $role.Role.Arn -match ('^arn:aws:iam::' + $ExpectedAccountId + ':role/.+$')
                    Add-Check 'operator-role-arn' $roleOk 'Role ARN obtained from IAM; STS session ARN is not a template principal.'
                    if ($roleOk) { $report['OperatorRoleArn'] = $role.Role.Arn }
                }
            }
            else { Add-Check 'operator-role-arn' $false 'Use an authenticated IAM role; an STS session ARN or user is not the administrator role parameter.' }

            $zones = Read-Aws 'availability-zones' @('ec2','describe-availability-zones','--filters','Name=state,Values=available')
            if ($null -ne $zones) {
                $names = @($zones.AvailabilityZones | Where-Object { $_.ZoneName -match '^us-east-2[a-z]$' -and $_.State -eq 'available' } | Select-Object -ExpandProperty ZoneName | Sort-Object -Unique)
                $report['AvailabilityZones'] = $names
                Add-Check 'two-available-zones' ($names.Count -ge 2) 'Require two distinct standard Ohio availability zones.'
            }
            $types = Read-Aws 'node-instance-type' @('ec2','describe-instance-types','--instance-types','m6a.xlarge')
            if ($null -ne $types) {
                $type = @($types.InstanceTypes)[0]
                $report['NodeCapacity'] = @{InstanceType=$type.InstanceType; VCpu=$type.VCpuInfo.DefaultVCpus; MemoryMiB=$type.MemoryInfo.SizeInMiB}
                Add-Check 'node-capacity' ($type.VCpuInfo.DefaultVCpus -eq 4 -and $type.MemoryInfo.SizeInMiB -eq 16384) 'Verify the planned 4-vCPU/16-GiB node, not actual scheduling or capacity reservation.'
            }
            $offerings = Read-Aws 'node-offerings' @('ec2','describe-instance-type-offerings','--location-type','availability-zone','--filters','Name=instance-type,Values=m6a.xlarge')
            if ($null -ne $offerings) {
                $offeredZones = @($offerings.InstanceTypeOfferings | Select-Object -ExpandProperty Location -Unique)
                $report['NodeOfferedInZones'] = $offeredZones
                Add-Check 'node-offered-in-ohio' (@($offeredZones | Where-Object { $_ -match '^us-east-2[a-z]$' }).Count -gt 0) 'Offering is not a guarantee of launch permission or physical capacity.'
            }
            $quota = Read-Aws 'node-vcpu-quota' @('service-quotas','get-service-quota','--service-code','ec2','--quota-code','L-1216C47A')
            if ($null -ne $quota) {
                $report['StandardOnDemandVCpuQuota'] = $quota.Quota.Value
                $vcpuLimit = [double]0
                $quotaOk = [double]::TryParse([Convert]::ToString($quota.Quota.Value, [Globalization.CultureInfo]::InvariantCulture), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$vcpuLimit)
                Add-Check 'node-vcpu-limit' ($quotaOk -and -not [double]::IsInfinity($vcpuLimit) -and $vcpuLimit -ge 4) 'Limit must cover the node; current account usage still needs inspection before launch.'
            }
            $versions = Read-Aws 'eks-version' @('eks','describe-cluster-versions','--cluster-versions','1.35')
            if ($null -ne $versions) {
                $version = @($versions.clusterVersions | Where-Object { $_.clusterVersion -eq '1.35' })
                $supported = $version.Count -gt 0 -and ($version[0].versionStatus -eq 'STANDARD_SUPPORT' -or $version[0].status -eq 'STANDARD_SUPPORT')
                $report['EksVersion'] = $version
                Add-Check 'eks-standard-support' $supported 'Require EKS 1.35 in standard support.'
            }
            $limits = Read-Aws 'search-instance-limits' @('opensearch','describe-instance-type-limits','--instance-type','t3.small.search','--engine-version','OpenSearch_2.19')
            if ($null -ne $limits) {
                $report['SearchLimits'] = $limits.LimitsByRole
                $storage = @($limits.LimitsByRole.data.StorageTypes | Where-Object { $_.StorageTypeName -eq 'ebs' -and $_.StorageSubTypeName -eq 'gp3' })
                $minimum = @($storage.StorageTypeLimits | Where-Object LimitName -eq 'MinimumVolumeSize' | Select-Object -ExpandProperty LimitValues)
                $maximum = @($storage.StorageTypeLimits | Where-Object LimitName -eq 'MaximumVolumeSize' | Select-Object -ExpandProperty LimitValues)
                $minimumSize = 0; $maximumSize = 0
                $sizeOk = $minimum.Count -gt 0 -and $maximum.Count -gt 0 `
                    -and [int]::TryParse([string]$minimum[0], [ref]$minimumSize) -and [int]::TryParse([string]$maximum[0], [ref]$maximumSize) `
                    -and $minimumSize -gt 0 -and $minimumSize -le 10 -and $maximumSize -ge 10
                Add-Check 'search-gp3-size' $sizeOk 'Confirm 10 GiB gp3 is within published limits; no domain was created.'
            }
            $linked = Read-Aws 'search-service-linked-role' @('iam','get-role','--role-name','AWSServiceRoleForAmazonOpenSearchService') $Region $false
            if ($null -ne $linked) { $report['SearchServiceLinkedRoleArn'] = $linked.Role.Arn; Add-Check 'search-service-linked-role' $true 'Existing role found; no role was created.' $false }
        }
    }
    if (@($checks | Where-Object Required).Count -eq 0) { Add-Check 'no-verifications' $false 'No required verification completed; the result is blocked.' }
    $requiredFailures = @($checks | Where-Object { $_.Required -and -not $_.Passed }).Count
    $report.GateStatus = if ($needsLogin) { 'needs-login' } elseif ($requiredFailures -gt 0) { 'blocked' } else { 'read-only-verified' }
    $report['Checks'] = @($checks.ToArray())
    [IO.File]::WriteAllText($absoluteOutput, ($report | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    Write-Output "AWS readonly checks: $($report.GateStatus). Provisioning remains disabled; report: $absoluteOutput"
    if ($needsLogin -or $requiredFailures -gt 0) { exit 1 }
}
finally { $env:AWS_MAX_ATTEMPTS = $oldAttempts }
