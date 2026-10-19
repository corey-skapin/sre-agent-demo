Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreConfiguration.psm1')

function Get-SreReadinessReport {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId, [string]$TenantId, [string]$SkinPath = '',
        [ValidateSet('Ready', 'Hibernated')][string]$DesiredState = 'Ready',
        [string]$PreviousIdentityPrincipalId
    )
    $checks = [Collections.Generic.List[object]]::new()
    function Add-Check([string]$Id, [string]$ResourceId, [string]$Status, [object]$Expected, [object]$Observed, [string]$Message, [bool]$Required = $true) {
        $checks.Add([ordered]@{ id = $Id; resourceId = $ResourceId; required = $Required; expected = $Expected; observed = $Observed; status = $Status; message = $Message })
    }
    function Read-AzJson([string[]]$Arguments) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments ($Arguments + @('-o', 'json')) | ConvertFrom-Json -Depth 100
    }
    $groups = @()
    try {
        $skin = Get-DemoSkin -Path $SkinPath
        Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
        $prefix = $skin.azure.namePrefix
        $groups = @("rg-$prefix-sre", "rg-$prefix", "rg-$prefix-infra")
        $base = "/subscriptions/$SubscriptionId/resourceGroups"
        $sreGroupId = "$base/$($groups[0])"
        $agentId = "$sreGroupId/providers/Microsoft.App/agents/$($skin.labels.agentName)"
        $identityId = "$sreGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($skin.labels.agentName)-uami"
        $exists = Read-AzJson @('group', 'exists', '-n', $groups[0])
        $principalId = $PreviousIdentityPrincipalId
        $agent = $null
        if ($exists) {
            $resources = @(Read-AzJson @('resource', 'list', '-g', $groups[0]))
            if (@($resources | Where-Object id -EQ $identityId).Count) {
                $identity = Read-AzJson @('identity', 'show', '--ids', $identityId)
                $principalId = $identity.principalId
            }
            if (@($resources | Where-Object id -EQ $agentId).Count) {
                $agent = Read-AzJson @('resource', 'show', '--ids', $agentId)
            }
        }
        if ($DesiredState -eq 'Hibernated') {
            Add-Check 'sre-group-absent' $sreGroupId $(if ($exists) { 'pending' } else { 'pass' }) $false $exists 'SRE hibernation is deletion-based; this command never deletes.'
        } elseif (-not $agent) {
            Add-Check 'parent' $agentId 'fail' 'Succeeded/Running' $null 'Required parent agent is absent; deploy parent then configure data plane.'
        } else {
            $p = $agent.properties
            $running = $p.provisioningState -eq 'Succeeded' -and $p.runningState -eq 'Running'
            Add-Check 'parent' $agentId $(if ($running) { 'pass' } elseif ($p.provisioningState -eq 'Failed') { 'fail' } else { 'pending' }) 'Succeeded/Running' "$($p.provisioningState)/$($p.runningState)" 'Control-plane provisioning and resource running state.'
            Add-Check 'review-mode' $agentId $(if ($p.actionConfiguration.mode -eq 'Review') { 'pass' } else { 'fail' }) 'Review' $p.actionConfiguration.mode 'Parent mode does not prove response-plan mode.'
            Add-Check 'access-level' $agentId $(if ($p.actionConfiguration.accessLevel -eq $skin.sre.accessLevel) { 'pass' } else { 'fail' }) $skin.sre.accessLevel $p.actionConfiguration.accessLevel 'Requested skin access profile.'
            Add-Check 'incident-platform' $agentId $(if ($p.incidentManagementConfiguration.type -eq 'AzMonitor') { 'pass' } else { 'fail' }) 'AzMonitor' $p.incidentManagementConfiguration.type 'Azure Monitor incident source.'
            $identityMatches = $principalId -and $p.actionConfiguration.identity -eq $identityId -and $p.knowledgeGraphConfiguration.identity -eq $identityId
            Add-Check 'identity' $identityId $(if ($identityMatches) { 'pass' } else { 'fail' }) $identityId $p.actionConfiguration.identity 'Action and knowledge graph must use the live user-assigned identity.'
            $expectedManaged = @("$base/$($groups[1])", "$base/$($groups[2])", "$base/$($groups[1])/providers/Microsoft.OperationalInsights/workspaces/law-$prefix", "$base/$($groups[1])/providers/Microsoft.Insights/actionGroups/ag-$prefix")
            $scenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
            if ('T09' -in $scenarios) { $expectedManaged += "$base/$($groups[2])/providers/Microsoft.App/containerApps/ca-$prefix-fault" }
            if ('T10' -in $scenarios -or 'T11' -in $scenarios) { $expectedManaged += "$base/$($groups[1])/providers/Microsoft.HybridCompute/machines/$($skin.sre.targetArcMachine)" }
            $missing = @($expectedManaged | Where-Object { $_ -notin $p.knowledgeGraphConfiguration.managedResources })
            Add-Check 'managed-resources' $agentId $(if ($missing.Count) { 'fail' } else { 'pass' }) $expectedManaged $p.knowledgeGraphConfiguration.managedResources "Missing managed IDs: $($missing -join ', ')"
            foreach ($scenario in $scenarios) {
                if ($scenario -eq 'T09') {
                    $app = Read-AzJson @('containerapp', 'show', '-g', $groups[2], '-n', "ca-$prefix-fault")
                    $healthy = $app.properties.provisioningState -eq 'Succeeded' -and $app.properties.runningStatus -eq 'Running'
                    $faultFlags = @($app.properties.template.containers | ForEach-Object { $_.env } | Where-Object name -EQ 'SIMULATE_CRASH')
                    $healthy = $healthy -and @($faultFlags | Where-Object value -EQ 'true').Count -eq 0
                    $revisions = @(Read-AzJson @('containerapp', 'revision', 'list', '-g', $groups[2], '-n', "ca-$prefix-fault"))
                    $serving = @($revisions | Where-Object {
                        $_.properties.active -and $_.properties.healthState -eq 'Healthy' -and
                        $_.properties.replicas -gt 0 -and $_.properties.trafficWeight -gt 0
                    })
                    $healthy = $healthy -and $serving.Count -gt 0
                    Add-Check 'T09-resource-health' $app.id $(if ($healthy) { 'pass' } else { 'fail' }) 'Healthy active revision serving traffic with replicas, no SIMULATE_CRASH=true' $app.properties.runningStatus 'Inspects actual revision health/replicas/traffic; active/provisioned alone is insufficient. No fault injection.'
                    $alert = Read-AzJson @('monitor', 'metrics', 'alert', 'show', '-g', $groups[2], '-n', "alert-$prefix-containerapp-restarts")
                    $alertHealthy = $alert.enabled -and $alert.severity -eq 2 -and $app.id -in $alert.scopes
                    Add-Check 'T09-alert' $alert.id $(if ($alertHealthy) { 'pass' } else { 'fail' }) 'Enabled Sev2, Container App scope' $alert.enabled 'Azure Monitor signal configuration, not firing-state proof.'
                } else {
                    $machine = Read-AzJson @('connectedmachine', 'show', '-g', $groups[1], '-n', $skin.sre.targetArcMachine)
                    Add-Check "$scenario-resource-health" $machine.id $(if ($machine.status -eq 'Connected') { 'pass' } else { 'pending' }) 'Connected' $machine.status 'Arc connection only; guest app/telemetry verification remains separate.'
                    if ($scenario -eq 'T11') {
                        $alertId = "$base/$($groups[1])/providers/Microsoft.Insights/scheduledQueryRules/alert-$prefix-lob-arc-app-fault"
                        $alert = Read-AzJson @('resource', 'show', '--ids', $alertId)
                        $ap = $alert.properties
                        $alertHealthy = $ap.enabled -and $ap.severity -eq 2 -and $ap.displayName.Contains($skin.labels.lobAlertTitleContains)
                        Add-Check 'T11-alert' $alertId $(if ($alertHealthy) { 'pass' } else { 'fail' }) "Enabled Sev2, title contains $($skin.labels.lobAlertTitleContains)" $ap.displayName 'Literal title keyword must align with the intended plan; region changes are not implied.'
                    }
                }
            }
            $session = $null
            try {
                $desired = Get-SreDesiredConfiguration -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath
                $session = New-SreConfigurationSession -Desired $desired
                $snapshot = Get-SreConfigurationSnapshot $session
                $handlers = @($snapshot.subagents | Where-Object name -CEQ $desired.handler.name)
                $handlerValid = $handlers.Count -eq 1 -and (Test-SreProperties $handlers[0].properties $desired.handler.properties)
                if ($handlerValid -and $handlers[0].properties.Contains('instructionsOverride') -and $handlers[0].properties.instructionsOverride) { $handlerValid = $false }
                Add-Check 'handler-instructions' $agentId $(if ($handlerValid) { 'pass' } else { 'fail' }) 'Versioned handler instructions and tools, no instructionsOverride' @($handlers | ForEach-Object { $_.name }) 'Full custom-agent read via pinned official export protocol; names alone are insufficient.'
                $modeValid = $true
                $filtersValid = $true
                $observedPlans = @()
                $legacyHandlers = @()
                foreach ($plan in $desired.plans) {
                    $matches = @($snapshot.filters | Where-Object name -CEQ $plan.name)
                    if ($matches.Count -ne 1) { $modeValid = $false; $filtersValid = $false; continue }
                    $properties = $matches[0].properties
                    $modeValid = $modeValid -and $properties.isEnabled -and $properties.agentMode -ieq 'Review'
                    $filtersValid = $filtersValid -and (Test-SreProperties $properties $plan.properties)
                    $observedPlans += @{ name = $plan.name; mode = $properties.agentMode; enabled = $properties.isEnabled; priorities = $properties.priorities; title = $properties.titleContains; handler = $properties.handlingAgent }
                    $legacyHandlers += @($snapshot.handlers | Where-Object {
                        $_.incidentFilterId -ceq $plan.name -and -not $_['isDeleted'] -and
                        ($_.customInstructions -or @($_.tools).Count -or @($_.incidentProcessingGuide).Count)
                    } | ForEach-Object { $_.id })
                }
                Add-Check 'plan-status-review' $agentId $(if ($modeValid) { 'pass' } else { 'fail' }) 'Each required existing plan enabled and Review' $observedPlans 'Reads actual plan properties, not MCP summary or parent mode.'
                Add-Check 'plan-filters-handler' $agentId $(if ($filtersValid) { 'pass' } else { 'fail' }) 'AzMonitor, Sev2, single title, intended service and custom agent' $observedPlans 'P1/P2 are invalid for AzMonitor; legacy MCP high is not Sev2.'
                Add-Check 'legacy-response-settings' $agentId $(if ($legacyHandlers.Count) { 'fail' } else { 'pass' }) @() $legacyHandlers 'Response-level instructions/tools/steps must be migrated to the handling custom agent, not retained on legacy handlers.'
                $owned = @($desired.plans | ForEach-Object { $_.name })
                $extra = @($snapshot.filters | Where-Object { $_.properties.isEnabled -and $_.name -notin $owned } | ForEach-Object { $_.name })
                Add-Check 'routing-conflicts' $agentId $(if ($extra.Count) { 'fail' } else { 'pass' }) 'No unreviewed enabled extra plans' $extra 'Conservatively requires review of every enabled unowned plan; never deletes quickstart automatically.'
            } catch {
                Add-Check 'data-plane-inspection' $agentId 'fail' 'Successful supported full configuration read' $null $_.Exception.Message
            } finally {
                if ($session) { $session.token = $null }
            }
            Add-Check 'telemetry-and-alerts' $agentId 'pending' 'Fresh separately authorized alert-to-thread/RCA/Review/recovery evidence' $null 'Configuration correctness does not certify a new automatic incident loop. This read-only command never injects a fault.'
            Add-Check 'code-repository-connection' $agentId 'skipped' 'Separate explicit authorization if needed' $null 'Public source context is not connector authentication.' $false
        }
        $expectedRoles = @('73c42c96-874c-492b-b04d-ab87d138a893', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
        if ($skin.sre.accessLevel -eq 'High') {
            $expectedRoles = @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
        }
        $scopes = [ordered]@{}
        if ($DesiredState -eq 'Hibernated') { $scopes['subscription'] = "/subscriptions/$SubscriptionId" }
        foreach ($rg in $groups[1..2]) { $scopes[$rg] = "$base/$rg" }
        foreach ($rg in $scopes.Keys) {
            $scope = $scopes[$rg]
            if ($rg -ne 'subscription' -and -not (Read-AzJson @('group', 'exists', '-n', $rg))) {
                Add-Check "rbac-$rg" $scope $(if ($DesiredState -eq 'Hibernated') { 'pass' } else { 'fail' }) 'Scope available for Ready; absent allowed for Hibernated' 'absent' 'Scope is absent.'
                continue
            }
            if (-not $principalId) {
                Add-Check "rbac-$rg" $scope 'pending' 'Known identity principal' $null 'Pass -PreviousIdentityPrincipalId to verify external grants after identity deletion.'
                continue
            }
            $assignments = @(Read-AzJson @('role', 'assignment', 'list', '--scope', $scope, '--include-inherited'))
            $owned = @($assignments | Where-Object principalId -EQ $principalId)
            $observed = @($owned | ForEach-Object { ($_.roleDefinitionId -split '/')[-1] })
            if ($DesiredState -eq 'Hibernated') {
                Add-Check "rbac-$rg" $scope $(if ($owned.Count) { 'fail' } else { 'pass' }) @() $observed 'External SRE identity grants must be absent.'
            } else {
                if ($skin.sre.accessLevel -eq 'High' -and '749f88d5-cbae-40b8-bcfc-e573ddc772fa' -in $observed) {
                    Add-Check "legacy-monitoring-contributor-$rg" $scope 'pass' 'Preserve existing demo compatibility grant, do not create' 'Monitoring Contributor present' 'Existing inherited/direct grant tolerated for High; hibernation includes identity-owned cleanup.' $false
                    $observed = @($observed | Where-Object { $_ -ne '749f88d5-cbae-40b8-bcfc-e573ddc772fa' })
                }
                $missingRoles = @($expectedRoles | Where-Object { $_ -notin $observed })
                $extraRoles = @($observed | Where-Object { $_ -notin $expectedRoles })
                $valid = -not $missingRoles.Count -and -not $extraRoles.Count -and $observed.Count -eq $expectedRoles.Count
                Add-Check "rbac-$rg" $scope $(if ($valid) { 'pass' } else { 'fail' }) $expectedRoles $observed 'Checks missing/excess/duplicate grants, including inherited grants; never revokes roles.'
            }
        }
    } catch {
        Add-Check 'inspection-error' '' 'fail' 'Successful explicit-context inspection' $null $_.Exception.Message
    }
    $status = if (@($checks | Where-Object { $_.required -and $_.status -eq 'fail' }).Count) { 'fail' } elseif (@($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count) { 'pending' } else { 'pass' }
    [pscustomobject][ordered]@{
        schemaVersion = 1; workload = 'sre-agent'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceGroups = $groups
        desiredState = $DesiredState; status = $status; checks = @($checks.ToArray())
    }
}
Export-ModuleMember -Function Get-SreReadinessReport
