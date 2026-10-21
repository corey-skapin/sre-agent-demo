Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')

function Get-SreArmRoleAssignments {
    param([string]$SubscriptionId, [string]$ScopeId, [string]$PrincipalId)
    $path = "$ScopeId/providers/Microsoft.Authorization/roleAssignments"
    $url = "https://management.azure.com${path}?api-version=2022-04-01"
    if ($PrincipalId) {
        if ($PrincipalId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'Invalid identity principal ID.' }
        # The documented principal filter includes grants above and below the scope.
        $url += '&$filter=' + [Uri]::EscapeDataString("principalId eq '$PrincipalId'")
    }
    $seen = [Collections.Generic.HashSet[string]]::new()
    do {
        $uri = [Uri]$url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
            $uri.AbsolutePath -ine $path -or -not $seen.Add($url) -or $seen.Count -gt 20) {
            throw 'Unexpected, repeated or excessive ARM role-assignment pagination. Inspection incomplete.'
        }
        $page = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'get', '--url', $url, '-o', 'json') |
            ConvertFrom-Json -AsHashtable -Depth 100
        if (-not $page.ContainsKey('value') -or $page.value -isnot [array]) { throw 'ARM role-assignment response is incomplete.' }
        foreach ($assignment in $page.value) {
            $expectedPrefix = "$($assignment.properties.scope)/providers/Microsoft.Authorization/roleAssignments/"
            if (-not $assignment.id.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Role assignment ID does not match its declared scope.' }
            [pscustomobject]@{
                id = $assignment.id; name = $assignment.name
                principalId = $assignment.properties.principalId
                scope = $assignment.properties.scope; roleDefinitionId = $assignment.properties.roleDefinitionId
            }
        }
        $url = $page['nextLink']
    } while ($url)
}

function Get-SreLifecycleInventory {
    param(
        [string]$SubscriptionId, [string]$SreResourceGroupName, [string]$AgentName,
        [string]$ArcResourceGroupName, [string]$InfraResourceGroupName,
        [string]$PreviousIdentityPrincipalId
    )
    function Read-AzJson([string[]]$Arguments) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments ($Arguments + @('-o', 'json')) | ConvertFrom-Json -Depth 100
    }
    $subscriptionScope = "/subscriptions/$SubscriptionId"
    $groupId = "$subscriptionScope/resourceGroups/$SreResourceGroupName"
    $agentId = "$groupId/providers/Microsoft.App/agents/$AgentName"
    $identityId = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$AgentName-uami"
    $removableIds = @(
        $agentId,
        "$groupId/providers/Microsoft.Insights/components/$AgentName-appi",
        "$groupId/providers/Microsoft.Insights/actionGroups/Application Insights Smart Detection"
    )
    $exists = Read-AzJson @('group', 'exists', '-n', $SreResourceGroupName)
    $resources = @()
    $principalId = $PreviousIdentityPrincipalId
    $identity = $null
    $parentAssignments = @()
    if ($exists) {
        $resources = @(Read-AzJson @('resource', 'list', '-g', $SreResourceGroupName))
        $unexpected = @($resources | Where-Object { $_.id -notin ($removableIds + $identityId) })
        if ($unexpected.Count) { throw "Unexpected resources in SRE group; refusing lifecycle changes: $($unexpected.id -join ', ')" }
        if (@($resources | Where-Object id -EQ $identityId).Count) {
            $identity = Read-AzJson @('identity', 'show', '--ids', $identityId)
            if ($identity.id -ine $identityId -or $identity.principalId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'Live SRE identity could not be verified.' }
            if ($principalId -and $principalId -ne $identity.principalId) { throw 'Previous principal differs from retained live identity; stop and inspect separately.' }
            $principalId = $identity.principalId
        }
        $groupAssignments = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId $groupId)
        $parentAssignments = @($groupAssignments | Where-Object { $_.scope -ieq $agentId -or $_.scope.StartsWith("$agentId/", [StringComparison]::OrdinalIgnoreCase) })
        if (@($parentAssignments | Where-Object { $_.scope -ine $agentId -or ($_.roleDefinitionId -split '/')[-1] -ne 'e79298df-d852-4c6d-84f9-5d13249d1e55' }).Count -or $parentAssignments.Count -gt 1) {
            throw 'Unexpected parent-scoped grants. Approve separate reconciliation before lifecycle changes.'
        }
    }
    $externalAssignments = @()
    if ($principalId) {
        $owned = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId $subscriptionScope -PrincipalId $principalId)
        $scopes = @($subscriptionScope, "$subscriptionScope/resourceGroups/$ArcResourceGroupName", "$subscriptionScope/resourceGroups/$InfraResourceGroupName")
        $roles = @('73c42c96-874c-492b-b04d-ab87d138a893', '92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
        if (@($owned | Where-Object { $_.principalId -ne $principalId -or $_.scope -notin $scopes -or ($_.roleDefinitionId -split '/')[-1] -notin $roles }).Count) {
            throw 'Unexpected identity-owned scope or role; stop lifecycle changes and approve a separate cleanup.'
        }
        $externalAssignments = @($owned | Sort-Object id -Unique)
    }
    [pscustomobject]@{
        groupExists = $exists; groupId = $groupId; agentId = $agentId; identityId = $identityId
        identity = $identity; principalId = $principalId; resources = $resources
        removableResources = @($removableIds | Where-Object { $_ -in @($resources | ForEach-Object { $_.id }) })
        externalAssignments = $externalAssignments; parentAssignments = $parentAssignments
    }
}

Export-ModuleMember -Function Get-SreArmRoleAssignments, Get-SreLifecycleInventory
