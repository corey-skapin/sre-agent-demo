#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$principal = '00000000-0000-0000-0000-000000000003'
$base = "/subscriptions/$subscription"
$group = "$base/resourceGroups/rg-arc-demo-sre"
$agent = "$group/providers/Microsoft.App/agents/sre-arc-demo"
$identityId = "$group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami"
$hibernate = Join-Path $root 'scripts\Hibernate-SreAgent.ps1'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Lifecycle assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected lifecycle failure: $Pattern"
}
function Reset-Fixture {
    $global:AzCalls.Clear()
    $global:LifecycleState = @{
        groupExists = $true; denyDelete = $false; drift = $false; pages = $false; restReads = 0; badNextLink = $false
        identity = @{ id = $identityId; name = 'sre-arc-demo-uami'; principalId = $principal }
        resources = @(
            @{ id = $agent; name = 'sre-arc-demo'; type = 'Microsoft.App/agents' },
            @{ id = $identityId; name = 'sre-arc-demo-uami'; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' },
            @{ id = "$group/providers/Microsoft.Insights/components/sre-arc-demo-appi"; name = 'sre-arc-demo-appi'; type = 'Microsoft.Insights/components' },
            @{ id = "$group/providers/Microsoft.Insights/actionGroups/Application Insights Smart Detection"; name = 'Application Insights Smart Detection'; type = 'Microsoft.Insights/actionGroups' }
        )
        assignments = @()
    }
    foreach ($rg in @('rg-arc-demo', 'rg-arc-demo-infra')) {
        foreach ($role in @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c')) {
            $scope = "$base/resourceGroups/$rg"
            $global:LifecycleState.assignments += @{ id = "$scope/providers/Microsoft.Authorization/roleAssignments/$rg-$role"; name = "$rg-$role"; properties = @{ principalId = $principal; scope = $scope; roleDefinitionId = "/roles/$role" } }
        }
    }
    $global:LifecycleState.assignments += @{ id = "$agent/providers/Microsoft.Authorization/roleAssignments/deployer"; name = 'deployer'; properties = @{ principalId = '00000000-0000-0000-0000-000000000004'; scope = $agent; roleDefinitionId = '/roles/e79298df-d852-4c6d-84f9-5d13249d1e55' } }
}
try {
    Reset-Fixture
    $global:AzResponder = {
        $command = $args -join ' '
        $state = $global:LifecycleState
        if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
        if ($command -like 'group exists*') { return ($state.groupExists | ConvertTo-Json) }
        if ($command -like 'resource list*') {
            if ($state.drift -and $state.restReads -ge 2) { $state.resources += @{ id = '/unexpected'; name = 'unexpected'; type = 'Microsoft.Storage/storageAccounts' }; $state.drift = $false }
            return ConvertTo-Json -InputObject @($state.resources) -Depth 30
        }
        if ($command -like 'identity show*') { return $state.identity | ConvertTo-Json }
        if ($command -like 'rest --method get*') {
            $state.restReads++
            $uri = $args[[Array]::IndexOf($args, '--url') + 1]
            if ($uri -match '/resourceGroups/rg-arc-demo-sre/providers/Microsoft.Authorization/roleAssignments') {
                $items = @($state.assignments | Where-Object { $_.properties.scope -like '*/providers/Microsoft.App/agents/*' })
            } else {
                $items = @($state.assignments | Where-Object { $_.properties.principalId -eq $state.identity.principalId })
            }
            if ($state.pages -and $uri -notmatch 'page=2' -and $items.Count -gt 1) {
                return @{ value = @($items[0]); nextLink = $(if ($state.badNextLink) { 'https://example.invalid/steal' } else { "$uri&page=2" }) } | ConvertTo-Json -Depth 30
            }
            if ($uri -match 'page=2') { $items = @($items | Select-Object -Skip 1) }
            return @{ value = $items } | ConvertTo-Json -Depth 30
        }
        if ($command -like 'role assignment delete*' -or $command -like 'resource delete*') {
            if ($state.denyDelete) { $global:LASTEXITCODE = 13; return '' }
            $id = $args[[Array]::IndexOf($args, '--ids') + 1]
            $state.assignments = @($state.assignments | Where-Object id -NE $id)
            $state.resources = @($state.resources | Where-Object id -NE $id)
            return ''
        }
        throw "Unexpected mocked lifecycle call: $command"
    }
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -WhatIf
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete|account set|get-access-token' }).Count -eq 0) 'WhatIf makes no mutations or service/token calls'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check ($global:LifecycleState.resources.Count -eq 1 -and $global:LifecycleState.resources[0].id -eq $identityId) 'Parking retains only the exact UAMI'
    Check ($global:LifecycleState.identity.principalId -eq $principal -and $global:LifecycleState.groupExists) 'Group and principal remain unchanged'
    Check ($global:LifecycleState.assignments.Count -eq 0) 'All six external grants and parent administrator grant removed'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' }).Count -eq 7) 'Exact seven assignment IDs deleted once'
    Check (@($global:AzCalls | Where-Object { $_ -like 'resource delete*' }).Count -eq 3) 'Only parent and two known diagnostics deleted'
    Check (@($global:AzCalls | Where-Object { $_ -like 'group delete*' -or $_ -like 'identity delete*' }).Count -eq 0) 'Normal parking never deletes group or identity'
    $report = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($report.status -eq 'pass') "Retained-only Hibernated passes: $($report.checks | ConvertTo-Json -Compress -Depth 20)"
    Check (@($report.checks | Where-Object { $_.id -eq 'parent-admin-absent' -and $_.status -eq 'pass' }).Count -eq 1) 'Readiness independently verifies parent administrator absence'
    $global:AzCalls.Clear()
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Repeated parked invocation makes zero writes'
    Reset-Fixture
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId '00000000-0000-0000-0000-000000000099' -Confirm:$false } 'differs'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Mismatched saved principal fails before mutation'
    Reset-Fixture
    $global:LifecycleState.resources += @{ id = "$group/providers/Microsoft.Storage/storageAccounts/unowned"; name = 'unowned'; type = 'Microsoft.Storage/storageAccounts' }
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected resources'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Unknown resource blocks the whole mutation'
    Reset-Fixture
    $global:LifecycleState.assignments[0].properties.roleDefinitionId = '/roles/unknown'
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected identity-owned'
    Reset-Fixture
    $global:LifecycleState.assignments[0].properties.scope += '/providers/Microsoft.Compute/virtualMachines/unexpected'
    $global:LifecycleState.assignments[0].id = "$($global:LifecycleState.assignments[0].properties.scope)/providers/Microsoft.Authorization/roleAssignments/unknown"
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected identity-owned'
    Reset-Fixture
    $global:LifecycleState.assignments[-1].properties.roleDefinitionId = '/roles/unowned-parent-role'
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected parent-scoped'
    Reset-Fixture
    $global:LifecycleState.denyDelete = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'failed \(13\)'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' }).Count -eq 1 -and
        @($global:AzCalls | Where-Object { $_ -like 'resource delete*' }).Count -eq 0) 'Denied mutation stops without retry or resource deletion'
    Reset-Fixture
    $global:LifecycleState.drift = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected resources'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Concurrent resource drift stops before first write'
    Reset-Fixture
    $global:LifecycleState.pages = $true
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($global:LifecycleState.assignments.Count -eq 0) 'Paginated principal lookup removes every known grant, not just first page'
    Reset-Fixture
    $global:LifecycleState.pages = $true; $global:LifecycleState.badNextLink = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'pagination'
    Check (@($global:AzCalls | Where-Object { $_ -match 'example.invalid| delete' }).Count -eq 0) 'Untrusted pagination target is never requested and blocks writes'
    Reset-Fixture
    $global:LifecycleState.assignments[0].id = "$base/resourceGroups/elsewhere/providers/Microsoft.Authorization/roleAssignments/wrong-scope"
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'ID does not match'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -NE $identityId)
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'live or saved identity principal'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -EQ $identityId)
    $global:LifecycleState.assignments = @($global:LifecycleState.assignments | Where-Object { $_.properties.scope -eq $agent })
    $partial = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
    Check ($partial.status -eq 'fail' -and @($partial.checks | Where-Object { $_.id -eq 'parent-admin-absent' -and $_.status -eq 'fail' }).Count -eq 1) 'Deleted parent alone does not prove its administrator grant is absent'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($global:LifecycleState.assignments.Count -eq 0 -and $global:LifecycleState.resources.Count -eq 1) 'Partial prior deletion safely cleans the exact parent grant without deleting identity'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -NE $identityId)
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    $missingIdentity = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($global:LifecycleState.resources.Count -eq 0 -and $missingIdentity.status -eq 'fail') 'Partial saved-principal cleanup never creates identity or falsely certifies normal Hibernated'
    Write-Host "$count lifecycle assertions passed. All cloud calls mocked."
} finally {
    Remove-Variable -Scope Global -Name LifecycleState -ErrorAction SilentlyContinue
}
