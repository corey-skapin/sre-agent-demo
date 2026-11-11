Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreConfiguration.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRelease.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreDataPlane.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreReleaseExtras.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreActsExtras.psm1')

function Get-SreSqlAlertQuery {
    param([string]$MachineResourceId)
    $hostId = $MachineResourceId.ToLowerInvariant()
    @"
Event
| where TimeGenerated > ago(15m)
| where tolower(_ResourceId) == '$hostId'
| where Source == 'ArcSqlEngineDemo' and EventID == 6201
| extend Incident = parse_json(RenderedDescription)
| where toint(Incident.schemaVersion) == 2
| where tostring(Incident.state) == 'detected'
| where toint(Incident.sqlErrorNumber) == 1222
| project TimeGenerated, Computer, _ResourceId, Incident
"@
}

function Test-SreSqlAlertDefinition {
    param([object]$Alert, [string]$AlertId, [string]$MachineResourceId,
        [string]$WorkspaceId, [string]$ActionGroupId, [string]$DisplayName)
    $definition = $Alert | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
    if ($definition -isnot [Collections.IDictionary]) { return $false }
    $p = $definition['properties']
    if ($p -isnot [Collections.IDictionary] -or $p['criteria'] -isnot [Collections.IDictionary] -or
        $p['actions'] -isnot [Collections.IDictionary] -or $definition['tags'] -isnot [Collections.IDictionary]) { return $false }
    $conditions = @($p.criteria['allOf'])
    if ($conditions.Count -ne 1 -or $conditions[0] -isnot [Collections.IDictionary] -or
        $conditions[0]['failingPeriods'] -isnot [Collections.IDictionary]) { return $false }
    $criterion = $conditions[0]
    $actualQuery = ([string]$criterion['query'] -replace '\s+', ' ').Trim()
    $expectedQuery = ((Get-SreSqlAlertQuery -MachineResourceId $MachineResourceId) -replace '\s+', ' ').Trim()
    $scopes = @($p['scopes'])
    $groups = @($p.actions['actionGroups'])
    return ($definition['id'] -ieq $AlertId -and
        $definition.tags['managedBy'] -ceq 'arc-demo-sql-incident' -and $definition.tags['workload'] -ceq 'sql-lock-timeout' -and
        $p['enabled'] -eq $true -and $p['severity'] -eq 2 -and $p['displayName'] -ceq $DisplayName -and
        $p['evaluationFrequency'] -ceq 'PT1M' -and $p['windowSize'] -ceq 'PT15M' -and $p['autoMitigate'] -eq $true -and
        $scopes.Count -eq 1 -and $scopes[0] -ieq $WorkspaceId -and
        $groups.Count -eq 1 -and $groups[0] -ieq $ActionGroupId -and
        $criterion['timeAggregation'] -ceq 'Count' -and $criterion['operator'] -ceq 'GreaterThan' -and $criterion['threshold'] -eq 0 -and
        $criterion.failingPeriods['numberOfEvaluationPeriods'] -eq 1 -and $criterion.failingPeriods['minFailingPeriodsToAlert'] -eq 1 -and
        $actualQuery -ceq $expectedQuery)
}

function Get-SreReadinessReport {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId, [string]$TenantId, [string]$SkinPath = '',
        [ValidateSet('Active', 'Ready', 'Hibernated', 'Removed')][string]$DesiredState = 'Ready',
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
        $release = $null
        $releaseGrants = @()
        if (Test-SreReleaseScenario -Skin $skin) {
            $release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $SubscriptionId
            $releaseGrants = @(Get-SreReleaseKnownGrants -Settings $release)
            $groups += $release.resourceGroup
        }
        $base = "/subscriptions/$SubscriptionId/resourceGroups"
        $sreGroupId = "$base/$($groups[0])"
        $agentId = "$sreGroupId/providers/Microsoft.App/agents/$($skin.labels.agentName)"
        $identityId = "$sreGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($skin.labels.agentName)-uami"
        $expectedRoles = if ($skin.sre.accessLevel -eq 'High') {
            @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
        } else {
            @('73c42c96-874c-492b-b04d-ab87d138a893', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
        }
        $exists = Read-AzJson @('group', 'exists', '-n', $groups[0])
        $principalId = $PreviousIdentityPrincipalId
        $agent = $null
        $monitorConnected = $false
        if ($exists) {
            $resources = @(Read-AzJson @('resource', 'list', '-g', $groups[0]))
            if (@($resources | Where-Object id -EQ $identityId).Count) {
                $identity = Read-AzJson @('identity', 'show', '--ids', $identityId)
                if ($PreviousIdentityPrincipalId -and $PreviousIdentityPrincipalId -ne $identity.principalId) { throw 'Previous principal differs from retained live identity.' }
                $principalId = $identity.principalId
            }
            if (@($resources | Where-Object id -EQ $agentId).Count) {
                $agent = Read-AzJson @('resource', 'show', '--ids', $agentId)
            }
        }
        if ($DesiredState -in @('Hibernated', 'Removed')) {
            $lifecycle = Get-SreLifecycleInventory -SubscriptionId $SubscriptionId -SreResourceGroupName $groups[0] `
                -AgentName $skin.labels.agentName -ArcResourceGroupName $groups[1] -InfraResourceGroupName $groups[2] `
                -PreviousIdentityPrincipalId $PreviousIdentityPrincipalId -KnownGrants $releaseGrants
            $principalId = $lifecycle.principalId
            if ($DesiredState -eq 'Removed') {
                Add-Check 'sre-group-absent' $sreGroupId $(if ($exists) { 'pending' } else { 'pass' }) 'Dedicated SRE group absent' $exists 'Shared Arc groups and private exports are outside Removed scope.'
                Add-Check 'external-grants-absent' $identityId $(if (-not $principalId) { 'pending' } elseif ($lifecycle.externalAssignments.Count) { 'fail' } else { 'pass' }) @() @($lifecycle.externalAssignments | ForEach-Object { $_.id }) 'A saved principal is needed after identity deletion to prove no external assignments remain; absence is not denial.'
                Add-Check 'parent-admin-absent' $agentId $(if ($lifecycle.parentAssignments.Count) { 'fail' } else { 'pass' }) @() @($lifecycle.parentAssignments | ForEach-Object { $_.id }) 'Checks surviving direct parent grants while the group exists.'
            } else {
                Add-Check 'parent-absent' $agentId $(if ($agent) { 'pending' } else { 'pass' }) 'Paid parent absent' $(if ($agent) { $agent.id } else { $null }) 'Stopped still bills; only parent absence establishes the normal cost-saving state.'
                Add-Check 'retained-identity' $identityId $(if ($lifecycle.identity) { 'pass' } else { 'fail' }) 'Dedicated UAMI/group retained with saved principal, if supplied' $principalId 'Normal Hibernate preserves the identity. Old UAMI-only parking is supported; missing state is rebuilt only by a new deployment.'
                $diagnosticIds = @("$sreGroupId/providers/Microsoft.Insights/components/$($skin.labels.agentName)-appi", "$sreGroupId/providers/Microsoft.Insights/actionGroups/Application Insights Smart Detection")
                $presentIds = @($lifecycle.resources | ForEach-Object { $_.id })
                Add-Check 'retained-diagnostics' $sreGroupId $(if (@($diagnosticIds | Where-Object { $_ -notin $presentIds }).Count) { 'pending' } else { 'pass' }) $diagnosticIds $presentIds 'Existing diagnostics are retained, not created by Hibernate. Missing legacy diagnostics are wake information, not a cost-state failure.' $false
                $expectedGrantKeys = @(foreach ($rg in $groups[1..2]) { foreach ($role in $expectedRoles) { "$base/$rg|$role" } }) +
                    @($releaseGrants | ForEach-Object { "$($_.scope)|$($_.roleId)" })
                $platformGrants = @($lifecycle.externalAssignments | Where-Object { Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $principalId })
                $observedGrantKeys = @($lifecycle.externalAssignments | Where-Object { -not (Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $principalId) } | ForEach-Object { "$($_.scope)|$(($_.roleDefinitionId -split '/')[-1])" })
                $extra = @($observedGrantKeys | Where-Object { $_ -notin $expectedGrantKeys })
                $missing = @($expectedGrantKeys | Where-Object { $_ -notin $observedGrantKeys })
                $duplicate = @($observedGrantKeys | Group-Object | Where-Object Count -GT 1)
                Add-Check 'retained-workload-grants' $identityId $(if ($extra.Count -or $duplicate.Count) { 'fail' } elseif ($missing.Count) { 'pending' } else { 'pass' }) $expectedGrantKeys $observedGrantKeys 'Existing grants are retained, not revoked. Missing grants are recreated on wake; excess/duplicate standing access needs explicit reconciliation before Active.' $false
                Add-Check 'retained-platform-grant' $identityId $(if ($platformGrants.Count -gt 1) { 'fail' } else { 'pass' }) 'At most one exact retained subscription Monitoring Contributor grant' @($platformGrants | ForEach-Object { $_.id }) 'Parent absence does not invalidate this platform prerequisite. No grant is created or revoked.' $false
                Add-Check 'parent-scope-grants' $agentId $(if ($lifecycle.parentAssignments.Count) { 'pending' } else { 'pass' }) 'Parent-lifetime grants absent or reconciled before Active' @($lifecycle.parentAssignments | ForEach-Object { $_.id }) 'These belong to the deployer, not the stable UAMI. A stale free entry does not keep the paid parent running.' $false
            }
            Add-Check 'retained-state-drift' $sreGroupId $(if ($lifecycle.drift.Count) { 'fail' } else { 'pass' }) 'No unexpected resources/permissions before Active or Removed' $lifecycle.drift 'Drift is reported without broad deletion; inspection denials still fail the whole report.' ($DesiredState -eq 'Removed')
        } elseif (-not $agent) {
            Add-Check 'parent' $agentId 'fail' 'Succeeded/Running' $null 'Required parent agent is absent; deploy parent then configure data plane.'
        } else {
            $p = $agent.properties
            $running = $p.provisioningState -eq 'Succeeded' -and $p.runningState -eq 'Running'
            Add-Check 'parent' $agentId $(if ($running) { 'pass' } elseif ($p.provisioningState -eq 'Failed') { 'fail' } else { 'pending' }) 'Succeeded/Running' "$($p.provisioningState)/$($p.runningState)" 'Control-plane provisioning and resource running state.'
            Add-Check 'review-mode' $agentId $(if ($p.actionConfiguration.mode -eq 'Review') { 'pass' } else { 'fail' }) 'Review' $p.actionConfiguration.mode 'Parent mode does not prove response-plan mode.'
            Add-Check 'access-level' $agentId $(if ($p.actionConfiguration.accessLevel -eq $skin.sre.accessLevel) { 'pass' } else { 'fail' }) $skin.sre.accessLevel $p.actionConfiguration.accessLevel 'Requested skin access profile.'
            $incidentConfiguration = $p.PSObject.Properties['incidentManagementConfiguration']
            $platformType = if ($incidentConfiguration -and $incidentConfiguration.Value) { $incidentConfiguration.Value.PSObject.Properties['type'] }
            $incidentPlatform = if ($platformType) { [string]$platformType.Value } else { '' }
            $monitorConnected = $incidentPlatform -eq 'AzMonitor'
            $platformMessage = if ($monitorConnected) { 'ARM selects Azure Monitor. Check azure-monitor-alert-access separately; selection is not scanner health or alert-delivery proof.' } else { 'WARNING: ARM does not select Azure Monitor. Use the documented portal fallback; retained access alone does not establish connectivity.' }
            Add-Check 'incident-platform' $agentId $(if ($monitorConnected) { 'pass' } else { 'pending' }) 'AzMonitor' $incidentPlatform $platformMessage $false
            if (-not $monitorConnected) { Write-Warning $platformMessage }
            $attachedIdentityIds = @($agent.identity.userAssignedIdentities.PSObject.Properties.Name)
            $identityMatches = $principalId -and $p.actionConfiguration.identity -eq $identityId -and $p.knowledgeGraphConfiguration.identity -eq $identityId -and $identityId -in $attachedIdentityIds
            Add-Check 'identity' $identityId $(if ($identityMatches) { 'pass' } else { 'fail' }) $identityId $p.actionConfiguration.identity 'Action and knowledge graph must use the live user-assigned identity.'
            Add-Check 'parent-identity-type' $agentId $(if (($agent.identity.type -replace '\s', '') -eq 'SystemAssigned,UserAssigned') { 'pass' } else { 'fail' }) 'SystemAssigned,UserAssigned' $agent.identity.type 'Validated service compatibility shape; no external workload roles are assigned to the system identity by this repo.'
            $expectedManaged = @("$base/$($groups[1])", "$base/$($groups[2])", "$base/$($groups[1])/providers/Microsoft.OperationalInsights/workspaces/law-$prefix", "$base/$($groups[1])/providers/Microsoft.Insights/actionGroups/ag-$prefix")
            $scenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
            if ('T09' -in $scenarios) { $expectedManaged += "$base/$($groups[2])/providers/Microsoft.App/containerApps/ca-$prefix-fault" }
            if ('T10' -in $scenarios -or 'T11' -in $scenarios) { $expectedManaged += "$base/$($groups[1])/providers/Microsoft.HybridCompute/machines/$($skin.sre.targetArcMachine)" }
            if ('SQL' -in $scenarios -and "$base/$($groups[1])" -notin $p.knowledgeGraphConfiguration.managedResources) {
                $expectedManaged += "$base/$($groups[1])/providers/Microsoft.HybridCompute/machines/$($skin.sre.sqlTargetArcMachine)"
            }
            if ($release) { $expectedManaged += $release.groupId }
            $missing = @($expectedManaged | Where-Object { $_ -notin $p.knowledgeGraphConfiguration.managedResources })
            Add-Check 'managed-resources' $agentId $(if ($missing.Count) { 'fail' } else { 'pass' }) $expectedManaged $p.knowledgeGraphConfiguration.managedResources "Missing managed IDs: $($missing -join ', ')"
            foreach ($scenario in $scenarios) {
                if ($scenario -eq 'T09') {
                    $appId = "$base/$($groups[2])/providers/Microsoft.App/containerApps/ca-$prefix-fault"
                    try {
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
                    } catch {
                        Add-Check 'T09-resource-health' $appId 'fail' 'Readable Container App and serving revisions' $null $_.Exception.Message
                    }
                    $alertId = "$base/$($groups[2])/providers/Microsoft.Insights/metricAlerts/alert-$prefix-containerapp-restarts"
                    try {
                    $alert = Read-AzJson @('monitor', 'metrics', 'alert', 'show', '-g', $groups[2], '-n', "alert-$prefix-containerapp-restarts")
                    $alertHealthy = $alert.enabled -and $alert.severity -eq 2 -and $appId -in $alert.scopes
                    Add-Check 'T09-alert' $alert.id $(if ($alertHealthy) { 'pass' } else { 'fail' }) 'Enabled Sev2, Container App scope' $alert.enabled 'Azure Monitor signal configuration, not firing-state proof.'
                    } catch {
                        Add-Check 'T09-alert' $alertId 'fail' 'Readable enabled Sev2 metric alert' $null $_.Exception.Message
                    }
                } elseif ($scenario -eq 'T12') {
                    foreach ($check in @(Get-SreReleaseReadinessChecks -SubscriptionId $SubscriptionId -Settings $release)) {
                        Add-Check $check.id $check.resourceId $check.status $check.expected $check.observed $check.message $check.required
                    }
                } else {
                    $machineName = if ($scenario -eq 'SQL') { $skin.sre.sqlTargetArcMachine } else { $skin.sre.targetArcMachine }
                    $expectedMachineId = "$base/$($groups[1])/providers/Microsoft.HybridCompute/machines/$machineName"
                    try {
                    $machine = Read-AzJson @('connectedmachine', 'show', '-g', $groups[1], '-n', $machineName)
                    $machineStatus = if ($scenario -eq 'SQL' -and $machine.id -ine $expectedMachineId) { 'fail' } elseif ($machine.status -eq 'Connected') { 'pass' } else { 'pending' }
                    Add-Check "$scenario-resource-health" $expectedMachineId $machineStatus 'Connected intended Arc host' $machine.status 'Arc connection only; guest app/SQL engine/telemetry verification remains separate.'
                    } catch {
                        Add-Check "$scenario-resource-health" $expectedMachineId 'fail' 'Readable connected intended Arc host' $null $_.Exception.Message
                    }
                    if ($scenario -eq 'T11') {
                        $alertId = "$base/$($groups[1])/providers/Microsoft.Insights/scheduledQueryRules/alert-$prefix-lob-arc-app-fault"
                        try {
                        $alert = Read-AzJson @('resource', 'show', '--ids', $alertId)
                        $ap = $alert.properties
                        $alertHealthy = $ap.enabled -and $ap.severity -eq 2 -and $ap.displayName.Contains($skin.labels.lobAlertTitleContains)
                        Add-Check 'T11-alert' $alertId $(if ($alertHealthy) { 'pass' } else { 'fail' }) "Enabled Sev2, title contains $($skin.labels.lobAlertTitleContains)" $ap.displayName 'Literal title keyword must align with the intended plan; region changes are not implied.'
                        } catch {
                            Add-Check 'T11-alert' $alertId 'fail' 'Readable enabled Sev2 LOB alert with the skin title' $null $_.Exception.Message
                        }
                    }
                    if ($scenario -eq 'SQL') {
                        $alertId = "$base/$($groups[1])/providers/Microsoft.Insights/scheduledQueryRules/al-$prefix-sql-lock-timeout"
                        try {
                        $alert = Read-AzJson @('resource', 'show', '--ids', $alertId)
                        $alertHealthy = Test-SreSqlAlertDefinition -Alert $alert -AlertId $alertId -MachineResourceId $expectedMachineId `
                            -WorkspaceId "$base/$($groups[1])/providers/Microsoft.OperationalInsights/workspaces/law-$prefix" `
                            -ActionGroupId "$base/$($groups[1])/providers/Microsoft.Insights/actionGroups/ag-$prefix" `
                            -DisplayName "$($skin.labels.sqlAlertTitleContains) - $prefix"
                        Add-Check 'SQL-alert' $alertId $(if ($alertHealthy) { 'pass' } else { 'fail' }) 'Owned enabled Sev2, exact SQL host/source/1222 JSON query, LAW/Action Group, PT1M/PT15M, count>0/1of1, autoMitigate' $alert.properties 'Strict source contract with Arc sql-incident-alert.bicep; permits whitespace differences only. Does not prove receiver delivery, current firing state or SQL health.'
                        } catch {
                            Add-Check 'SQL-alert' $alertId 'fail' 'Readable owned SQL lock-timeout alert' $null $_.Exception.Message
                        }
                    }
                }
            }
            $session = $null
            try {
                $desired = Get-SreDesiredConfiguration -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath
                $session = New-SreConfigurationSession -Desired $desired
                $snapshot = Get-SreConfigurationSnapshot $session
                $desiredHandlers = @(@($desired.handler) + @($desired.extraHandlers) | Where-Object { $_ })
                $handlerValid = $true
                $handlerNames = @()
                foreach ($desiredHandler in $desiredHandlers) {
                    $found = @($snapshot.subagents | Where-Object name -CEQ $desiredHandler.name)
                    $oneValid = $found.Count -eq 1 -and (Test-SreProperties $found[0].properties $desiredHandler.properties)
                    if ($oneValid -and $found[0].properties.Contains('instructionsOverride') -and $found[0].properties.instructionsOverride) { $oneValid = $false }
                    $handlerValid = $handlerValid -and $oneValid
                    $handlerNames += @($found | ForEach-Object { $_.name })
                }
                Add-Check 'handler-instructions' $agentId $(if ($handlerValid) { 'pass' } else { 'fail' }) 'Versioned handler instructions and tools, no instructionsOverride' $handlerNames 'Full custom-agent read via pinned official export protocol; names alone are insufficient.'
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
                    $observedPlans += @{ name = $plan.name; mode = $properties.agentMode; enabled = $properties.isEnabled; priorities = $properties.priorities; title = $properties.titleContains; handler = $properties.handlingAgent; mergeEnabled = $properties['mergeEnabled']; mergeWindowHours = $properties['mergeWindowHours'] }
                }
                $activeNames = @($snapshot.filters | Where-Object { $_.properties.isEnabled } | ForEach-Object { $_.name })
                $legacyHandlers = @($snapshot.handlers | Where-Object {
                    $_.incidentFilterId -in $activeNames -and -not $_['isDeleted'] -and
                    ($_.customInstructions -or @($_.tools).Count -or @($_.incidentProcessingGuide).Count)
                } | ForEach-Object { $_.id })
                Add-Check 'plan-status-review' $agentId $(if ($modeValid) { 'pass' } else { 'fail' }) 'Each required existing plan enabled and Review' $observedPlans 'Reads actual plan properties, not MCP summary or parent mode.'
                Add-Check 'plan-filters-handler' $agentId $(if ($filtersValid) { 'pass' } else { 'fail' }) 'AzMonitor, Sev2, single title, intended service/custom agent, merge setting as each plan declares it (cooldown on for the Arc plans, off for T12)' $observedPlans 'P1/P2 are invalid for AzMonitor; legacy MCP high is not Sev2. Cooldown is explicitly repo-managed.'
                Add-Check 'legacy-response-settings' $agentId $(if ($legacyHandlers.Count) { 'fail' } else { 'pass' }) @() $legacyHandlers 'Active routing must not depend on legacy response settings. Retired disabled plans and their history may remain untouched.'
                $owned = @($desired.plans | ForEach-Object { $_.name })
                $extra = @($snapshot.filters | Where-Object { $_.properties.isEnabled -and $_.name -notin $owned } | ForEach-Object { $_.name })
                Add-Check 'routing-conflicts' $agentId $(if ($extra.Count) { 'fail' } else { 'pass' }) 'No unreviewed enabled extra plans' $extra 'Conservatively requires review of every enabled unowned plan; never deletes quickstart automatically.'
                if ($desired.release -or $desired.acts) {
                    $dataContext = ConvertTo-SreDataContext -Session $session -SubscriptionId $SubscriptionId -TenantId $TenantId
                    if ($desired.release) {
                        foreach ($check in @(Get-SreReleaseDataChecks -Context $dataContext -Desired $desired)) {
                            Add-Check $check.id $check.resourceId $check.status $check.expected $check.observed $check.message $check.required
                        }
                    }
                    if ($desired.acts) {
                        foreach ($check in @(Get-SreActsDataChecks -Context $dataContext -Desired $desired)) {
                            Add-Check $check.id $check.resourceId $check.status $check.expected $check.observed $check.message $check.required
                        }
                    }
                }
            } catch {
                Add-Check 'data-plane-inspection' $agentId 'fail' 'Successful supported full configuration read' $null $_.Exception.Message
            } finally {
                if ($session) { $session.token = $null }
            }
            Add-Check 'telemetry-and-alerts' $agentId 'skipped' 'Alert-to-thread/RCA/Review/recovery evidence from an incident run' $null 'Not evaluated: configuration readiness does not certify an incident loop or ingest rehearsal evidence. This read-only command never injects a fault.' $false
            Add-Check 'code-repository-connection' $agentId 'skipped' 'Optional; connect it separately if you want it' $null 'Public source context is not connector authentication.' $false
        }
        if ($DesiredState -in @('Active', 'Ready')) {
            if ($principalId) {
                $allAssignments = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId "/subscriptions/$SubscriptionId" -PrincipalId $principalId)
                $expectedScopes = @("$base/$($groups[1])", "$base/$($groups[2])")
                $platformGrants = @($allAssignments | Where-Object { Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $principalId })
                $excess = @($allAssignments | Where-Object {
                    -not (Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $principalId) -and
                    -not (Test-SreKnownGrant $_ $releaseGrants) -and
                    ($_.principalId -ne $principalId -or $_.scope -notin $expectedScopes -or ($_.roleDefinitionId -split '/')[-1] -notin $expectedRoles)
                })
                Add-Check 'identity-grant-boundary' $identityId $(if ($excess.Count -or $platformGrants.Count -gt 1) { 'fail' } else { 'pass' }) 'Requested workload-group profile plus at most one exact AzMonitor platform grant, and the known T12 grants when T12 is required' @($excess | ForEach-Object { $_.id }) "Exact AzMonitor platform grants: $($platformGrants.Count); excess grants: $($excess.Count). Exact retained subscription Monitoring Contributor is permitted with or without a parent or connected incident platform. No role is created or revoked."
                Add-Check 'azure-monitor-alert-access' $identityId $(if (-not $monitorConnected) { 'skipped' } elseif ($platformGrants.Count -eq 1) { 'pass' } else { 'fail' }) 'One exact platform grant when AzMonitor is selected' @($platformGrants | ForEach-Object { $_.id }) 'Azure Monitor scanning requires subscription Monitoring Contributor. Pass -GrantAzureMonitorAlertAccess to confirm you want that IAM grant; IaC supplies platform selection, not this grant.' $monitorConnected
            }
            foreach ($rg in $groups[1..2]) {
                $scope = "$base/$rg"
                if (-not (Read-AzJson @('group', 'exists', '-n', $rg))) {
                    Add-Check "rbac-$rg" $scope 'fail' 'Scope available for Active' 'absent' 'Scope is absent.'
                    continue
                }
                if (-not $principalId) {
                    Add-Check "rbac-$rg" $scope 'pending' 'Known identity principal' $null 'Required UAMI principal could not be resolved.'
                    continue
                }
                $assignments = @(Read-AzJson @('role', 'assignment', 'list', '--scope', $scope, '--include-inherited', '--fill-principal-name', 'false'))
                $owned = @($assignments | Where-Object { $_.principalId -eq $principalId -and -not (Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $principalId) })
                $observed = @($owned | ForEach-Object { ($_.roleDefinitionId -split '/')[-1] })
                $missingRoles = @($expectedRoles | Where-Object { $_ -notin $observed })
                $extraRoles = @($observed | Where-Object { $_ -notin $expectedRoles })
                $valid = -not $missingRoles.Count -and -not $extraRoles.Count -and $observed.Count -eq $expectedRoles.Count -and @($owned | Where-Object scope -NE $scope).Count -eq 0
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
