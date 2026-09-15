param(
    [Parameter(Mandatory = $true)][ValidateSet('true','false')][string]$Enabled,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{12}$')][string]$AccountId,
    [string]$Profile = 'fiap-fase3'
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Account $AccountId
$stackName = 'fcg-fase3-notifications'
$stack = (Aws cloudformation describe-stacks @{ StackName = $stackName }).Stacks[0]
if ($stack.StackStatus -notin @('CREATE_COMPLETE','UPDATE_COMPLETE')) { throw 'Cloud stack must be stable before toggling triggers.' }
$current = ($stack.Parameters | Where-Object ParameterKey -eq 'NotificationsEnabled').ParameterValue
if ($current -ne $Enabled) {
    $name = 'fcg-session-' + [guid]::NewGuid().ToString('N')
    $change = Aws cloudformation create-change-set @{ StackName = $stackName; ChangeSetName = $name; ChangeSetType = 'UPDATE'; UsePreviousTemplate = $true; Capabilities = @('CAPABILITY_NAMED_IAM'); Parameters = @(@{ ParameterKey = 'NotificationsEnabled'; ParameterValue = $Enabled }) }
    Wait-Until { $script:changes = Aws cloudformation describe-change-set @{ StackName = $stackName; ChangeSetName = $name }; $script:changes.Status -in @('CREATE_COMPLETE','FAILED') } 'Changeset creation' 180
    if ($changes.Status -ne 'CREATE_COMPLETE') { throw ('Changeset failed: ' + $changes.StatusReason) }
    $allowed = @('NotificationsFunctionUserCreated','NotificationsFunctionPaymentProcessed')
    if ($changes.Changes.Count -ne 2) { throw 'Refusing changeset: expected exactly two mapping changes.' }
    foreach ($entry in $changes.Changes) {
        $c = $entry.ResourceChange
        if ($c.LogicalResourceId -notin $allowed -or $c.ResourceType -ne 'AWS::Lambda::EventSourceMapping' -or $c.Action -ne 'Modify' -or $c.Replacement -ne 'False') { throw 'Refusing unexpected resource change.' }
        foreach ($detail in $c.Details) { if ($detail.Target.Attribute -ne 'Properties' -or $detail.Target.Name -ne 'Enabled') { throw 'Refusing change beyond mapping Enabled property.' } }
    }
    Write-Host "Reviewed changeset: only the two SQS mappings Enabled=$Enabled; no resource replacement."
    Write-LocalJson (Join-Path $repo "notifications-$Enabled-changes.local.json") $changes
    $null = Aws cloudformation execute-change-set @{ StackName = $stackName; ChangeSetName = $name }
    Wait-Until { $script:updated = (Aws cloudformation describe-stacks @{ StackName = $stackName }).Stacks[0]; $script:updated.StackStatus -notmatch '_IN_PROGRESS$' } 'Cloud stack update' 300
    if ($updated.StackStatus -ne 'UPDATE_COMPLETE') { throw ('Cloud update failed: ' + $updated.StackStatus) }
}
$expected = if ($Enabled -eq 'true') { 'Enabled' } else { 'Disabled' }
Wait-Until {
    $mappings = (Aws lambda list-event-source-mappings @{ FunctionName = $stackName }).EventSourceMappings
    @($mappings).Count -eq 2 -and @($mappings | Where-Object State -ne $expected).Count -eq 0
} "Both mappings $expected" 180
Write-Host "Both Lambda SQS mappings confirmed $expected."
