[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][ValidateSet('users','catalog','payments')][string]$Service,
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$BuildSha
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cloud-common.ps1')
$state = Read-CloudState -Path $StatePath
Assert-CloudWindow -State $state
$source = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath
$head = Invoke-CloudNative -Executable 'git' -Arguments @('-C',$source,'rev-parse','HEAD')
$dirty = Invoke-CloudNative -Executable 'git' -Arguments @('-C',$source,'status','--porcelain')
if ($head.Trim() -cne $BuildSha -or $dirty.Trim()) { throw 'Build only a clean checkout of the exact reviewed source commit.' }
$identity = Invoke-CloudAws -Arguments @('sts','get-caller-identity') -Profile $state.AwsProfile -Region $state.Region -AsJson
if ($identity.Account -cne $state.AccountId) { throw 'Unexpected AWS account.' }
$property = (Get-Culture).TextInfo.ToTitleCase($Service) + 'RepositoryUri'
$repository = [string]$state.NetworkOutputs.$property
$expected = "$($state.AccountId).dkr.ecr.$($state.Region).amazonaws.com/$($state.ProjectName)/$Service"
if ($repository -cne $expected) { throw 'The ECR repository differs from the expected private project repository.' }
$registry = $repository.Split('/')[0]
$directory = Split-Path ([IO.Path]::GetFullPath($StatePath)) -Parent
$dockerDirectory = Join-Path $directory ('docker-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $dockerDirectory
Protect-CloudDirectory -Path $dockerDirectory
$tag = $BuildSha + '-initial-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$image = "$($repository):$tag"
try {
    $null = Invoke-CloudNative -Executable 'docker' -Arguments @('--config',$dockerDirectory,'build','--build-arg',"BUILD_SHA=$BuildSha",'--tag',$image,$source)
    $password = Invoke-CloudAws -Arguments @('ecr','get-login-password') -Profile $state.AwsProfile -Region $state.Region
    $preference = $ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $result = @($password | & docker --config $dockerDirectory login --username AWS --password-stdin $registry 2>&1); $code=$LASTEXITCODE }
    finally { $password=$null; $ErrorActionPreference=$preference }
    if ($code -ne 0) { throw 'ECR login failed; its private response was suppressed.' }
    $null = Invoke-CloudNative -Executable 'docker' -Arguments @('--config',$dockerDirectory,'push',$image)
    $published = Invoke-CloudAws -Arguments @('ecr','describe-images','--repository-name',"$($state.ProjectName)/$Service",'--image-ids',"imageTag=$tag") -Profile $state.AwsProfile -Region $state.Region -AsJson
    $digest = [string]$published.imageDetails[0].imageDigest
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'ECR did not return a verified image digest.' }
    $state.Images | Add-Member -NotePropertyName $Service -NotePropertyValue "$repository@$digest" -Force
    if ($state.PSObject.Properties.Name -notcontains 'SourceCommits') { $state | Add-Member -NotePropertyName SourceCommits -NotePropertyValue ([pscustomobject]@{}) }
    $state.SourceCommits | Add-Member -NotePropertyName $Service -NotePropertyValue $BuildSha -Force
    Write-CloudJson -Path $StatePath -Value $state
    Write-Host "Private ECR image published and digest saved for $Service ($BuildSha)."
}
finally {
    try { $null = Invoke-CloudNative -Executable 'docker' -Arguments @('--config',$dockerDirectory,'logout',$registry) } catch { }
    $config = Join-Path $dockerDirectory 'config.json'
    if (Test-Path -LiteralPath $config -PathType Leaf) { Remove-Item -LiteralPath $config -Force }
    # A failed Docker build may leave other harmless client files. Never recursively remove an inferred directory.
}
