[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Discover','Network','Notifications','Runtime','Search','Access','Platform','SearchBootstrap','Apis','GatewayChallenge','Certificate','GatewayHttps')][string]$Stage,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [string]$AwsExecutable = $env:FCG_AWS_EXECUTABLE
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-tunnel.ps1')
if ($AwsExecutable) { $env:FCG_AWS_EXECUTABLE = $AwsExecutable }
if (-not $env:FCG_AWS_EXECUTABLE) { $env:FCG_AWS_EXECUTABLE = (Get-Command aws -CommandType Application -ErrorAction Stop).Source }
$state = Read-CloudState -Path $StatePath
$directory = Split-Path ([IO.Path]::GetFullPath($StatePath)) -Parent
$repo = Split-Path $PSScriptRoot -Parent
$siblings = Split-Path $repo -Parent
function Invoke-OperatorAws([string[]]$A, [switch]$Json) {
    Invoke-CloudAws -Arguments $A -Profile $script:state.AwsProfile -Region $script:state.Region -AsJson:$Json
}
function Save-State { Write-CloudJson -Path $script:StatePath -Value $script:state }
function Set-StateValue([string]$Name, $Value) { $script:state | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Assert-ObservationTime([object]$Value, [double]$MaxAgeHours, [string]$Name) {
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$') { throw "$Name requires an actual ISO-8601 observation time with timezone." }
    try { $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)).TotalHours }
    catch { throw "$Name contains an invalid observation time." }
    if ($age -lt 0 -or $age -gt $MaxAgeHours) { throw "$Name is future-dated or too old; repeat the actual verification." }
}
function Deploy-Stack([string]$Name, [string]$Template, [System.Collections.IDictionary]$Parameters, [string]$OutputProperty) {
    Assert-CloudWindow -State $script:state
    $a = @('cloudformation','deploy','--stack-name',"$($script:state.ProjectName)-$Name",'--template-file',$Template,
        '--capabilities','CAPABILITY_NAMED_IAM','CAPABILITY_AUTO_EXPAND','--no-fail-on-empty-changeset','--parameter-overrides')
    $a += @($Parameters.Keys | ForEach-Object { '{0}={1}' -f $_, $Parameters[$_] })
    $a += @('--tags',"Project=$($script:state.ProjectName)",'ManagedBy=CloudFormation')
    $null = Invoke-OperatorAws $a
    $response = Invoke-OperatorAws @('cloudformation','describe-stacks','--stack-name',"$($script:state.ProjectName)-$Name") -Json
    if (@($response.Stacks).Count -ne 1 -or $response.Stacks[0].StackId -notlike "arn:aws:cloudformation:$($script:state.Region):$($script:state.AccountId):stack/*" -or
        $response.Stacks[0].StackStatus -notin @('CREATE_COMPLETE','UPDATE_COMPLETE')) { throw 'The intended stack did not reach a successful state.' }
    $outputs = [ordered]@{}
    foreach ($item in $response.Stacks[0].Outputs) { $outputs[$item.OutputKey] = $item.OutputValue }
    Set-StateValue $OutputProperty ([pscustomobject]$outputs)
    Save-State
    Write-Host "Verified stack outputs saved: $Name."
}
function Get-AddonVersion([string]$Name) {
    $response = Invoke-OperatorAws @('eks','describe-addon-versions','--kubernetes-version','1.35','--addon-name',$Name) -Json
    $versions = @($response.addons.addonVersions | Where-Object { @($_.compatibilities | Where-Object { $_.clusterVersion -eq '1.35' -and $_.defaultVersion }).Count -gt 0 })
    if ($versions.Count -ne 1) { throw "Expected one verified default version for addon $Name." }
    $null = Invoke-OperatorAws @('eks','describe-addon-configuration','--addon-name',$Name,'--addon-version',$versions[0].addonVersion) -Json
    return $versions[0].addonVersion
}
function Set-KongConfiguration([ValidateSet('Challenge','Business')][string]$Mode, [switch]$Initial) {
    if ($Mode -eq 'Challenge') {
        $configuration = [ordered]@{
            _format_version='3.0'; _transform=$true
            services=@(@{name='acme-only'; url='http://acme-solver.fcg-platform.svc.cluster.local:8089';
                routes=@(@{name='acme-only'; protocols=@('http','https'); methods=@('GET');
                    paths=@('~^/.well-known/acme-challenge/[A-Za-z0-9_-]+$'); strip_path=$false})})
        }
        $text = ConvertTo-Json -InputObject $configuration -Depth 20
    }
    else {
        $text = Get-Content -LiteralPath (Join-Path $repo 'k8s/gateway/kong.template.json') -Raw -Encoding UTF8
        if (-not $text.Contains('__JWT_SECRET_FROM_LOCAL_SETTINGS__')) { throw 'Reviewed Kong secret placeholder is missing.' }
        $configuration = ConvertFrom-CloudJson -Json $text
        $keys = @($configuration.consumers.jwt_secrets | Where-Object { $_.secret -ceq '__JWT_SECRET_FROM_LOCAL_SETTINGS__' })
        if ($keys.Count -ne 1) { throw 'Expected one Kong issuer secret placeholder.' }
        $keys[0].secret = $state.Secrets.JwtKey
        foreach ($service in $configuration.services) {
            if ($service.name -eq 'users-api') { $service.url='http://users-api.fcg-users.svc.cluster.local:8080' }
            elseif ($service.name -eq 'catalog-api') { $service.url='http://catalog-api.fcg-catalog.svc.cluster.local:8080' }
        }
        $text = ConvertTo-Json -InputObject $configuration -Depth 30
    }
    $secretPath = Join-Path $directory 'kong-config.local.json'
    try {
        Write-CloudJson -Path $secretPath -Value @{apiVersion='v1';kind='Secret';metadata=@{name='fcg-kong-config';namespace='fcg-platform'};type='Opaque';data=@{'kong.json'=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))}}
        Assert-CloudWindow -State $state
        $null = K @('apply','--server-side','--field-manager=fcg-kong-configuration','-f',$secretPath) 'fcg-platform'
        if (-not $Initial) {
            $null = K @('rollout','restart','deployment/kong') 'fcg-platform'
            $null = K @('rollout','status','deployment/kong','--timeout=300s') 'fcg-platform'
        }
    }
    finally { if (Test-Path -LiteralPath $secretPath) { Remove-Item -LiteralPath $secretPath -Force } }
}

$identity = Invoke-OperatorAws @('sts','get-caller-identity') -Json
if ($identity.Account -cne $state.AccountId) { throw 'The AWS caller differs from the intended account.' }
if ($Stage -ne 'Discover') { Assert-CloudWindow -State $state }
switch ($Stage) {
    'Discover' {
        $preflightPath = Join-Path $directory 'preflight.local.json'
        & (Join-Path $PSScriptRoot 'test-aws-foundation.ps1') -ExpectedAccountId $state.AccountId -Profile $state.AwsProfile -Region $state.Region -AwsExecutable $env:FCG_AWS_EXECUTABLE -OutputPath $preflightPath
        $preflight = ConvertFrom-CloudJson -Json (Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8)
        if ($preflight.GateStatus -cne 'read-only-verified') { throw 'Read-only checks did not pass; renew login or resolve the reported checks.' }
        $state.AdminRoleArn = $preflight.OperatorRoleArn
        $zones = @($preflight.AvailabilityZones | Where-Object { $_ -in $preflight.NodeOfferedInZones } | Sort-Object)
        if ($zones.Count -lt 2) { throw 'Two verified offered zones are required.' }
        if (-not $state.AvailabilityZoneA) { $state.AvailabilityZoneA = $zones[0] }
        if (-not $state.AvailabilityZoneB) { $state.AvailabilityZoneB = $zones[1] }
        if ($state.AvailabilityZoneA -notin $zones -or $state.AvailabilityZoneB -notin $zones -or $state.AvailabilityZoneA -eq $state.AvailabilityZoneB) { throw 'Existing selected zones are no longer valid.' }
        $publicIp = (Invoke-WebRequest -UseBasicParsing -Uri 'https://checkip.amazonaws.com' -TimeoutSec 15).Content.Trim()
        if ($publicIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { throw 'Could not verify the operator public IPv4.' }
        $state.AdminCidrIPv4 = "$publicIp/32"
        Set-StateValue 'PreflightObservedAtUtc' $preflight.ObservedAtUtc
        Save-State
        Protect-CloudFile -Path $preflightPath
        Write-Host 'Read-only discovery saved. It does not prove create permissions or provision resources.'
    }
    'Network' {
        $plan = Invoke-CloudAws -Arguments @('freetier','get-account-plan-state') -Profile $state.AwsProfile -Region 'us-east-1' -AsJson
        $remainingHours = ([DateTimeOffset]::Parse($state.WindowEndUtc) - [DateTimeOffset]::UtcNow).TotalHours
        $requiredCredit = [decimal](40 + 0.50 * $remainingHours)
        if ($plan.accountId -cne $state.AccountId -or $plan.accountPlanType -cne 'FREE' -or $plan.accountPlanStatus -cne 'ACTIVE' -or
            $plan.accountPlanRemainingCredits.unit -cne 'USD' -or [decimal]$plan.accountPlanRemainingCredits.amount -lt $requiredCredit -or
            [DateTimeOffset]::Parse($plan.accountPlanExpirationDate) -lt [DateTimeOffset]::Parse($state.WindowEndUtc)) { throw 'Free plan/current credit does not cover the approved estimate and reserve. Do not upgrade or spend personal money.' }
        Assert-ObservationTime $state.PreflightObservedAtUtc 2 'PreflightObservedAtUtc'
        # Published prices must be rechecked on the day of creation, not inherited from an old snapshot.
        Assert-ObservationTime $state.PriceReviewObservedAtUtc 24 'PriceReviewObservedAtUtc'
        $instances = Invoke-OperatorAws @('ec2','describe-instances','--filters','Name=instance-state-name,Values=pending,running,stopping,stopped') -Json
        $active = @($instances.Reservations.Instances | Where-Object { $_.State.Name -in @('pending','running') })
        $used = 0
        if ($active.Count -gt 0) {
            $types = @($active.InstanceType | Sort-Object -Unique)
            $typesResponse = Invoke-OperatorAws (@('ec2','describe-instance-types','--instance-types') + $types) -Json
            foreach ($instance in $active) { $used += [int](@($typesResponse.InstanceTypes | Where-Object InstanceType -eq $instance.InstanceType)[0].VCpuInfo.DefaultVCpus) }
        }
        $quota = Invoke-OperatorAws @('service-quotas','get-service-quota','--service-code','ec2','--quota-code','L-1216C47A') -Json
        if ($used + 4 -gt [double]$quota.Quota.Value) { throw 'Current instance usage leaves insufficient verified standard-vCPU quota.' }
        $parameterPath = Join-Path $directory 'network-parameters.local.json'
        & (Join-Path $PSScriptRoot 'new-aws-foundation-parameters.ps1') -Stage network-compute -ExpectedAccountId $state.AccountId -ProjectName $state.ProjectName -AdminRoleArn $state.AdminRoleArn -AdminCidrIPv4 $state.AdminCidrIPv4 -AvailabilityZoneA $state.AvailabilityZoneA -AvailabilityZoneB $state.AvailabilityZoneB -OutputPath $parameterPath
        $parameters = [ordered]@{}
        foreach ($item in (Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json)) { $parameters[$item.ParameterKey] = $item.ParameterValue }
        Deploy-Stack 'network' (Join-Path $repo 'infra/aws/templates/network-compute.json') $parameters 'NetworkOutputs'
    }
    'Notifications' {
        if (-not $state.NetworkOutputs.ArtifactBucketName) { throw 'The actual network artifact bucket output is required.' }
        $source = Join-Path $siblings 'tech-challenge-3-notifications-function'
        $buildId = [Guid]::NewGuid().ToString('N')
        $publish = Join-Path $directory "lambda-$buildId"
        $null = Invoke-CloudNative -Executable 'dotnet' -Arguments @('publish',(Join-Path $source 'src/FCG.Notifications.Function/FCG.Notifications.Function.csproj'),'-c','Release','-r','linux-x64','--self-contained','false','-o',$publish)
        $zip = Join-Path $directory "lambda-$buildId.local.zip"
        Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
        $template = Get-Content -LiteralPath (Join-Path $source 'template.yaml') -Raw
        if ([regex]::Matches($template, '(?m)^      CodeUri:.*$').Count -ne 1) { throw 'The reviewed SAM template must contain exactly one CodeUri.' }
        $template = [regex]::Replace($template, '(?m)^      CodeUri:.*$', ('      CodeUri: ' + (ConvertTo-Json -InputObject $zip -Compress)))
        $inputPath = Join-Path $directory 'sam-build.local.yaml'
        $packaged = Join-Path $directory 'sam-packaged.local.json'
        Write-CloudPrivateText -Path $inputPath -Text $template
        $null = Invoke-OperatorAws @('cloudformation','package','--template-file',$inputPath,'--s3-bucket',$state.NetworkOutputs.ArtifactBucketName,'--s3-prefix','notifications','--output-template-file',$packaged,'--use-json')
        Deploy-Stack 'notifications' $packaged @{ ProjectName=$state.ProjectName; NotificationsEnabled='true' } 'NotificationsOutputs'
        Set-StateValue 'NotificationsPackageSha256' ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant())
        Save-State
    }
    'Runtime' {
        Deploy-Stack 'runtime' (Join-Path $repo 'infra/aws/templates/runtime-identity.json') @{
            ProjectName=$state.ProjectName; ClusterName=$state.NetworkOutputs.ClusterName; DomainName="$($state.ProjectName)-search"; IndexName='fcg-games'
            UserCreatedQueueArn=$state.NotificationsOutputs.UserCreatedQueueArn; PaymentProcessedQueueArn=$state.NotificationsOutputs.PaymentProcessedQueueArn
            PodIdentityAgentVersion=(Get-AddonVersion 'eks-pod-identity-agent'); EbsCsiVersion=(Get-AddonVersion 'aws-ebs-csi-driver')
        } 'RuntimeOutputs'
    }
    'Search' {
        $null = Invoke-OperatorAws @('iam','get-role','--role-name','AWSServiceRoleForAmazonOpenSearchService') -Json
        # If this role is absent, create only the official service-linked role as documented in the runbook, then retry.
        Deploy-Stack 'search' (Join-Path $repo 'infra/aws/templates/search.json') @{
            VpcId=$state.NetworkOutputs.VpcId; PublicSubnetAId=$state.NetworkOutputs.PublicSubnetAId
            ClusterSecurityGroupId=$state.NetworkOutputs.ClusterSecurityGroupId; DomainName="$($state.ProjectName)-search"; IndexName='fcg-games'
            BootstrapRoleArn=$state.AdminRoleArn; CatalogRuntimeRoleArn=$state.RuntimeOutputs.CatalogSearchRoleArn
        } 'SearchOutputs'
    }
    'Access' {
        $nodes = Invoke-OperatorAws @('ec2','describe-instances','--filters',"Name=tag:eks:cluster-name,Values=$($state.NetworkOutputs.ClusterName)",'Name=instance-state-name,Values=running') -Json
        $instances = @($nodes.Reservations.Instances)
        if ($instances.Count -ne 1) { throw 'Expected exactly one running managed cluster node.' }
        Set-StateValue 'NodeInstanceId' $instances[0].InstanceId
        $ssm = Invoke-OperatorAws @('ssm','describe-instance-information','--filters',"Key=InstanceIds,Values=$($state.NodeInstanceId)") -Json
        if (@($ssm.InstanceInformationList).Count -ne 1 -or $ssm.InstanceInformationList[0].PingStatus -ne 'Online' -or [version]$ssm.InstanceInformationList[0].AgentVersion -lt [version]'3.1.1374.0') { throw 'Wait for the intended node to be SSM Online with remote-host forwarding support.' }
        Deploy-Stack 'access' (Join-Path $repo 'infra/aws/templates/deploy-access.json') @{
            ProjectName=$state.ProjectName; ClusterName=$state.NetworkOutputs.ClusterName; ClusterEndpoint=$state.NetworkOutputs.ClusterEndpoint
            SearchEndpoint=$state.SearchOutputs.DomainEndpoint; NodeInstanceId=$state.NodeInstanceId; OperatorRoleArn=$state.AdminRoleArn
        } 'DeployOutputs'
    }
    default {
        $config = Join-Path $directory 'operator-kubeconfig.local.yaml'
        $handle = $null
        try {
            $handle = Start-CloudTunnel -State $state -DirectoryPath $directory -Kubeconfig $config
            function K([string[]]$A, [string]$N, [switch]$Json) { Invoke-CloudKubectl -Arguments $A -Kubeconfig $config -Context 'fcg-fase4' -Namespace $N -AsJson:$Json }
            if ($Stage -eq 'Platform') {
                foreach ($file in @('namespaces.yaml','serviceaccounts.yaml')) { $null = K @('apply','-f',(Join-Path $repo "k8s/cloud/bootstrap/$file")) }
                $null = K @('apply','-f',(Join-Path $repo 'k8s/cloud/deploy-admission.yaml'))
                $null = K @('apply','-f',(Join-Path $repo 'k8s/cloud/deploy-rbac.json'))
                & (Join-Path $PSScriptRoot 'apply-cloud-secrets.ps1') -StatePath $StatePath -Kubeconfig $config
                $existing = K @('get','secrets','--field-selector','metadata.name=fcg-kong-config') 'fcg-platform' -Json
                if (@($existing.items).Count -eq 0) { Set-KongConfiguration 'Challenge' -Initial }
                if ($state.Images.payments -cnotmatch ('^' + [regex]::Escape($state.NetworkOutputs.PaymentsRepositoryUri) + '@sha256:[0-9a-f]{64}$')) { throw 'Record the published Payments image digest before applying platform resources.' }
                $rendered = K @('kustomize',(Join-Path $repo 'k8s/cloud/bootstrap'))
                $rendered = $rendered.Replace('__AVAILABILITY_ZONE_A__',$state.NetworkOutputs.AvailabilityZoneA).Replace('__PAYMENTS_IMAGE__',$state.Images.payments)
                if ($rendered -match '__[A-Z0-9_]+__') { throw 'Unresolved bootstrap token.' }
                $manifest = Join-Path $directory 'bootstrap.local.yaml'
                Write-CloudPrivateText -Path $manifest -Text $rendered
                $null = K @('apply','-f',$manifest)
                foreach ($name in @('sqlserver','rabbitmq','redis','kong','payments-api','prometheus','grafana')) { $null = K @('rollout','status',"deployment/$name",'--timeout=300s') 'fcg-platform' }
                & (Join-Path $PSScriptRoot 'bootstrap-cloud-databases.ps1') -StatePath $StatePath -Kubeconfig $config
            }
            elseif ($Stage -eq 'SearchBootstrap') {
                if (-not $state.SearchSettingsConfirmedAtUtc) { throw 'Configure and verify managed auto_create_index=false first.' }
                $catalog = K @('get','deployments','--field-selector','metadata.name=catalog-api') 'fcg-catalog' -Json
                if (@($catalog.items).Count -gt 0 -and $catalog.items[0].spec.replicas -gt 0) { throw 'Stop Catalog writers in a controlled maintenance window before search bootstrap; do not reset an index in use.' }
                $manifest = Get-Content -LiteralPath (Join-Path $repo 'k8s/cloud/catalog/migration-job.json') -Raw | ConvertFrom-Json
                $manifest.metadata.name = 'catalog-search-bootstrap-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
                $manifest.spec.template.spec.serviceAccountName = 'catalog-search-bootstrap'
                $manifest.spec.template.spec.containers[0].image = $state.Images.catalog
                $manifest.spec.template.spec.containers[0].args = @('--search-bootstrap')
                $manifest.spec.template.spec.containers[0].envFrom = @(@{ configMapRef=@{name='catalog-api-config'} },@{secretRef=@{name='catalog-api-secrets'}},@{secretRef=@{name='catalog-migration-secrets'}})
                $job = Join-Path $directory 'search-bootstrap.local.json'
                Write-CloudJson -Path $job -Value $manifest
                $null = K @('create','-f',$job) 'fcg-catalog'
                $null = K @('wait','--for=condition=complete',"job/$($manifest.metadata.name)",'--timeout=300s') 'fcg-catalog'
            }
            elseif ($Stage -eq 'Apis') {
                foreach ($service in @('users','catalog')) {
                    $image = $state.Images.$service
                    $buildSha = $state.SourceCommits.$service
                    if ($image -notmatch '@sha256:[0-9a-f]{64}$' -or $buildSha -notmatch '^[0-9a-f]{40}$' -or $state.SourceCommits.orchestration -notmatch '^[0-9a-f]{40}$') { throw 'Record verified source commits and published image digests before API bootstrap.' }
                    & (Join-Path $PSScriptRoot 'deploy-api.ps1') -Service $service -Kubeconfig $config -Context 'fcg-fase4' -Namespace "fcg-$service" -Image $image -BuildSha $buildSha -OrchestrationRef $state.SourceCommits.orchestration -DeploymentId ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')) -OutputPath (Join-Path $directory "$service-initial-deploy.local.json")
                    if ($LASTEXITCODE -ne 0) { throw "Initial API bootstrap failed for $service." }
                }
                Write-Host 'Initial API bootstrap only; external HTTPS smoke and real Actions rollouts are still required.'
            }
            elseif ($Stage -eq 'Certificate') {
                & (Join-Path $PSScriptRoot 'issue-cloud-certificate.ps1') -StatePath $StatePath -Kubeconfig $config -Context 'fcg-fase4'
                if ($LASTEXITCODE -ne 0) { throw 'IP certificate issuance/import failed; business routes remain disabled.' }
            }
            else {
                if ($Stage -eq 'GatewayChallenge') {
                    Set-KongConfiguration 'Challenge'
                    $certificateArn = ''; $challenge = 'true'
                }
                else {
                    if (-not $state.CertificateArn) { throw 'Import a verified production IP certificate before activating HTTPS.' }
                    $certificateArn = $state.CertificateArn; $challenge = 'false'
                }
                Deploy-Stack 'gateway' (Join-Path $repo 'infra/aws/templates/gateway.json') @{
                    ProjectName=$state.ProjectName; VpcId=$state.NetworkOutputs.VpcId; PublicSubnetAId=$state.NetworkOutputs.PublicSubnetAId
                    ClusterSecurityGroupId=$state.NetworkOutputs.ClusterSecurityGroupId; NodeInstanceId=$state.NodeInstanceId; CertificateArn=$certificateArn; AllowHttpChallenge=$challenge
                } 'GatewayOutputs'
                if ($Stage -eq 'GatewayHttps') {
                    $listeners = Invoke-OperatorAws @('elbv2','describe-listeners','--load-balancer-arn',$state.GatewayOutputs.LoadBalancerArn) -Json
                    if (@($listeners.Listeners | Where-Object Port -eq 80).Count -gt 0) { throw 'HTTP listener still exists; keep business routes disabled.' }
                    Set-KongConfiguration 'Business'
                }
            }
        }
        finally { if ($handle) { Stop-CloudTunnel -Handle $handle } }
    }
}
