Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRelease.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreActs.psm1')

# Protocol contracts and re-pin/fallback procedure: docs/sre-response-plan-automation.md.
$script:TemplateRevision = 'ff317310cca5894fcd42ccc32f5452c3f408cc3c'

function Get-SreDesiredConfiguration {
    param([string]$SubscriptionId, [string]$TenantId, [string]$SkinPath = '')
    Assert-SreContextIds -SubscriptionId $SubscriptionId -TenantId $TenantId
    $skin = Get-DemoSkin -Path $SkinPath
    $prefix = $skin.azure.namePrefix
    $scenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
    $tokens = @{
        arcGroup = "rg-$prefix"; infraGroup = "rg-$prefix-infra"; containerApp = "ca-$prefix-fault"
        eventSource = $skin.labels.lobEventSource
        arcMachineId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.HybridCompute/machines/$($skin.sre.targetArcMachine)"
        workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.OperationalInsights/workspaces/law-$prefix"
        sourceContext = if ($skin.codeContext.lobRepositoryUrl) {
            "Source context is optional: $($skin.codeContext.lobRepositoryUrl) at $($skin.codeContext.lobSourceCommit), path $($skin.codeContext.lobSourcePath)."
        } else {
            'No external source repository is configured. Use authorized telemetry; source contents and repository access are unverified.'
        }
    }
    $instructions = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\config\sre-handler.instructions.txt') -Raw
    if ('SQL' -in $scenarios) {
        $tokens.sqlMachineId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.HybridCompute/machines/$($skin.sre.sqlTargetArcMachine)"
        $tokens.sqlWorkspaceId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.OperationalInsights/workspaces/law-$prefix"
        $tokens.sqlEventSource = $skin.labels.sqlEventSource
        $instructions += "`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\config\sre-sql.instructions.txt') -Raw)
    }
    if ('ARC' -in $scenarios) {
        # The base text keeps Windows investigations read-only. With the ARC module the agent may also propose one Run Command, so the sentence after
        # the read-only rule names the one exception and a closing paragraph holds the policy. A skin without ARC gets the base text unchanged.
        $anchor = 'Recommend human checks, not unapproved actions.'
        if (-not $instructions.Contains($anchor)) { throw 'The base handler no longer has the governance sentence the ARC module extends. Update Get-SreDesiredConfiguration.' }
        $instructions = $instructions.Replace($anchor, 'The one exception to this read-only rule is the Arc application recovery policy below. ' + $anchor)
        $eol = if ($instructions.Contains("`r`n")) { "`r`n" } else { "`n" }
        $tokens.arcMachineName = [string]$skin.sre.targetArcMachine
        $instructions += "`n" + ((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\config\acts\arc\handler.instructions.txt') -Raw) -replace "`r?`n", $eol)
    }
    foreach ($key in $tokens.Keys) { $instructions = $instructions.Replace("{$key}", $tokens[$key]) }
    $plans = @()
    foreach ($scenario in $scenarios) {
        if ($scenario -notin @('T09', 'T11', 'SQL')) { continue }
        $name = switch ($scenario) { 'T09' { $skin.labels.containerResponsePlan }; 'T11' { $skin.labels.lobResponsePlan }; 'SQL' { $skin.labels.sqlResponsePlan } }
        $title = switch ($scenario) { 'T09' { 'containerapp-restarts' }; 'T11' { $skin.labels.lobAlertTitleContains }; 'SQL' { $skin.labels.sqlAlertTitleContains } }
        $service = if ($scenario -eq 'T09') { 'Azure Container Apps' } else { 'Azure Arc' }
        # With ARC the LOB plan runs with the cooldown off, like T12's, so a rehearsal's repeat fault opens a new thread instead of merging into a resolved one.
        $merge = -not ($scenario -eq 'T11' -and 'ARC' -in $scenarios)
        $plans += @{
            scenario = $scenario; name = $name; type = 'IncidentFilter'; tags = @()
            properties = @{
                incidentPlatform = 'AzMonitor'; priorities = @('Sev2'); titleContains = $title
                impactedService = $service; handlingAgent = $skin.labels.agentName
                agentMode = 'Review'; isEnabled = $true
                mergeEnabled = $merge; mergeWindowHours = 3
            }
        }
        if (@($plans | ForEach-Object { $_.name } | Select-Object -Unique).Count -ne $plans.Count) { throw 'Required scenarios must use distinct response-plan names.' }
    }
    for ($i = 0; $i -lt $plans.Count; $i++) {
        for ($j = $i + 1; $j -lt $plans.Count; $j++) {
            $left = $plans[$i].properties.titleContains
            $right = $plans[$j].properties.titleContains
            if ($left.IndexOf($right, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $right.IndexOf($left, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw 'Required response-plan title keywords overlap; review the explicit routing scope.'
            }
        }
    }
    $release = $null
    $needsBaseHandler = @($scenarios | Where-Object { $_ -in @('T09', 'T10', 'T11', 'SQL') }).Count -gt 0
    if ('T12' -in $scenarios) {
        $release = Get-SreReleaseDesired -Skin $skin -SubscriptionId $SubscriptionId
        $plans += $release.plan
        for ($i = 0; $i -lt $plans.Count - 1; $i++) {
            $left = $plans[$i].properties.titleContains
            $right = $release.plan.properties.titleContains
            if ($left.IndexOf($right, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $right.IndexOf($left, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw 'Required response-plan title keywords overlap; review the explicit routing scope.'
            }
        }
        if (@($plans | ForEach-Object { $_.name } | Select-Object -Unique).Count -ne $plans.Count) { throw 'Required scenarios must use distinct response-plan names.' }
    }
    $acts = Get-SreActsDesired -Skin $skin -SubscriptionId $SubscriptionId
    $extraHandlers = @()
    if ($release) { $extraHandlers += $release.handler }
    if ($acts) { $extraHandlers += @($acts.agents) }
    @{
        schemaVersion = 2; kind = 'SreDesiredConfiguration'; sourceRevision = $script:TemplateRevision
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroup = "rg-$prefix-sre"; agentName = $skin.labels.agentName
        requiredScenarios = $scenarios
        handler = if ($needsBaseHandler) {
            @{
                name = $skin.labels.agentName; type = 'ExtendedAgent'; tags = @()
                properties = @{
                    instructions = $instructions
                    handoffDescription = 'Review-mode incident investigation; governed Container App recovery and diagnostic-only Windows application/SQL analysis.'
                    handoffs = @(); tools = @('RunAzCliReadCommands', 'RunAzCliWriteCommands', 'QueryLogAnalyticsByWorkspaceId', 'SearchMemory')
                    enableSkills = $true
                }
            }
        } else { $null }
        extraHandlers = $extraHandlers
        plans = $plans
        release = if ($release) {
            [ordered]@{ settings = $release.settings; skills = $release.skills; hook = $release.hook; policy = $release.policy; guard = $release.guard; repository = $release.repository }
        } else { $null }
        acts = $acts
    }
}

function ConvertTo-SreCanonicalJson {
    param([AllowNull()][object]$Value)
    function Sort-Value($Item) {
        if ($null -eq $Item -or $Item -is [string] -or $Item -is [ValueType]) { return $Item }
        if ($Item -is [Collections.IDictionary]) {
            $sorted = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object)) { $sorted[$key] = Sort-Value $Item[$key] }
            return $sorted
        }
        $items = @($Item | ForEach-Object { Sort-Value $_ })
        return ,$items
    }
    ConvertTo-Json -InputObject (Sort-Value $Value) -Depth 100 -Compress
}

function Test-SreProperties {
    param([Collections.IDictionary]$Actual, [Collections.IDictionary]$Expected)
    foreach ($key in $Expected.Keys) {
        if ($key -in @('agentMode', 'incidentPlatform') -and $Actual.Contains($key) -and $Actual[$key] -ieq $Expected[$key]) { continue }
        if (-not $Actual.Contains($key) -or
            (ConvertTo-SreCanonicalJson $Actual[$key]) -cne (ConvertTo-SreCanonicalJson $Expected[$key])) { return $false }
    }
    return $true
}

function Get-SreComparableJson {
    param([AllowNull()][object]$Value, [switch]$IgnoreVersionToken)
    if ($null -eq $Value) { return 'null' }
    $copy = $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    foreach ($key in @('_etag', 'updatedAt', 'createdAt')) { $null = $copy.Remove($key) }
    if ($IgnoreVersionToken) { $null = $copy.Remove('etag') }
    if ($copy.Contains('properties')) {
        foreach ($key in @('updatedAt', 'createdAt', 'configurationWarning')) { $null = $copy.properties.Remove($key) }
        if ($IgnoreVersionToken) {
            foreach ($key in @('etag', '_etag')) { $null = $copy.properties.Remove($key) }
        }
    }
    ConvertTo-SreCanonicalJson $copy
}

function New-SreConfigurationSession {
    param([Collections.IDictionary]$Desired, [ValidateRange(1, 600)][int]$TimeoutSeconds = 180)
    Assert-SreContext -SubscriptionId $Desired.subscriptionId -TenantId $Desired.tenantId | Out-Null
    $id = "/subscriptions/$($Desired.subscriptionId)/resourceGroups/$($Desired.resourceGroup)/providers/Microsoft.App/agents/$($Desired.agentName)"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $parent = Invoke-SreAz -SubscriptionId $Desired.subscriptionId -Arguments @('resource', 'show', '--ids', $id, '--api-version', '2025-05-01-preview', '-o', 'json') |
            ConvertFrom-Json -AsHashtable
        if ($parent.properties.provisioningState -eq 'Failed') { throw 'SRE parent provisioning failed; configuration was not changed.' }
        if ($parent.properties.provisioningState -eq 'Succeeded' -and $parent.properties.runningState -eq 'Running') { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'SRE parent readiness deadline exceeded; configuration was not changed.' }
        Start-Sleep -Seconds 2
    } while ($true)
    if ($parent.properties.actionConfiguration.mode -ne 'Review') {
        throw 'SRE parent must already be in Review mode; configuration does not change parent autonomy.'
    }
    $endpoint = [uri]$parent.properties.agentEndpoint
    if (-not $endpoint -or -not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or
        -not $endpoint.Host.EndsWith('.azuresre.ai', [StringComparison]::OrdinalIgnoreCase) -or
        $endpoint.UserInfo -or -not $endpoint.IsDefaultPort) { throw 'Invalid SRE endpoint returned by the explicit parent resource.' }
    $token = Invoke-SreAz -SubscriptionId $Desired.subscriptionId -Arguments @('account', 'get-access-token', '--resource', 'https://azuresre.dev', '--query', 'accessToken', '-o', 'tsv')
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'SRE data-plane token is missing. Sign in explicitly; no grants or account selection were changed.' }
    @{
        endpoint = $endpoint.GetLeftPart([UriPartial]::Authority); token = $token; resourceId = $id
        deadlineUtc = $deadline
    }
}

function Invoke-SreConfigurationRequest {
    param([Collections.IDictionary]$Session, [ValidateSet('Get', 'Put')][string]$Method,
        [string]$Path, [AllowNull()][object]$Body)
    if ($Path -notmatch '^/api/(v2/extendedAgent/(agents|incidentFilters)|v1/incidentPlayground/handlers)(/[A-Za-z0-9_.%~-]+)?$') {
        throw 'Only the pinned official handler/filter routes are permitted.'
    }
    if ($Method -eq 'Put' -and $Path -like '/api/v1/*') { throw 'Legacy response handlers are read-only; no migration or guessed update is supported.' }
    $remaining = [int][Math]::Floor(($Session.deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) { throw 'SRE configuration deadline exceeded; inspect read-back before retrying.' }
    $parameters = @{
        Uri = $Session.endpoint + $Path; Method = $Method; TimeoutSec = [Math]::Min(25, $remaining)
        Headers = @{ Authorization = "Bearer $($Session.token)" }; ErrorAction = 'Stop'
    }
    if ($Method -eq 'Put') {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $remaining = [int][Math]::Floor(($Session.deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) { throw 'SRE configuration deadline exceeded during request.' }
            $parameters.TimeoutSec = [Math]::Min(25, $remaining)
            $response = Invoke-RestMethod @parameters
            break
        } catch {
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ([DateTime]::UtcNow -ge $Session.deadlineUtc -or $Method -ne 'Get' -or $attempt -eq 3 -or
                ($status -ne 0 -and $status -notin @(404, 408, 409, 429) -and $status -lt 500)) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if ($null -eq $response) {
        if ($Method -eq 'Get') { throw "Empty SRE GET response at $Path; absence is not verified." }
        return
    }
    return ,(ConvertTo-Json -InputObject $response -Depth 100 | ConvertFrom-Json -AsHashtable -NoEnumerate)
}

function Get-SreConfigurationSnapshot {
    param([Collections.IDictionary]$Session)
    $result = @{
        schemaVersion = 1; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceRevision = $script:TemplateRevision; resourceId = $Session.resourceId
    }
    foreach ($entry in @(@('subagents', '/api/v2/extendedAgent/agents'), @('filters', '/api/v2/extendedAgent/incidentFilters'), @('handlers', '/api/v1/incidentPlayground/handlers'))) {
        $raw = Invoke-SreConfigurationRequest -Session $Session -Method Get -Path $entry[1]
        if ($raw -is [Collections.IDictionary]) {
            if (-not $raw.Contains('value')) { throw "Unexpected SRE list schema for $($entry[0]); refusing to infer absence." }
            if ($raw.Contains('nextLink') -and $raw.nextLink) { throw "SRE $($entry[0]) list is paginated; full conflict/absence verification is required before apply." }
            if ($raw.value -isnot [array]) { throw "SRE $($entry[0]) value is not an array; absence is not verified." }
            $result[$entry[0]] = @($raw.value)
        } else {
            $result[$entry[0]] = @($raw)
        }
    }
    return $result
}

function Get-SreConfigurationPlan {
    param([Collections.IDictionary]$Desired, [Collections.IDictionary]$Snapshot)
    $operations = [Collections.Generic.List[object]]::new()
    $ownedNames = @($Desired.plans | ForEach-Object { $_.name })
    $conflicts = @($Snapshot.filters | Where-Object { $_.properties.isEnabled -and $_.name -notin $ownedNames })
    if ($conflicts.Count) { throw "Unowned enabled routing requires review: $($conflicts.name -join ', '). No plans were changed." }
    foreach ($handler in @(@($Desired.handler) + @($Desired.extraHandlers) | Where-Object { $_ })) {
        $matches = @($Snapshot.subagents | Where-Object name -CEQ $handler.name)
        if ($matches.Count -gt 1) { throw "Duplicate custom handler $($handler.name)." }
        $before = if ($matches.Count) { $matches[0] } else { $null }
        if ($before -and $before.properties.Contains('instructionsOverride') -and $before.properties.instructionsOverride) {
            throw 'Existing custom handler has instructionsOverride; review it explicitly before reconciliation.'
        }
        $after = if ($before) { $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable } else { $handler | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
        foreach ($key in $handler.properties.Keys) { $after.properties[$key] = $handler.properties[$key] }
        if (-not $before -or -not (Test-SreProperties $before.properties $handler.properties)) {
            $operations.Add(@{ collection = 'subagents'; method = 'Put'; path = "/api/v2/extendedAgent/agents/$([uri]::EscapeDataString($after.name))"; name = $after.name; before = $before; after = $after })
        }
    }
    foreach ($plan in $Desired.plans) {
        $matches = @($Snapshot.filters | Where-Object name -CEQ $plan.name)
        if ($matches.Count -gt 1) { throw "Duplicate incident filter $($plan.name)." }
        $before = if ($matches.Count) { $matches[0] } else { $null }
        if ($before -and @($before.properties.priorities | Where-Object { $_ -notmatch '^Sev[0-4]$' }).Count) {
            throw 'Legacy priorities are not migrated. No objects were written; follow docs/sre-response-plan-automation.md for supported manual setup or a rebuild.'
        }
        $handlers = @($Snapshot.handlers | Where-Object { $_.incidentFilterId -ceq $plan.name -and -not $_['isDeleted'] })
        if ($handlers.Count -gt 1) { throw "Multiple response handlers for $($plan.name); review before apply." }
        foreach ($handler in $handlers) {
            $hasLegacy = $handler.customInstructions -or @($handler.tools).Count -or @($handler.incidentProcessingGuide).Count
            if ($hasLegacy) {
                throw 'Legacy response settings are not migrated. No objects were written; follow docs/sre-response-plan-automation.md for supported manual setup or a rebuild.'
            }
        }
        $after = if ($before) { $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable } else { $plan | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
        $null = $after.Remove('scenario')
        foreach ($key in @('createdAt', 'updatedAt', 'configurationWarning')) { $null = $after.properties.Remove($key) }
        foreach ($key in $plan.properties.Keys) { $after.properties[$key] = $plan.properties[$key] }
        if (-not $before -or -not (Test-SreProperties $before.properties $plan.properties)) {
            $operations.Add(@{ collection = 'filters'; method = 'Put'; path = "/api/v2/extendedAgent/incidentFilters/$([uri]::EscapeDataString($plan.name))"; name = $plan.name; before = $before; after = $after })
        }
    }
    @{ operations = @($operations.ToArray()) }
}

function Find-SreConfigurationObject {
    param([Collections.IDictionary]$Snapshot, [Collections.IDictionary]$Operation)
    $matches = @($Snapshot[$Operation.collection] | Where-Object { $_.name -ceq $Operation.name })
    if ($matches.Count -gt 1) { throw "Ambiguous read-back for $($Operation.name)." }
    if ($matches.Count) { return $matches[0] }
    return $null
}

function Wait-SreConfigurationReadBack {
    param([Collections.IDictionary]$Session, [Collections.IDictionary]$Desired,
        [AllowNull()][Collections.IDictionary]$Operation)
    $readSession = @{}
    foreach ($key in $Session.Keys) { $readSession[$key] = $Session[$key] }
    $limit = [DateTime]::UtcNow.AddMinutes(5)
    if ($readSession.deadlineUtc -gt $limit) { $readSession.deadlineUtc = $limit }
    $delay = 2
    $expectedProperties = @{}
    if ($Operation) {
        foreach ($key in $Operation.after.properties.Keys) {
            if ($key -notin @('etag', '_etag')) { $expectedProperties[$key] = $Operation.after.properties[$key] }
        }
    }
    do {
        $snapshot = Get-SreConfigurationSnapshot $readSession
        $plan = Get-SreConfigurationPlan $Desired $snapshot
        if ($Operation) {
            $observed = Find-SreConfigurationObject $snapshot $Operation
            if ($null -ne $observed -and (Test-SreProperties $observed.properties $expectedProperties)) {
                return $snapshot
            }
            if ((Get-SreComparableJson $observed -IgnoreVersionToken) -cne
                (Get-SreComparableJson $Operation.before -IgnoreVersionToken)) {
                throw "Ambiguous/partial update for $($Operation.name); inspect the saved backup and current state. PUT was not replayed."
            }
        } elseif (-not $plan.operations.Count) {
            return $snapshot
        }
        $remaining = ($readSession.deadlineUtc - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($delay, [Math]::Ceiling($remaining)))
        $delay = [Math]::Min(20, $delay * 2)
    } while ([DateTime]::UtcNow -lt $readSession.deadlineUtc)
    throw 'SRE configuration read-back deadline exceeded; desired state remains unverified. No PUT was replayed. Keep the backup and inspect before you apply again.'
}

function Set-SreConfigurationOperation {
    param([Collections.IDictionary]$Session, [Collections.IDictionary]$Operation, [Collections.IDictionary]$Desired)
    if ($Operation.method -ne 'Put') { throw 'Only named current-schema PUT operations are supported; no write attempted.' }
    $snapshot = Get-SreConfigurationSnapshot $Session
    $ownedNames = @($Desired.plans | ForEach-Object { $_.name })
    if (@($snapshot.filters | Where-Object { $_.properties.isEnabled -and $_.name -notin $ownedNames }).Count) {
        throw 'Concurrent routing change: unowned enabled filter appeared during reconciliation; stop with the saved backup.'
    }
    $current = Find-SreConfigurationObject $snapshot $Operation
    if ((Get-SreComparableJson $current) -cne (Get-SreComparableJson $Operation.before)) {
        throw "Concurrent change detected for $($Operation.name); stop and create a new backup/preview."
    }
    try { Invoke-SreConfigurationRequest -Session $Session -Method Put -Path $Operation.path -Body $Operation.after | Out-Null }
    catch {
        $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -in @(400, 401, 403, 404) -or ($status -ge 400 -and $status -lt 500 -and $status -notin @(408, 429))) {
            throw
        }
        Write-Warning "PUT outcome for $($Operation.name) is ambiguous: $($_.Exception.Message). Verifying with read-only polling; the PUT will not be replayed."
    }
    $verified = Wait-SreConfigurationReadBack -Session $Session -Desired $Desired -Operation $Operation
    return Find-SreConfigurationObject $verified $Operation
}

function Invoke-SreConfigurationReconcile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Collections.IDictionary]$Desired, [Collections.IDictionary]$Session,
        [Parameter(Mandatory)][string]$BackupPath)
    $before = Get-SreConfigurationSnapshot $Session
    $plan = Get-SreConfigurationPlan $Desired $before
    if (-not $plan.operations.Count) { return @{ changed = $false; verified = $true; operations = @() } }
    if (-not $PSCmdlet.ShouldProcess($Session.resourceId, "Back up and reconcile $($plan.operations.Count) named SRE configuration objects (Review only, no delete)")) {
        return @{ changed = $false; verified = $false; preview = $plan }
    }
    $fullPath = [IO.Path]::GetFullPath($BackupPath)
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backups contain runtime configuration; choose a path outside the repository.' }
    if (-not (Test-Path -LiteralPath (Split-Path $fullPath -Parent) -PathType Container)) { throw 'Backup parent directory must already exist.' }
    $json = $before | ConvertTo-Json -Depth 100
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    foreach ($operation in $plan.operations) {
        Set-SreConfigurationOperation -Session $Session -Operation $operation -Desired $Desired | Out-Null
    }
    $after = Wait-SreConfigurationReadBack -Session $Session -Desired $Desired
    @{ changed = $true; verified = $true; backupPath = $fullPath; before = $before; after = $after; operations = @($plan.operations | ForEach-Object { $_.path }) }
}

Export-ModuleMember -Function Get-SreDesiredConfiguration, New-SreConfigurationSession, Get-SreConfigurationSnapshot, Get-SreConfigurationPlan, Invoke-SreConfigurationReconcile, Test-SreProperties
