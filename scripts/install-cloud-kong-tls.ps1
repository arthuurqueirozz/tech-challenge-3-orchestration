# Called only after Start-CloudTunnel verifies the AWS account and EKS target.
. (Join-Path $PSScriptRoot 'cloud-tunnel.ps1')

function Install-CloudKongTls {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State, [Parameter(Mandatory=$true)][string]$StatePath,
        [Parameter(Mandatory=$true)][string]$Kubeconfig, [string]$Context='fcg-fase4')
    Assert-CloudWindow -State $State
    $privateRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))
    $certificateDirectory = [IO.Path]::GetFullPath([string]$State.CertificatePrivateDirectory)
    if (-not $certificateDirectory.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $certificateDirectory -Leaf) -cnotmatch '^acme-ip-[a-f0-9]{12}$') { throw 'Expected the retained private certificate directory beside the state.' }
    $ancestor = $certificateDirectory
    while ($ancestor) {
        if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw 'TLS private material must remain outside Git.' }
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'TLS private paths must not traverse links.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    foreach ($file in @('cert.pem','chain.pem','privkey.pem')) {
        $item = Get-Item -LiteralPath (Join-Path $certificateDirectory $file)
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected regular retained PEM files.' }
    }
    $identity = Invoke-CloudAws -Arguments @('sts','get-caller-identity') -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($identity.Account -cne $State.AccountId) { throw 'AWS account differs from private state.' }
    $arnPrefix = 'arn:aws:acm:{0}:{1}:certificate/' -f $State.Region,$State.AccountId
    if (-not ([string]$State.CertificateArn).StartsWith($arnPrefix,[StringComparison]::Ordinal) -or
        $State.CertificateFingerprintSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Expected verified production certificate metadata.' }
    $saved = Invoke-CloudAws -Arguments @('acm','describe-certificate','--certificate-arn',$State.CertificateArn) -Profile $State.AwsProfile -Region $State.Region -AsJson
    if ($saved.Certificate.Status -cne 'ISSUED' -or @($saved.Certificate.SubjectAlternativeNames) -notcontains $State.GatewayOutputs.PublicIp) { throw 'Saved certificate does not cover the gateway IP.' }
    $certificatePem = [IO.File]::ReadAllText((Join-Path $certificateDirectory 'cert.pem'))
    $chainPem = [IO.File]::ReadAllText((Join-Path $certificateDirectory 'chain.pem'))
    $keyPem = [IO.File]::ReadAllText((Join-Path $certificateDirectory 'privkey.pem'))
    $pattern = '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----'
    $leafMatch = [regex]::Match($certificatePem,$pattern)
    if (-not $leafMatch.Success) { throw 'Invalid retained certificate PEM.' }
    $leaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String(($leafMatch.Groups[1].Value -replace '\s','')))
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($leaf.RawData))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($fingerprint -cne $State.CertificateFingerprintSha256 -or $leaf.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
            $leaf.NotAfter.ToUniversalTime() -lt [DateTimeOffset]::Parse($State.WindowEndUtc).UtcDateTime) { throw 'Retained certificate fingerprint or validity differs from the approved window.' }
        foreach ($match in [regex]::Matches($chainPem,$pattern)) {
            $intermediate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String(($match.Groups[1].Value -replace '\s','')))
            $null = $chain.ChainPolicy.ExtraStore.Add($intermediate)
        }
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        if (-not $chain.Build($leaf)) { throw 'Retained production certificate chain is not trusted.' }
    } finally { $chain.Dispose(); $leaf.Dispose() }
    # Existing pinned Certbot supplies cryptography; no network or credentials in argv.
    $validator = @'
import datetime, hashlib, ipaddress, sys
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import NameOID
base = Path('/input')
leaf = x509.load_pem_x509_certificate((base / 'cert.pem').read_bytes())
key = serialization.load_pem_private_key((base / 'privkey.pem').read_bytes(), password=None)
assert leaf.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) == key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
assert ipaddress.ip_address(sys.argv[1]) in leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.IPAddress)
assert leaf.issuer.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)[0].value == "Let's Encrypt"
assert 'staging' not in leaf.issuer.rfc4514_string().lower()
assert leaf.not_valid_before_utc <= datetime.datetime.now(datetime.timezone.utc)
assert leaf.not_valid_after_utc >= datetime.datetime.fromisoformat(sys.argv[2].replace('Z', '+00:00'))
assert hashlib.sha256(leaf.public_bytes(serialization.Encoding.DER)).hexdigest() == sys.argv[3]
print('TLS_MATERIAL_VALIDATED')
'@
    $validatorPath = Join-Path $certificateDirectory 'validate-kong-tls.local.py'
    $manifestPath = Join-Path $certificateDirectory 'kong-tls.local.json'
    try {
        Write-CloudPrivateText -Path $validatorPath -Text $validator.Replace("`r`n","`n")
        $docker = @(Get-Command docker -CommandType Application -ErrorAction Stop)[0].Source
        $arguments = @('run','--rm','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges','--entrypoint','python')
        foreach ($file in @('cert.pem','privkey.pem','validate-kong-tls.local.py')) { $arguments += @('--mount',('type=bind,source='+(Join-Path $certificateDirectory $file)+',target=/input/'+$file+',readonly')) }
        $arguments += @('certbot/certbot@sha256:91808b1b417f72daa57763337e6080c6b90c49b409d06778924f9a9d4affde02','/input/validate-kong-tls.local.py',[string]$State.GatewayOutputs.PublicIp,[string]$State.WindowEndUtc,[string]$State.CertificateFingerprintSha256)
        $result = Invoke-CloudNative -Executable $docker -Arguments $arguments
        if ($result.Trim() -cne 'TLS_MATERIAL_VALIDATED') { throw 'Offline TLS key/IP validation did not complete.' }
        $data = @{}
        foreach ($entry in @{'tls.crt'=($certificatePem.Trim()+"`n"+$chainPem.Trim()+"`n");'tls.key'=$keyPem;'ssl-cert-path'='/etc/kong/tls/tls.crt';'ssl-key-path'='/etc/kong/tls/tls.key'}.GetEnumerator()) {
            $data[$entry.Key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($entry.Value))
        }
        $existing = Invoke-CloudKubectl -Arguments @('get','secrets','--field-selector','metadata.name=fcg-kong-tls') -Kubeconfig $Kubeconfig -Context $Context -Namespace 'fcg-platform' -AsJson
        if (@($existing.items).Count -gt 1) { throw 'Unexpected TLS Secret lookup result.' }
        if (@($existing.items).Count -eq 1) {
            foreach ($key in $data.Keys) { if ($existing.items[0].data.$key -cne $data[$key]) { throw 'Existing Kong TLS Secret differs; review explicit certificate renewal before replacing it.' } }
        }
        else {
            Write-CloudJson -Path $manifestPath -Value @{apiVersion='v1';kind='Secret';metadata=@{name='fcg-kong-tls';namespace='fcg-platform'};type='kubernetes.io/tls';data=$data}
            Assert-CloudWindow -State $State
            $null = Invoke-CloudKubectl -Arguments @('create','-f',$manifestPath) -Kubeconfig $Kubeconfig -Context $Context -Namespace 'fcg-platform'
        }
        Write-Host 'The retained trusted IP certificate and matching private key are installed in the Kong TLS Secret.'
    } finally {
        foreach ($path in @($validatorPath,$manifestPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }
}

function Assert-CloudKongTls {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][string]$Kubeconfig,[string]$Context='fcg-fase4')
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18443)
    try { $listener.Start() } finally { $listener.Stop() }
    $executable = @(Get-Command kubectl -CommandType Application -ErrorAction Stop)[0].Source
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable
    $arguments = @('--kubeconfig',$Kubeconfig,'--context',$Context,'--namespace','fcg-platform','port-forward','--address','127.0.0.1','service/kong','18443:8443')
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-CloudProcessArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    try {
        $connected = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
            $client = New-Object Net.Sockets.TcpClient
            try { $client.Connect('127.0.0.1',18443); $connected=$true; break } catch { $client.Dispose(); Start-Sleep -Milliseconds 500 }
        }
        if (-not $connected) { throw 'The private Kong TLS verification port did not become ready.' }
        $expectedFingerprint = [string]$State.CertificateFingerprintSha256
        $callback = [Net.Security.RemoteCertificateValidationCallback]{param($sender,$certificate,$chain,$errors)
            if ($errors -ne [Net.Security.SslPolicyErrors]::None) { return $false }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { return ([BitConverter]::ToString($sha.ComputeHash($certificate.GetRawCertData()))).Replace('-','').ToLowerInvariant() -ceq $expectedFingerprint } finally { $sha.Dispose() }
        }
        $stream = New-Object Net.Security.SslStream($client.GetStream(),$false,$callback)
        try { $stream.ReadTimeout=15000; $stream.WriteTimeout=15000; $stream.AuthenticateAsClient([string]$State.GatewayOutputs.PublicIp) }
        finally { $stream.Dispose(); $client.Dispose() }
        Write-Host 'Kong presented the saved production certificate with normal IP/chain verification over the private tunnel.'
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}
