[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Kubeconfig,
    [ValidateNotNullOrEmpty()][string]$Context = 'fcg-fase4',
    [ValidateRange(300, 1200)][int]$TimeoutSeconds = 900,
    [string]$AwsExecutable = $env:FCG_AWS_EXECUTABLE
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')
if ($AwsExecutable) { $env:FCG_AWS_EXECUTABLE = $AwsExecutable }
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state

# Certbot v5.9.0 linux/amd64; registry manifest verified 2026-11-11.
# https://hub.docker.com/layers/certbot/certbot/amd64-v5.9.0/images/sha256-91808b1b417f72daa57763337e6080c6b90c49b409d06778924f9a9d4affde02
# https://letsencrypt.org/2026/03/11/shorter-certs-certbot.html
$certbotImage = 'certbot/certbot@sha256:91808b1b417f72daa57763337e6080c6b90c49b409d06778924f9a9d4affde02'
$holdSeconds = 600

function Invoke-CertificateAws {
    param([string[]]$Arguments, [switch]$AsJson)
    return Invoke-CloudAws -Arguments $Arguments -Profile $state.AwsProfile -Region $state.Region -AsJson:$AsJson
}
function Invoke-SolverKubectl {
    param([string[]]$Arguments, [switch]$AsJson)
    return Invoke-CloudKubectl -Arguments $Arguments -Kubeconfig $Kubeconfig -Context $Context -Namespace 'fcg-platform' -AsJson:$AsJson
}
function Set-CertificateState {
    param([string]$Name, [object]$Value)
    $state | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}
function Assert-CertificateChain {
    param([string]$CertificatePem, [string]$ChainPem, [string]$ExpectedFingerprint)
    $pattern = '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----'
    $leafMatch = [regex]::Match($CertificatePem, $pattern)
    if (-not $leafMatch.Success) { throw 'The extracted leaf certificate is not valid PEM.' }
    $leaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String(($leafMatch.Groups[1].Value -replace '\s', '')))
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($leaf.RawData))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($ExpectedFingerprint -and $fingerprint -cne $ExpectedFingerprint) { throw 'The extracted certificate changed after validation.' }
        if ($leaf.Issuer -notmatch "O=Let's Encrypt" -or $leaf.Issuer -match '(?i)staging|pretend|fake' -or
            $leaf.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
            $leaf.NotAfter.ToUniversalTime() -lt [DateTimeOffset]::Parse($state.WindowEndUtc).UtcDateTime) {
            throw 'The production certificate issuer/validity does not cover the approved window.'
        }
        foreach ($match in [regex]::Matches($ChainPem, $pattern)) {
            $intermediate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String(($match.Groups[1].Value -replace '\s', '')))
            $null = $chain.ChainPolicy.ExtraStore.Add($intermediate)
        }
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        if (-not $chain.Build($leaf)) { throw 'The production certificate chain is not trusted by this operator system.' }
        return $leaf.NotAfter.ToUniversalTime().ToString('o')
    }
    finally { $chain.Dispose(); $leaf.Dispose() }
}

$identity = Invoke-CertificateAws -Arguments @('sts', 'get-caller-identity') -AsJson
if ($identity.Account -cne $state.AccountId) { throw 'The authenticated AWS account differs from private state.' }
$remote = Invoke-CertificateAws -Arguments @('eks', 'describe-cluster', '--name', $state.NetworkOutputs.ClusterName) -AsJson
if (-not $remote.cluster.certificateAuthority.data -or $remote.cluster.endpoint -cne $state.NetworkOutputs.ClusterEndpoint) {
    throw 'The live EKS endpoint/CA does not match the intended cluster.'
}
$configuration = Invoke-SolverKubectl -Arguments @('config', 'view', '--minify', '--raw') -AsJson
if (@($configuration.clusters).Count -ne 1) { throw 'The selected context must resolve to one verified EKS cluster.' }
$cluster = $configuration.clusters[0].cluster
$expected = [uri]$remote.cluster.endpoint
$server = [uri]$cluster.server
$direct = $server.AbsoluteUri.TrimEnd('/') -ceq $expected.AbsoluteUri.TrimEnd('/')
$tunnel = $server.Scheme -eq 'https' -and $server.Host -in @('127.0.0.1', 'localhost', '[::1]', '::1') -and $server.AbsolutePath -eq '/' -and $cluster.'tls-server-name' -ceq $expected.Host
if ($cluster.'insecure-skip-tls-verify' -or $cluster.'certificate-authority-data' -cne $remote.cluster.certificateAuthority.data -or
    (-not $direct -and -not $tunnel) -or $server.UserInfo -or $server.Query -or $server.Fragment -or
    ($direct -and $cluster.'tls-server-name' -and $cluster.'tls-server-name' -cne $expected.Host)) {
    throw 'The kubeconfig must verify the EKS CA and target, including TLS server name for a local tunnel.'
}

$publicIp = [string]$state.GatewayOutputs.PublicIp
$parsedIp = $null
if (-not [Net.IPAddress]::TryParse($publicIp, [ref]$parsedIp) -or
    $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsedIp.ToString() -cne $publicIp) {
    throw 'A real canonical IPv4 output from the gateway stack is required.'
}
if ($state.CertificateArn) {
    $arnPrefix = 'arn:aws:acm:{0}:{1}:certificate/' -f $state.Region, $state.AccountId
    if (-not $state.CertificateArn.StartsWith($arnPrefix, [StringComparison]::Ordinal)) { throw 'The saved ACM certificate belongs to a different account/region.' }
    $saved = Invoke-CertificateAws -Arguments @('acm', 'describe-certificate', '--certificate-arn', $state.CertificateArn) -AsJson
    if ($saved.Certificate.Status -cne 'ISSUED' -or @($saved.Certificate.SubjectAlternativeNames) -notcontains $publicIp) {
        throw 'The saved ACM certificate is not issued for the gateway IP; review it explicitly before replacement.'
    }
    $pem = Invoke-CertificateAws -Arguments @('acm', 'get-certificate', '--certificate-arn', $state.CertificateArn) -AsJson
    $null = Assert-CertificateChain -CertificatePem $pem.Certificate -ChainPem $pem.CertificateChain
    Write-Host 'The saved production ACM certificate remains trusted and covers the approved window; no new issuance was requested.'
    return
}
if ($state.GatewayOutputs.HttpChallengeEnabled -cne 'true') { throw 'Run GatewayChallenge first; only the ACME HTTP route may be enabled.' }
if (([DateTimeOffset]::Parse($state.WindowEndUtc) - [DateTimeOffset]::UtcNow).TotalSeconds -lt ($TimeoutSeconds + $holdSeconds + 120)) {
    throw 'The remaining approved window is too short for issuance and protected extraction.'
}
$loadBalancer = Invoke-CertificateAws -Arguments @('elbv2', 'describe-load-balancers', '--load-balancer-arns', $state.GatewayOutputs.LoadBalancerArn) -AsJson
$addresses = @($loadBalancer.LoadBalancers | ForEach-Object { $_.AvailabilityZones } | ForEach-Object { $_.LoadBalancerAddresses } | ForEach-Object { $_.IpAddress })
if (@($loadBalancer.LoadBalancers).Count -ne 1 -or $addresses -notcontains $publicIp) { throw 'The gateway public IP is not attached to the expected load balancer.' }
$listeners = Invoke-CertificateAws -Arguments @('elbv2', 'describe-listeners', '--load-balancer-arn', $state.GatewayOutputs.LoadBalancerArn) -AsJson
$http = @($listeners.Listeners | Where-Object { $_.Port -eq 80 -and $_.Protocol -eq 'TCP' })
if ($http.Count -ne 1 -or @($http[0].DefaultActions | Where-Object { $_.Type -eq 'forward' -and $_.TargetGroupArn -ceq $state.GatewayOutputs.TargetGroupArn }).Count -ne 1) {
    throw 'The HTTP challenge listener must forward only to the expected Kong target group.'
}
$kongList = Invoke-SolverKubectl -Arguments @('get', 'secrets', '--field-selector', 'metadata.name=fcg-kong-config') -AsJson
if (@($kongList.items).Count -ne 1) { throw 'The existing ACME-only Kong configuration is required.' }
try { $kong = ConvertFrom-CloudJson -Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kongList.items[0].data.'kong.json'))) }
catch { throw 'The existing Kong configuration could not be verified safely.' }
$services = @($kong.services)
$routes = if ($services.Count -eq 1) { @($services[0].routes) } else { @() }
if ($services.Count -ne 1 -or $services[0].name -cne 'acme-only' -or $services[0].url -cne 'http://acme-solver.fcg-platform.svc.cluster.local:8089' -or
    $routes.Count -ne 1 -or @($routes[0].methods).Count -ne 1 -or $routes[0].methods[0] -cne 'GET' -or
    @($routes[0].paths).Count -ne 1 -or $routes[0].paths[0] -cne '~^/.well-known/acme-challenge/[A-Za-z0-9_-]+$' -or $routes[0].strip_path -ne $false -or
    @($kong.PSObject.Properties.Name | Where-Object { $_ -notin @('_format_version', '_transform', 'services') }).Count -gt 0) {
    throw 'Kong must contain only the reviewed ACME GET route before certificate issuance.'
}
$solverServices = Invoke-SolverKubectl -Arguments @('get', 'services', '--field-selector', 'metadata.name=acme-solver') -AsJson
if (@($solverServices.items).Count -ne 0) { throw 'An acme-solver Service already exists; recover its invocation rather than replacing it.' }

$jobName = 'acme-ip-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$privateDirectory = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))) $jobName
$ancestor = $privateDirectory
while ($ancestor) {
    if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw 'Certificate material must remain outside Git working trees.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$null = New-Item -ItemType Directory -Path $privateDirectory
Protect-CloudDirectory -Path $privateDirectory
$manifestPath = Join-Path $privateDirectory 'solver.local.json'
$labels = @{ 'app.kubernetes.io/part-of' = 'fcg'; 'fcg.dev/operation' = 'acme-ip'; 'fcg.dev/acme-job' = $jobName }
$service = @{ apiVersion = 'v1'; kind = 'Service'; metadata = @{ name = 'acme-solver'; namespace = 'fcg-platform'; labels = $labels }; spec = @{
    type = 'ClusterIP'; selector = @{ 'fcg.dev/acme-job' = $jobName }; ports = @(@{ name = 'http'; port = 8089; targetPort = 8089 })
} }
$shell = @'
set -eu
umask 077
mkdir -p /acme/staging/config /acme/staging/work /acme/staging/logs /acme/production/config /acme/production/work /acme/production/logs
fail() { touch /acme/failed; echo 'ACME issuance failed; private diagnostics remain in the protected account archive.' >&2; sleep 600; exit 1; }
certbot --version 2>/dev/null | grep -Fx 'certbot 5.9.0' >/dev/null || fail
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --preferred-profile shortlived --preferred-challenges http --http-01-address 0.0.0.0 --http-01-port 8089 --key-type rsa --rsa-key-size 2048 --ip-address "$PUBLIC_IP" --cert-name fcg-ip-staging --staging --config-dir /acme/staging/config --work-dir /acme/staging/work --logs-dir /acme/staging/logs >/acme/staging/output.log 2>&1 || fail
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --preferred-profile shortlived --preferred-challenges http --http-01-address 0.0.0.0 --http-01-port 8089 --key-type rsa --rsa-key-size 2048 --ip-address "$PUBLIC_IP" --cert-name fcg-ip --server https://acme-v02.api.letsencrypt.org/directory --config-dir /acme/production/config --work-dir /acme/production/work --logs-dir /acme/production/logs >/acme/production/output.log 2>&1 || fail
touch /acme/ready
echo 'Staging and production certificates issued; waiting for protected extraction.'
sleep 600
'@
$job = @{ apiVersion = 'batch/v1'; kind = 'Job'; metadata = @{ name = $jobName; namespace = 'fcg-platform'; labels = $labels }; spec = @{
    backoffLimit = 0; activeDeadlineSeconds = $TimeoutSeconds + $holdSeconds + 120
    template = @{ metadata = @{ labels = $labels }; spec = @{
        restartPolicy = 'Never'; serviceAccountName = 'kong'; automountServiceAccountToken = $false; terminationGracePeriodSeconds = 15
        nodeSelector = @{ 'kubernetes.io/arch' = 'amd64' }
        securityContext = @{ runAsUser = 1000; runAsGroup = 1000; runAsNonRoot = $true; fsGroup = 1000 }
        containers = @(@{ name = 'certbot'; image = $certbotImage; imagePullPolicy = 'IfNotPresent'; command = @('/bin/sh', '-c', $shell)
            env = @(@{ name = 'PUBLIC_IP'; value = $publicIp }, @{ name = 'WINDOW_END_UTC'; value = $state.WindowEndUtc }, @{ name = 'PYTHONDONTWRITEBYTECODE'; value = '1' })
            ports = @(@{ name = 'http'; containerPort = 8089 })
            resources = @{ requests = @{ cpu = '50m'; memory = '96Mi' }; limits = @{ cpu = '500m'; memory = '256Mi' } }
            securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') }; seccompProfile = @{ type = 'RuntimeDefault' } }
            volumeMounts = @(@{ name = 'acme'; mountPath = '/acme' })
        })
        volumes = @(@{ name = 'acme'; emptyDir = @{ sizeLimit = '64Mi' } })
    } }
} }
$metadataPython = @'
import datetime, hashlib, ipaddress, json, os
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import NameOID
base = Path('/acme/production/config/live/fcg-ip')
leaf = x509.load_pem_x509_certificate((base / 'cert.pem').read_bytes())
key = serialization.load_pem_private_key((base / 'privkey.pem').read_bytes(), password=None)
assert leaf.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) == key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
assert ipaddress.ip_address(os.environ['PUBLIC_IP']) in leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.IPAddress)
issuer = leaf.issuer.rfc4514_string()
assert leaf.issuer.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)[0].value == 'Let\'s Encrypt'
assert 'staging' not in issuer.lower()
end = datetime.datetime.fromisoformat(os.environ['WINDOW_END_UTC'].replace('Z', '+00:00'))
assert leaf.not_valid_after_utc >= end
assert leaf.not_valid_before_utc <= datetime.datetime.now(datetime.timezone.utc)
print(json.dumps({'ip': os.environ['PUBLIC_IP'], 'notAfterUtc': leaf.not_valid_after_utc.isoformat(), 'fingerprintSha256': hashlib.sha256(leaf.public_bytes(serialization.Encoding.DER)).hexdigest()}))
'@
$archivePython = @'
import base64, io, tarfile
from pathlib import Path
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
    for name in ['staging', 'production']:
        path = Path('/acme') / name
        if path.exists():
            archive.add(str(path), arcname=name, recursive=True)
print(base64.b64encode(buffer.getvalue()).decode('ascii'))
'@
$createdService = $false
$createdJob = $false
$issuanceStopped = $false
$podName = $null
$archiveSaved = $false
try {
    Write-CloudJson -Path $manifestPath -Value $service
    Assert-CloudWindow -State $state
    $null = Invoke-SolverKubectl -Arguments @('create', '-f', $manifestPath)
    $createdService = $true
    Write-CloudJson -Path $manifestPath -Value $job
    Assert-CloudWindow -State $state
    $null = Invoke-SolverKubectl -Arguments @('create', '-f', $manifestPath)
    $createdJob = $true
    Write-Host "Waiting for ACME staging/production Job $jobName."
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $ready = $false
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pods = Invoke-SolverKubectl -Arguments @('get', 'pods', '-l', "job-name=$jobName") -AsJson
        if (@($pods.items).Count -gt 1) { throw 'The ACME invocation resolved to an ambiguous pod list.' }
        if (@($pods.items).Count -eq 1) {
            $podName = $pods.items[0].metadata.name
            if ($pods.items[0].status.phase -in @('Failed', 'Succeeded')) { throw 'The ACME pod stopped before protected extraction.' }
            if ($pods.items[0].status.phase -eq 'Running') {
                $marker = Invoke-SolverKubectl -Arguments @('exec', $podName, '--', '/bin/sh', '-c', 'if test -f /acme/ready; then echo ready; elif test -f /acme/failed; then echo failed; else echo waiting; fi')
                if ($marker.Trim() -in @('ready', 'failed')) {
                    $issuanceStopped = $true
                    $archive = Invoke-SolverKubectl -Arguments @('exec', $podName, '--', 'python', '-c', $archivePython)
                    $archivePath = Join-Path $privateDirectory 'acme-accounts.tar.gz.b64'
                    Write-CloudPrivateText -Path $archivePath -Text ($archive.Trim() + [Environment]::NewLine)
                    Set-CertificateState -Name 'AcmeArchivePath' -Value $archivePath
                    Write-CloudJson -Path $StatePath -Value $state
                    $archiveSaved = $true
                    if ($marker.Trim() -eq 'failed') { throw 'ACME staging or production issuance failed. The private account archive was preserved; do not repeat production blindly.' }
                    $ready = $true
                    break
                }
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'ACME issuance timed out; the bounded Job and its solver Service remain for controlled recovery.' }
    $metadataJson = Invoke-SolverKubectl -Arguments @('exec', $podName, '--', 'python', '-c', $metadataPython)
    try { $metadata = ConvertFrom-CloudJson -Json $metadataJson } catch { throw 'The certificate validation result was not valid JSON.' }
    if ($metadata.ip -cne $publicIp -or $metadata.fingerprintSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Certificate IP/key validation did not return the expected metadata.' }
    $paths = @{}
    foreach ($file in @('cert.pem', 'chain.pem', 'privkey.pem')) {
        $content = Invoke-SolverKubectl -Arguments @('exec', $podName, '--', 'cat', "/acme/production/config/live/fcg-ip/$file")
        $path = Join-Path $privateDirectory $file
        Write-CloudPrivateText -Path $path -Text ($content + [Environment]::NewLine)
        $paths[$file] = $path
    }
    $notAfter = Assert-CertificateChain -CertificatePem (Get-Content -Raw -LiteralPath $paths['cert.pem']) -ChainPem (Get-Content -Raw -LiteralPath $paths['chain.pem']) -ExpectedFingerprint $metadata.fingerprintSha256
    Assert-CloudWindow -State $state
    $imported = Invoke-CertificateAws -Arguments @('acm', 'import-certificate', '--certificate', ('fileb://' + $paths['cert.pem']), '--certificate-chain', ('fileb://' + $paths['chain.pem']), '--private-key', ('fileb://' + $paths['privkey.pem']), '--tags', ('Key=Project,Value=' + $state.ProjectName)) -AsJson
    Write-CloudJson -Path (Join-Path $privateDirectory 'acm-import.local.json') -Value $imported
    $arnPrefix = 'arn:aws:acm:{0}:{1}:certificate/' -f $state.Region, $state.AccountId
    if (-not $imported.CertificateArn -or -not $imported.CertificateArn.StartsWith($arnPrefix, [StringComparison]::Ordinal)) { throw 'ACM did not return a certificate ARN in the intended account/region.' }
    Set-CertificateState -Name 'CertificateArn' -Value $imported.CertificateArn
    Set-CertificateState -Name 'CertificateNotAfterUtc' -Value $notAfter
    Set-CertificateState -Name 'CertificateFingerprintSha256' -Value $metadata.fingerprintSha256
    Set-CertificateState -Name 'CertificatePrivateDirectory' -Value $privateDirectory
    Write-CloudJson -Path $StatePath -Value $state
    Write-Host 'A trusted production IP certificate was imported into ACM and recorded privately. Run GatewayHttps to close HTTP before enabling business routes.'
}
finally {
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    if (-not $createdJob -or ($issuanceStopped -and $archiveSaved)) {
        if ($createdJob) { $null = Invoke-SolverKubectl -Arguments @('delete', 'job', $jobName, '--wait=true', '--timeout=30s') }
        if ($createdService) { $null = Invoke-SolverKubectl -Arguments @('delete', 'service', 'acme-solver', '--wait=true', '--timeout=30s') }
    }
    else {
        Write-Warning "ACME Job $jobName may still hold account material. Its deadline is finite; preserve/extract its private state before removing the invocation."
    }
}

