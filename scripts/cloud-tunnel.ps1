. (Join-Path $PSScriptRoot 'cloud-common.ps1')

function ConvertTo-CloudProcessArgument([string]$Value) {
    # ProcessStartInfo.ArgumentList is unavailable on Windows PowerShell 5.1.
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Start-CloudTunnel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State,
        [ValidateSet('Eks','Search')][string]$Purpose = 'Eks',
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [string]$Kubeconfig, [string]$Context = 'fcg-fase4')
    Assert-CloudWindow -State $State
    $null = Get-Command session-manager-plugin -ErrorAction Stop
    $executable = $env:FCG_AWS_EXECUTABLE
    if (-not $executable) { $executable = 'aws' }
    $executable = (Get-Command $executable -CommandType Application -ErrorAction Stop).Source
    $env:PATH = (Split-Path $executable -Parent) + [IO.Path]::PathSeparator + $env:PATH
    $identity = Invoke-CloudAws -Arguments @('sts','get-caller-identity') -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($identity.Account -cne $State.AccountId) { throw 'AWS identity does not match the intended account.' }
    if ($State.NodeInstanceId -cnotmatch '^i-([0-9a-f]{8}|[0-9a-f]{17})$') { throw 'Verify the current managed node instance before opening a tunnel.' }
    $endpoint = if ($Purpose -eq 'Eks') { [uri]$State.NetworkOutputs.ClusterEndpoint } else { [uri]$State.SearchOutputs.DomainEndpoint }
    if ($endpoint.Scheme -ne 'https' -or $endpoint.Port -ne 443 -or $endpoint.UserInfo -or $endpoint.PathAndQuery -ne '/') { throw 'Expected a verified HTTPS endpoint.' }
    $port = if ($Purpose -eq 'Eks') { 8443 } else { 9443 }
    $document = if ($Purpose -eq 'Eks') { $State.DeployOutputs.EksTunnelDocumentName } else { $State.DeployOutputs.SearchTunnelDocumentName }
    $expectedDocument = $State.ProjectName + $(if ($Purpose -eq 'Eks') { '-eks-tunnel' } else { '-search-operator-tunnel' })
    if ($document -cne $expectedDocument) { throw 'The SSM tunnel document does not match the project and purpose.' }
    $directory = [IO.Path]::GetFullPath($DirectoryPath)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Create the private tunnel directory first.' }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
    try { $listener.Start() } catch { throw 'The tunnel port is in use; inspect the existing process before continuing.' } finally { $listener.Stop() }
    $id = [Guid]::NewGuid().ToString('N')
    $parameterPath = Join-Path $directory "$id.parameters.local.json"
    $outPath = Join-Path $directory "$id.stdout.local.log"
    $errorPath = Join-Path $directory "$id.stderr.local.log"
    Write-CloudJson -Path $parameterPath -Value @{ localPortNumber = @([string]$port) }
    Write-CloudPrivateText -Path $outPath -Text ''
    Write-CloudPrivateText -Path $errorPath -Text ''
    $arguments = @('ssm','start-session','--target',$State.NodeInstanceId,'--document-name',$document,
        '--parameters',('file://' + $parameterPath),'--region',$State.Region,'--no-cli-pager')
    if ($State.AwsProfile) { $arguments += @('--profile', $State.AwsProfile) }
    $start = @{ FilePath = $executable; ArgumentList = (($arguments | ForEach-Object { ConvertTo-CloudProcessArgument $_ }) -join ' ');
        PassThru = $true; RedirectStandardOutput = $outPath; RedirectStandardError = $errorPath }
    if ($env:OS -eq 'Windows_NT') { $start.WindowStyle = 'Hidden' }
    $process = $null
    $handle = [pscustomobject]@{ Process = $null; State = $State; OutPath = $outPath; Paths = @($parameterPath,$outPath,$errorPath); Port = $port; Kubeconfig = $Kubeconfig; Context = $Context }
    try {
        $process = Start-Process @start
        $handle.Process = $process
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
            $client = New-Object Net.Sockets.TcpClient
            try { $client.Connect('127.0.0.1', $port); $ready = $true; break } catch { } finally { $client.Dispose() }
            Start-Sleep -Milliseconds 500
            $process.Refresh()
        }
        if (-not $ready) { throw 'The private tunnel did not become ready. Check SSM node status, document and session permissions.' }
        if ($Purpose -eq 'Eks') {
            if ([string]::IsNullOrWhiteSpace($Kubeconfig)) { throw 'An isolated Kubeconfig is required for an EKS tunnel.' }
            $cluster = Invoke-CloudAws -Arguments @('eks','describe-cluster','--name',$State.NetworkOutputs.ClusterName) -Profile $State.AwsProfile -Region $State.Region -AsJson
            if ($cluster.cluster.endpoint -cne $endpoint.AbsoluteUri.TrimEnd('/') -or $cluster.cluster.arn -notlike "arn:aws:eks:$($State.Region):$($State.AccountId):cluster/*") { throw 'EKS endpoint/account differs from the verified state.' }
            Write-CloudPrivateText -Path $Kubeconfig -Text ''
            $null = Invoke-CloudAws -Arguments @('eks','update-kubeconfig','--name',$State.NetworkOutputs.ClusterName,'--alias',$Context,'--kubeconfig',$Kubeconfig) -Profile $State.AwsProfile -Region $State.Region
            $configuration = Invoke-CloudKubectl -Arguments @('config','view','--minify','--raw') -Kubeconfig $Kubeconfig -Context $Context -AsJson
            if (@($configuration.clusters).Count -ne 1 -or $configuration.clusters[0].cluster.'certificate-authority-data' -cne $cluster.cluster.certificateAuthority.data) { throw 'EKS kubeconfig CA differs from DescribeCluster.' }
            $name = $configuration.clusters[0].name
            $null = Invoke-CloudKubectl -Arguments @('config','set-cluster',$name,'--server',"https://127.0.0.1:$port",'--tls-server-name',$endpoint.DnsSafeHost) -Kubeconfig $Kubeconfig -Context $Context
            Protect-CloudFile -Path $Kubeconfig
            $null = Invoke-CloudKubectl -Arguments @('get','--raw','/version') -Kubeconfig $Kubeconfig -Context $Context
        }
        return $handle
    }
    catch { Stop-CloudTunnel -Handle $handle; throw }
}

function Stop-CloudTunnel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Handle)
    try {
        if (Test-Path -LiteralPath $Handle.OutPath -PathType Leaf) {
            $log = Get-Content -LiteralPath $Handle.OutPath -Raw -ErrorAction SilentlyContinue
            if ($log -match 'Starting session with SessionId:\s*([A-Za-z0-9_@.=-]+)') {
                $sessionId = $Matches[1]
                $null = Invoke-CloudAws -Arguments @('ssm','terminate-session','--session-id',$sessionId) -Profile $Handle.State.AwsProfile -Region $Handle.State.Region
            }
        }
    }
    catch { Write-Warning 'The tunnel session could not be terminated remotely; it will expire under its SSM limits.' }
    finally {
        if ($Handle.Process -and -not $Handle.Process.HasExited) {
            if ($env:OS -eq 'Windows_NT') {
                $null = & taskkill.exe /PID $Handle.Process.Id /T /F 2>&1
            }
            else {
                # .NET on the Linux runner can terminate only this process and its children.
                $Handle.Process.Kill($true)
            }
        }
        foreach ($path in $Handle.Paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
    }
}
