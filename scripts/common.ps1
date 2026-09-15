$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$utf8 = New-Object Text.UTF8Encoding($false)
$cluster = 'fcg-fase3'
$config = Join-Path $repo 'fase3.kubeconfig.local.yaml'
$kube = @('--kubeconfig', $config, '--context', 'kind-fcg-fase3', '-n', 'fcg')
function Check-Exit([string]$Step) { if ($LASTEXITCODE -ne 0) { throw "$Step failed." } }
function Resolve-Tool([string]$Name, [string]$Fallback) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
    throw "Install $Name and add it to PATH; see README."
}
function Write-LocalJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), $utf8)
}
function Wait-Until([scriptblock]$Condition, [string]$Description, [int]$Seconds = 180) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Seconds 2 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout: $Description"
}
function Aws([string]$Service, [string]$Operation, [hashtable]$InputData) {
    $awsExe = Resolve-Tool aws (Join-Path $env:LOCALAPPDATA 'Programs/Amazon/AWSCLIV2/aws.exe')
    $path = Join-Path $repo ('aws-request-' + [guid]::NewGuid().ToString('N') + '.local.json')
    try {
        Write-LocalJson $path $InputData
        $raw = & $awsExe $Service $Operation --cli-input-json ('file://' + $path) --profile $Profile --region us-east-1 --output json --no-cli-pager
        Check-Exit "AWS $Service $Operation"
        if ($raw) { return ($raw -join "`n") | ConvertFrom-Json }
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
}
function Assert-Account([string]$Expected) {
    $identity = Aws sts get-caller-identity @{}
    if ($identity.Account -ne $Expected -or !$identity.Arn.EndsWith(':user/fiap-fase3-cli')) { throw 'Unexpected AWS account or deploy user. Review README IAM setup.' }
}
