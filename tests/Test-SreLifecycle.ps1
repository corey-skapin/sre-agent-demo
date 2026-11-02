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
$remove = Join-Path $root 'scripts\Remove-SreAgent.ps1'
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
        groupExists = $true; denyDelete = $false; denyRead = $false; drift = $false; pages = $false; restReads = 0; badNextLink = $false
        staleParentGrant = $false; pendingDelete = $false; pendingGroupDelete = $false; deleteCount = 0; failSecondDelete = $false
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
        if ($command -like 'resource show*') { return @{ id = $agent } | ConvertTo-Json }
        if ($command -like 'rest --method get*') {
            if ($state.denyRead) { $global:LASTEXITCODE = 13; return '' }
            $state.restReads++
            $uri = $args[[Array]::IndexOf($args, '--url') + 1]
            if ($uri -match '/resourceGroups/rg-arc-demo-sre/providers/Microsoft.Authorization/roleAssignments') {
                $items = @($state.assignments | Where-Object { $_.properties.scope -eq $group -or $_.properties.scope.StartsWith("$group/") })
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
            $state.deleteCount++
            if ($state.failSecondDelete -and $state.deleteCount -eq 2) { $global:LASTEXITCODE = 13; return '' }
            if ($state.denyDelete) { $global:LASTEXITCODE = 13; return '' }
            $id = $args[[Array]::IndexOf($args, '--ids') + 1]
            if ($state.pendingDelete) { return '' }
            $state.assignments = @($state.assignments | Where-Object id -NE $id)
            if ($id -eq $agent -and -not $state.staleParentGrant) {
                $state.assignments = @($state.assignments | Where-Object { $_.properties.scope -ne $agent })
            }
            $state.resources = @($state.resources | Where-Object id -NE $id)
            return ''
        }
        if ($command -like 'group delete*') {
            if ($state.resources.Count) { throw 'Mock refused group deletion with resources still present.' }
            if (-not $state.pendingGroupDelete) { $state.groupExists = $false }
            return ''
        }
        throw "Unexpected mocked lifecycle call: $command"
    }
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -WhatIf
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete|account set|get-access-token' }).Count -eq 0) 'WhatIf makes no mutations or service/token calls'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check ($global:LifecycleState.resources.Count -eq 3 -and $agent -notin $global:LifecycleState.resources.id) 'Parking retains UAMI and both diagnostics'
    Check ($global:LifecycleState.identity.principalId -eq $principal -and $global:LifecycleState.groupExists) 'Group and principal remain unchanged'
    Check ($global:LifecycleState.assignments.Count -eq 6) 'All six free workload grants retained; parent deployer grant follows parent lifetime'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' }).Count -eq 0) 'Hibernate never explicitly revokes IAM'
    Check (@($global:AzCalls | Where-Object { $_ -like 'resource delete*' }).Count -eq 1) 'Only paid parent deleted'
    Check (@($global:AzCalls | Where-Object { $_ -like 'group delete*' -or $_ -like 'identity delete*' }).Count -eq 0) 'Normal parking never deletes group or identity'
    $report = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($report.status -eq 'pass') "Retained-state Hibernated passes: $($report.checks | ConvertTo-Json -Compress -Depth 20)"
    Check (@($report.checks | Where-Object { $_.id -eq 'retained-diagnostics' -and $_.status -eq 'pass' }).Count -eq 1) 'Readiness reports retained diagnostics'
    $global:AzCalls.Clear()
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Repeated parked invocation makes zero writes'
    $platformGrant = @{ id = "$base/providers/Microsoft.Authorization/roleAssignments/platform"; name = 'platform'; properties = @{ principalId = $principal; scope = $base; roleDefinitionId = '/roles/749f88d5-cbae-40b8-bcfc-e573ddc772fa' } }
    $global:LifecycleState.assignments += $platformGrant
    $platformParked = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($platformParked.status -eq 'pass' -and @($platformParked.checks | Where-Object { $_.id -eq 'retained-platform-grant' -and $_.status -eq 'pass' }).Count -eq 1) 'Exact platform grant remains accepted with no live parent'
    Check (@($platformParked.checks | Where-Object { $_.id -in @('retained-workload-grants','retained-state-drift') -and $_.status -eq 'pass' }).Count -eq 2) 'Known subscription prerequisite is not reported as workload-grant excess or lifecycle drift'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0 -and $global:LifecycleState.assignments.Count -eq 7) 'Already parked platform grant is retained with zero IAM or resource writes'
    $duplicatePlatform = $platformGrant.Clone()
    $duplicatePlatform.id = "$base/providers/Microsoft.Authorization/roleAssignments/duplicate-platform"
    $duplicatePlatform.name = 'duplicate-platform'
    $global:LifecycleState.assignments += $duplicatePlatform
    $duplicateParked = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($duplicateParked.status -eq 'pass' -and @($duplicateParked.checks | Where-Object { $_.id -eq 'retained-platform-grant' -and $_.status -eq 'fail' -and -not $_.required }).Count -eq 1) 'Duplicate grants are surfaced without confusing a parked cost-state with Active readiness'
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Duplicate Azure Monitor'
    Reset-Fixture
    $global:LifecycleState.assignments += $platformGrant
    & $remove -SubscriptionId $subscription -TenantId $tenant -WhatIf
    Check ($global:LifecycleState.assignments.Count -eq 8 -and @($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Removed preview retains all seven UAMI grants plus parent admin'
    & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check (-not $global:LifecycleState.groupExists -and $global:LifecycleState.assignments.Count -eq 0) 'Full Removed deletes the exact subscription prerequisite together with six workload grants and parent admin'
    Reset-Fixture
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId '00000000-0000-0000-0000-000000000099' -Confirm:$false } 'differs'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Mismatched saved principal fails before mutation'
    Reset-Fixture
    $global:LifecycleState.resources += @{ id = "$group/providers/Microsoft.Storage/storageAccounts/unowned"; name = 'unowned'; type = 'Microsoft.Storage/storageAccounts' }
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($agent -notin $global:LifecycleState.resources.id -and @($global:LifecycleState.resources | Where-Object name -EQ unowned).Count -eq 1) 'Unknown resource is not deleted and does not block parking the known parent'
    $drifted = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
    Check ($drifted.status -eq 'pass' -and @($drifted.checks | Where-Object { $_.id -eq 'retained-state-drift' -and $_.status -eq 'fail' -and -not $_.required }).Count -eq 1) 'Parking reports unrelated drift without falsely certifying wake configuration'
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected resources'
    Reset-Fixture
    $global:LifecycleState.assignments[0].properties.roleDefinitionId = '/roles/unknown'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($global:LifecycleState.assignments[0].properties.roleDefinitionId -eq '/roles/unknown') 'Unexpected IAM is retained during parking'
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected identity-owned'
    Reset-Fixture
    $global:LifecycleState.assignments[0].properties.scope += '/providers/Microsoft.Compute/virtualMachines/unexpected'
    $global:LifecycleState.assignments[0].id = "$($global:LifecycleState.assignments[0].properties.scope)/providers/Microsoft.Authorization/roleAssignments/unknown"
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected identity-owned'
    Reset-Fixture
    $global:LifecycleState.assignments[-1].properties.roleDefinitionId = '/roles/unowned-parent-role'
    $global:LifecycleState.staleParentGrant = $true
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected parent-scoped'
    Reset-Fixture
    $global:LifecycleState.denyDelete = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'failed \(13\)'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' }).Count -eq 0 -and
        @($global:AzCalls | Where-Object { $_ -like 'resource delete*' }).Count -eq 1) 'Denied mutation stops without retry or IAM change'
    Reset-Fixture
    $global:LifecycleState.drift = $true
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected resources'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Concurrent unknown resource blocks Removed before first write'
    Reset-Fixture
    $global:LifecycleState.pages = $true
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($global:LifecycleState.assignments.Count -eq 6) 'Paginated principal lookup retains every free grant'
    & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check (-not $global:LifecycleState.groupExists -and $global:LifecycleState.assignments.Count -eq 0) 'Explicit Removed deletes known assignments, diagnostics, identity and empty group'
    $removed = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Removed -PreviousIdentityPrincipalId $principal
    Check ($removed.status -eq 'pass') 'Removed independently verifies absent group and saved-principal external grants'
    $global:AzCalls.Clear()
    & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Repeated Removed makes no mutations'
    $noSavedPrincipal = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Removed
    Check ($noSavedPrincipal.status -eq 'pending') 'Removed never guesses external principal after identity deletion'
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'live or saved identity principal'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Absent group without saved principal cannot trigger unverified cleanup'
    Reset-Fixture
    $global:LifecycleState.pages = $true; $global:LifecycleState.badNextLink = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'pagination'
    Check (@($global:AzCalls | Where-Object { $_ -match 'example.invalid| delete' }).Count -eq 0) 'Untrusted pagination target is never requested and blocks writes'
    Reset-Fixture
    $global:LifecycleState.assignments[0].id = "$base/resourceGroups/elsewhere/providers/Microsoft.Authorization/roleAssignments/wrong-scope"
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'ID does not match'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -NE $identityId)
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($agent -notin @($global:LifecycleState.resources | ForEach-Object { $_.id })) 'Missing identity does not strand the known paid parent'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -EQ $identityId)
    $global:LifecycleState.assignments = @($global:LifecycleState.assignments | Where-Object { $_.properties.scope -eq $agent })
    $partial = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
    Check ($partial.status -eq 'pass' -and @($partial.checks | Where-Object { $_.id -eq 'parent-scope-grants' -and $_.status -eq 'pending' -and -not $_.required }).Count -eq 1) 'Stale free parent grant is a wake diagnostic, not a cost-state blocker'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check ($global:LifecycleState.assignments.Count -eq 1 -and $global:LifecycleState.resources.Count -eq 1) 'Old UAMI-only state is idempotent; parking does not recreate diagnostics or revoke free entries'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -NE $identityId)
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    $missingIdentity = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($global:LifecycleState.resources.Count -eq 2 -and $missingIdentity.status -eq 'fail') 'Parking never creates missing identity or destroys retained diagnostics'
    Reset-Fixture
    $global:LifecycleState.denyRead = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'failed \(13\)'
    $denied = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Removed -PreviousIdentityPrincipalId $principal
    Check ($denied.status -eq 'fail') 'Read denial is never interpreted as absent or non-required drift'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Denied inspection blocks all writes'
    Reset-Fixture
    $preview = (& $remove -SubscriptionId $subscription -TenantId $tenant -WhatIf -Verbose 4>&1 | Out-String)
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Removed WhatIf is read-only including empty-group deletion'
    Check ($preview.Contains($identityId)) 'Removed preview includes the retained UAMI target even under inherited WhatIf'
    $global:LifecycleState.failSecondDelete = $true
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'failed \(13\)'
    Check ($global:LifecycleState.resources.Count -eq 4 -and $global:LifecycleState.assignments.Count -eq 6) 'Partial removal stops immediately at denial before resource deletion'
    $global:LifecycleState.failSecondDelete = $false
    & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check (-not $global:LifecycleState.groupExists -and $global:LifecycleState.assignments.Count -eq 0) 'Explicit retry converges from partial accepted removals without resurrecting state'
    Reset-Fixture
    $global:LifecycleState.pendingDelete = $true
    Throws { & $hibernate -SubscriptionId $subscription -TenantId $tenant -TimeoutSeconds 1 -Confirm:$false } 'pending'
    Check (@($global:AzCalls | Where-Object { $_ -like 'resource delete*' }).Count -eq 1) 'Pending deletion is observed, never blindly resubmitted'
    Reset-Fixture
    $global:LifecycleState.pendingDelete = $true
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -TimeoutSeconds 1 -Confirm:$false } 'Assignment deletion remains pending'
    Check (@($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' }).Count -eq 1) 'Pending assignment removal is read back rather than retried'
    Reset-Fixture
    $global:LifecycleState.resources = @()
    $global:LifecycleState.assignments = @()
    $global:LifecycleState.pendingGroupDelete = $true
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -TimeoutSeconds 1 -Confirm:$false } 'Group deletion remains pending'
    Check (@($global:AzCalls | Where-Object { $_ -like 'group delete*' }).Count -eq 1) 'Pending empty-group deletion is not resubmitted'
    Reset-Fixture
    $global:LifecycleState.resources = @($global:LifecycleState.resources | Where-Object id -EQ $identityId)
    $global:LifecycleState.assignments = @()
    $legacyParked = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId $principal
    Check ($legacyParked.status -eq 'pass' -and @($legacyParked.checks | Where-Object { $_.id -eq 'retained-workload-grants' -and $_.status -eq 'pending' -and -not $_.required }).Count -eq 1) 'Legacy UAMI-only parking passes cost checks and honestly reports missing wake grants'
    & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check (-not $global:LifecycleState.groupExists) 'Removed directly converges old parked state without recreating diagnostics/grants'
    Reset-Fixture
    $global:LifecycleState.groupExists = $false
    $global:LifecycleState.resources = @()
    $global:LifecycleState.assignments = @($global:LifecycleState.assignments | Where-Object { $_.properties.principalId -eq $principal })
    & $remove -SubscriptionId $subscription -TenantId $tenant -PreviousIdentityPrincipalId $principal -Confirm:$false
    Check ($global:LifecycleState.assignments.Count -eq 0 -and @($global:AzCalls | Where-Object { $_ -like 'resource delete*' -or $_ -like 'group delete*' }).Count -eq 0) 'Already absent group still cleans exact orphaned workload grants using saved principal'
    Reset-Fixture
    $global:LifecycleState.assignments += @{ id = "$group/providers/Microsoft.Authorization/roleAssignments/unowned"; name = 'unowned'; properties = @{ principalId = '00000000-0000-0000-0000-000000000099'; scope = $group; roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' } }
    Throws { & $remove -SubscriptionId $subscription -TenantId $tenant -Confirm:$false } 'Unexpected SRE-group scoped grants'
    Check (@($global:AzCalls | Where-Object { $_ -match ' delete' }).Count -eq 0) 'Removed never erases unowned group-scoped IAM through broad group deletion'
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    Check (@($global:LifecycleState.assignments | Where-Object name -EQ unowned).Count -eq 1) 'Unrelated group IAM is retained and does not block known-parent parking'
    Reset-Fixture
    $global:LifecycleState.assignments[0].properties.scope = $base
    $global:LifecycleState.assignments[0].properties.roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c'
    $global:LifecycleState.assignments[0].id = "$base/providers/Microsoft.Authorization/roleAssignments/legacy-contributor"
    & $hibernate -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
    $excessParked = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
    Check ($excessParked.status -eq 'pass' -and @($excessParked.checks | Where-Object { $_.id -eq 'retained-workload-grants' -and $_.status -eq 'fail' -and -not $_.required }).Count -eq 1) 'Legacy broad standing grant is reported as wake failure but not a cost-parking failure'
    Write-Host "$count lifecycle assertions passed. All cloud calls mocked."
} finally {
    Remove-Variable -Scope Global -Name LifecycleState -ErrorAction SilentlyContinue
}
