#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$grantScript = Join-Path $root 'scripts\Grant-SreAzureMonitorAlertAccess.ps1'
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$principal = '00000000-0000-0000-0000-000000000003'
$scope = "/subscriptions/$subscription"
$identityId = "$scope/resourceGroups/rg-arc-demo-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami"
$role = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
$parameters = @{ SubscriptionId = $subscription; TenantId = $tenant; PrincipalId = $principal }
$savedResponder = $global:AzResponder
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Monitor access assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected monitor access failure: $Pattern"
}
function Reset-Fixture {
    $global:AzCalls.Clear()
    $global:MonitorAccessState = @{
        assignments = @(); identityId = $identityId; principalId = $principal
        denyRead = $false; denyCreate = $false
    }
}
try {
    Reset-Fixture
    $global:AzResponder = {
        $command = $args -join ' '
        $state = $global:MonitorAccessState
        if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
        if ($command -like 'identity show*') { return @{ id = $state.identityId; principalId = $state.principalId } | ConvertTo-Json }
        if ($command -like 'rest --method get*') {
            if ($state.denyRead) { $global:LASTEXITCODE = 13; return '' }
            return @{ value = @($state.assignments) } | ConvertTo-Json -Depth 20
        }
        if ($command -like 'role assignment create*') {
            if ($state.denyCreate) { $global:LASTEXITCODE = 13; return '' }
            $name = $args[[Array]::IndexOf($args, '--name') + 1]
            $scope = $args[[Array]::IndexOf($args, '--scope') + 1]
            $state.assignments = @(@{
                id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"; name = $name
                properties = @{
                    principalId = $args[[Array]::IndexOf($args, '--assignee-object-id') + 1]
                    scope = $scope; roleDefinitionId = $args[[Array]::IndexOf($args, '--role') + 1]
                }
            })
            return $state.assignments[0] | ConvertTo-Json -Depth 20
        }
        throw "Unexpected monitor access call: $command"
    }
    $first = & $grantScript @parameters -WhatIf
    $second = & $grantScript @parameters -WhatIf
    Check ($first.status -eq 'preview' -and $first.assignmentId -eq $second.assignmentId) 'WhatIf returns one deterministic assignment'
    Check ($first.principalId -eq $principal -and $first.scope -eq $scope -and $first.roleDefinitionId.EndsWith("/$role")) 'Preview contains exactly the approved principal, role and subscription'
    Check (@($global:AzCalls | Where-Object { $_ -match ' create| delete|account set|get-access-token' }).Count -eq 0) 'Preview is read-only without token, Graph or account-switch calls'
    Throws { & $grantScript @parameters } 'explicitly approve'
    $created = & $grantScript @parameters -GrantAzureMonitorAlertAccess
    Check ($created.status -eq 'created' -and $created.assignmentId -eq $first.assignmentId) 'Single create is independently read back'
    $writes = @($global:AzCalls | Where-Object { $_ -like 'role assignment create*' })
    Check ($writes.Count -eq 1 -and $writes[0] -match '--assignee-principal-type ServicePrincipal') 'Creates once for a managed identity, without directory lookup'
    $existing = & $grantScript @parameters
    Check ($existing.status -eq 'existing' -and $existing.assignmentId -eq $created.assignmentId) 'Repeated invocation is idempotent and needs no new approval'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment create*' }).Count -eq 1) 'No duplicate create'
    $global:MonitorAccessState.assignments[0].id = "$scope/providers/Microsoft.Authorization/roleAssignments/portal-existing"
    $adopted = & $grantScript @parameters -GrantAzureMonitorAlertAccess
    Check ($adopted.assignmentId.EndsWith('/portal-existing') -and $adopted.status -eq 'existing') 'Existing exact grant keeps its original assignment ID'
    $global:MonitorAccessState.assignments += $global:MonitorAccessState.assignments[0].Clone()
    Throws { & $grantScript @parameters -GrantAzureMonitorAlertAccess } 'Duplicate'
    Reset-Fixture
    $global:MonitorAccessState.principalId = $tenant
    Throws { & $grantScript @parameters -GrantAzureMonitorAlertAccess } 'does not match'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment create*' }).Count -eq 0) 'Wrong live principal blocks writes'
    Reset-Fixture
    $global:MonitorAccessState.identityId = "$scope/resourceGroups/another/providers/Microsoft.ManagedIdentity/userAssignedIdentities/other"
    Throws { & $grantScript @parameters -WhatIf } 'does not match'
    Reset-Fixture
    $global:MonitorAccessState.denyRead = $true
    Throws { & $grantScript @parameters -GrantAzureMonitorAlertAccess } 'failed \(13\)'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment create*' }).Count -eq 0) 'Inspection denial is not absence'
    Reset-Fixture
    $global:MonitorAccessState.denyCreate = $true
    Throws { & $grantScript @parameters -GrantAzureMonitorAlertAccess } 'failed \(13\)'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment create*' }).Count -eq 1) 'Denied or ambiguous create is not blindly retried'
    Write-Host "$count Monitor access assertions passed. All cloud operations mocked."
} finally {
    $global:AzResponder = $savedResponder
    Remove-Variable -Scope Global -Name MonitorAccessState -ErrorAction SilentlyContinue
}
