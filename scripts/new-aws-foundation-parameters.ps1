[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('network-compute','search')][string]$Stage,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidatePattern('^[a-z][a-z0-9-]{1,18}[a-z0-9]$')][string]$ProjectName = 'fcg-fase4',
    [string]$AdminRoleArn,
    [string]$AdminCidrIPv4,
    [string]$AvailabilityZoneA,
    [string]$AvailabilityZoneB,
    [string]$NetworkOutputsPath,
    [string]$BootstrapRoleArn,
    [string]$CatalogRuntimeRoleArn,
    [string]$DomainName,
    [ValidatePattern('^[a-z0-9][a-z0-9_-]{0,127}$')][string]$IndexName = 'fcg-games'
)
$ErrorActionPreference = 'Stop'
function Assert-Role([string]$Arn) {
    if ($Arn -cnotmatch ('^arn:aws:iam::' + $ExpectedAccountId + ':role/[A-Za-z0-9+=,.@_/-]+$')) {
        throw 'Provide an existing IAM role ARN in the expected account, not an STS session ARN.'
    }
}
$absoluteOutput = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath (Split-Path $absoluteOutput -Parent) -PathType Container)) { throw 'Output directory must exist.' }
$values = [ordered]@{}
if ($ProjectName -cnotmatch '^[a-z][a-z0-9-]{1,18}[a-z0-9]$') { throw 'ProjectName must use lowercase canonical notation.' }
if ($IndexName -cnotmatch '^[a-z0-9][a-z0-9_-]{0,127}$') { throw 'IndexName must use lowercase canonical notation.' }
if ($Stage -eq 'network-compute') {
    Assert-Role $AdminRoleArn
    if ($AvailabilityZoneA -cnotmatch '^us-east-2[a-z]$' -or $AvailabilityZoneB -cnotmatch '^us-east-2[a-z]$' -or $AvailabilityZoneA -eq $AvailabilityZoneB) {
        throw 'Provide two distinct, verified standard Ohio availability zones.'
    }
    if ($AdminCidrIPv4 -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/32$') { throw 'Operator CIDR must be a single public IPv4 /32.' }
    $octets = @(1..4 | ForEach-Object { [int]$Matches[$_] })
    if (@($octets | Where-Object { $_ -gt 255 }).Count -gt 0) { throw 'Invalid IPv4 address.' }
    if (($octets -join '.') + '/32' -ne $AdminCidrIPv4) { throw 'Use canonical IPv4 notation without leading zeros.' }
    $a=$octets[0]; $b=$octets[1]; $c=$octets[2]
    if ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224 -or ($a -eq 169 -and $b -eq 254) `
        -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168) `
        -or ($a -eq 100 -and $b -ge 64 -and $b -le 127) -or ($a -eq 198 -and $b -in @(18,19)) `
        -or ($a -eq 192 -and $b -eq 0) -or ($a -eq 198 -and $b -eq 51 -and $c -eq 100) `
        -or ($a -eq 203 -and $b -eq 0 -and $c -eq 113)) { throw 'Operator CIDR must be a real public egress address, not private/reserved/documentation space.' }
    $values.ProjectName=$ProjectName; $values.AdminRoleArn=$AdminRoleArn; $values.AdminCidrIPv4=$AdminCidrIPv4
    $values.AvailabilityZoneA=$AvailabilityZoneA; $values.AvailabilityZoneB=$AvailabilityZoneB
}
else {
    Assert-Role $BootstrapRoleArn
    Assert-Role $CatalogRuntimeRoleArn
    if ([string]::IsNullOrWhiteSpace($NetworkOutputsPath)) { throw 'NetworkOutputsPath must contain the real describe-stacks response.' }
    $response = Get-Content -LiteralPath $NetworkOutputsPath -Raw | ConvertFrom-Json
    if (@($response.Stacks).Count -ne 1 -or $response.Stacks[0].StackId -notmatch ('^arn:aws:cloudformation:us-east-2:'+$ExpectedAccountId+':stack/')) { throw 'Expected one Ohio stack from the intended account.' }
    $outputs=@{}
    foreach ($output in $response.Stacks[0].Outputs) {
        if ($outputs.ContainsKey($output.OutputKey)) { throw 'Duplicate stack output.' }
        $outputs[$output.OutputKey]=$output.OutputValue
    }
    foreach ($entry in @(@('VpcId','^vpc-([0-9a-f]{8}|[0-9a-f]{17})$'),@('PublicSubnetAId','^subnet-([0-9a-f]{8}|[0-9a-f]{17})$'),@('ClusterSecurityGroupId','^sg-([0-9a-f]{8}|[0-9a-f]{17})$'))) {
        if (-not $outputs.ContainsKey($entry[0]) -or $outputs[$entry[0]] -notmatch $entry[1]) { throw "Missing or invalid network output: $($entry[0])." }
        $values[$entry[0]]=$outputs[$entry[0]]
    }
    if ([string]::IsNullOrWhiteSpace($DomainName)) { $DomainName="$ProjectName-search" }
    if ($DomainName -cnotmatch '^[a-z][a-z0-9-]{2,27}$') { throw 'DomainName must be 3-28 lowercase letters, digits or hyphens and start with a letter.' }
    $values.DomainName=$DomainName; $values.IndexName=$IndexName; $values.BootstrapRoleArn=$BootstrapRoleArn
    $values.CatalogRuntimeRoleArn=$CatalogRuntimeRoleArn
}
$parameters = @($values.GetEnumerator() | ForEach-Object { [ordered]@{ParameterKey=$_.Key; ParameterValue=[string]$_.Value} })
[IO.File]::WriteAllText($absoluteOutput, (ConvertTo-Json -InputObject $parameters -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Output "Parameters written locally for $Stage. No AWS API was called; verify all inputs before provisioning."
