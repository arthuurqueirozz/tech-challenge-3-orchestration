# Shared helpers for the Fase 4 operator scripts. Dot-source this file.
function ConvertFrom-CloudJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Json)
    $command = Get-Command ConvertFrom-Json -CommandType Cmdlet
    if ($command.Parameters.ContainsKey('DateKind')) {
        # Preserve ISO strings across Windows PowerShell and the current Actions runner.
        return ($Json | ConvertFrom-Json -DateKind String -ErrorAction Stop)
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { throw 'Use Windows PowerShell 5.1 or PowerShell 7.5+ so JSON timestamps are preserved.' }
    return ($Json | ConvertFrom-Json -ErrorAction Stop)
}

function Protect-CloudFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Expected a regular private file.'
    }
    if ($env:OS -eq 'Windows_NT') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$item, $acl) }
    }
    else {
        & chmod 600 -- $item.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the private file.' }
    }
}

function Protect-CloudDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected a regular private directory.' }
    if ($env:OS -eq 'Windows_NT') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$item, $acl) }
    }
    else {
        & chmod 700 -- $item.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the private directory.' }
    }
}

function Write-CloudPrivateText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'Create the private output directory before writing a file.'
    }
    if (Test-Path -LiteralPath $fullPath) { Protect-CloudFile -Path $fullPath }
    $temporaryPath = Join-Path $directory ('.private-' + [Guid]::NewGuid().ToString('N'))
    try {
        # The file is empty until its ACL/mode is restricted. Never write then chmod.
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        Protect-CloudFile -Path $temporaryPath
        [IO.File]::WriteAllText($temporaryPath, $Text, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force -ErrorAction Stop
        Protect-CloudFile -Path $fullPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Write-CloudJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    Write-CloudPrivateText -Path $Path -Text $json
}

function Read-CloudState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    Protect-CloudFile -Path $Path
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($raw -notmatch '^\s*\{') { throw 'Expected an object.' }
        $state = ConvertFrom-CloudJson -Json $raw
        if ($state -isnot [pscustomobject]) { throw 'Expected one object.' }
    }
    catch { throw 'The private state file is not valid JSON.' }
    if ($state.SchemaVersion -ne 1 -or $state.AccountId -cnotmatch '^[0-9]{12}$' -or $state.Region -cne 'us-east-2' -or
        $state.ProjectName -cnotmatch '^[a-z][a-z0-9-]{1,18}[a-z0-9]$') {
        throw 'Fill the state account/project fields with verified AWS values (schema 1, Ohio).' 
    }
    return $state
}

function Assert-CloudWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [switch]$AllowAfterEnd)
    # This is the 120-hour window explicitly approved for this demonstration.
    $approvedStart = [DateTimeOffset]::Parse('2026-11-13T23:00:00Z')
    $approvedEnd = [DateTimeOffset]::Parse('2026-11-18T23:00:00Z')
    if ($State.WindowStartUtc -cne '2026-11-13T23:00:00Z' -or $State.WindowEndUtc -cne '2026-11-18T23:00:00Z') {
        throw 'The state must contain the approved 13-18 November 2026 UTC window.'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($now -lt $approvedStart -or (-not $AllowAfterEnd -and $now -ge $approvedEnd)) {
        throw 'AWS/Kubernetes changes are outside the approved demonstration window. Local preparation remains available.'
    }
}

function Invoke-CloudNative {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Executable, [string[]]$Arguments, [switch]$AsJson)
    # Capture both streams: provider responses may contain credentials or Secret data.
    # On failure expose only an exit code; do not copy the payload into a log/error.
    $ErrorActionPreference = 'Continue'
    $result = @(& $Executable @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Cloud command failed (exit $code). Its response was suppressed to protect private data." }
    $value = ($result | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($AsJson) {
        try { return (ConvertFrom-CloudJson -Json $value) }
        catch { throw 'Cloud command returned invalid JSON; its response was suppressed.' }
    }
    return $value
}

function Invoke-CloudAws {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [string]$Profile, [string]$Region = 'us-east-2', [switch]$AsJson)
    $executable = $env:FCG_AWS_EXECUTABLE
    if ([string]::IsNullOrWhiteSpace($executable)) { $executable = 'aws' }
    $executable = (Get-Command $executable -CommandType Application -ErrorAction Stop).Source
    $parameters = @($Arguments) + @('--region', $Region, '--no-cli-pager', '--output', 'json')
    # An absent profile intentionally uses the runner's short-lived environment credentials.
    if (-not [string]::IsNullOrWhiteSpace($Profile)) { $parameters += @('--profile', $Profile) }
    return Invoke-CloudNative -Executable $executable -Arguments $parameters -AsJson:$AsJson
}

function Invoke-CloudKubectl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Kubeconfig,
        [Parameter(Mandatory = $true)][string]$Context, [string]$Namespace, [switch]$AsJson)
    $executable = $env:FCG_KUBECTL_EXECUTABLE
    if ([string]::IsNullOrWhiteSpace($executable)) { $executable = 'kubectl' }
    $timeout = 60
    foreach ($argument in $Arguments) {
        if ($argument -match '^--timeout=([0-9]+)s$') { $timeout = [int]$Matches[1] + 30 }
    }
    $parameters = @('--kubeconfig', $Kubeconfig, '--context', $Context, "--request-timeout=$($timeout)s")
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) { $parameters += @('--namespace', $Namespace) }
    $parameters += $Arguments
    if ($AsJson) { $parameters += @('-o', 'json') }
    return Invoke-CloudNative -Executable $executable -Arguments $parameters -AsJson:$AsJson
}
