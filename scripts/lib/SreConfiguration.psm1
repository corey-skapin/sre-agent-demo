Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')

# Protocol provenance: microsoft/sre-agent at this immutable revision, linked by
# https://learn.microsoft.com/azure/sre-agent/deploy-iac.
$script:TemplateRevision = 'ff317310cca5894fcd42ccc32f5452c3f408cc3c'

function Get-SreDesiredConfiguration {
    param([string]$SubscriptionId, [string]$TenantId, [string]$SkinPath = '')
    Assert-SreContextIds -SubscriptionId $SubscriptionId -TenantId $TenantId
    $skin = Get-DemoSkin -Path $SkinPath
    $prefix = $skin.azure.namePrefix
    $tokens = @{
        arcGroup = "rg-$prefix"; infraGroup = "rg-$prefix-infra"; containerApp = "ca-$prefix-fault"
        arcMachine = $skin.sre.targetArcMachine; eventSource = $skin.labels.lobEventSource
        repositoryUrl = $skin.codeContext.lobRepositoryUrl; sourceCommit = $skin.codeContext.lobSourceCommit
        sourcePath = $skin.codeContext.lobSourcePath
    }
    $instructions = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\config\sre-handler.instructions.txt') -Raw
    foreach ($key in $tokens.Keys) { $instructions = $instructions.Replace("{$key}", $tokens[$key]) }
    $scenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
    $plans = @()
    foreach ($scenario in $scenarios) {
        if ($scenario -notin @('T09', 'T11')) { continue }
        $name = if ($scenario -eq 'T09') { $skin.labels.containerResponsePlan } else { $skin.labels.lobResponsePlan }
        $title = if ($scenario -eq 'T09') { 'containerapp-restarts' } else { $skin.labels.lobAlertTitleContains }
        $service = if ($scenario -eq 'T09') { 'Azure Container Apps' } else { 'Azure Arc' }
        $plans += @{
            scenario = $scenario; name = $name; type = 'IncidentFilter'; tags = @()
            properties = @{
                incidentPlatform = 'AzMonitor'; priorities = @('Sev2'); titleContains = $title
                impactedService = $service; handlingAgent = $skin.labels.agentName
                agentMode = 'Review'; isEnabled = $true
            }
        }
        if (@($plans | ForEach-Object { $_.name } | Select-Object -Unique).Count -ne $plans.Count) { throw 'Required scenarios must use distinct response-plan names.' }
    }
    @{
        schemaVersion = 2; kind = 'SreDesiredConfiguration'; sourceRevision = $script:TemplateRevision
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroup = "rg-$prefix-sre"; agentName = $skin.labels.agentName
        requiredScenarios = $scenarios
        retiredPlanNames = @(Get-DemoSkinValue -Skin $skin -Path 'sre.retiredResponsePlanNames' -Default @())
        handler = @{
            name = $skin.labels.agentName; type = 'ExtendedAgent'; tags = @()
            properties = @{
                instructions = $instructions
                handoffDescription = "$($skin.labels.demoTitle) Review-mode T09 and operator-only hybrid investigation."
                handoffs = @(); tools = @('RunAzCliReadCommands', 'RunAzCliWriteCommands', 'QueryLogAnalyticsByWorkspaceId', 'SearchMemory')
                enableSkills = $true
            }
        }
        plans = $plans
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
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    $copy = $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    foreach ($key in @('_etag', 'updatedAt', 'createdAt')) { $null = $copy.Remove($key) }
    if ($copy.Contains('properties')) {
        foreach ($key in @('updatedAt', 'createdAt', 'configurationWarning')) { $null = $copy.properties.Remove($key) }
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
    $legacy = $false
    $ownedNames = @($Desired.plans | ForEach-Object { $_.name })
    $retiredNames = @($Desired.retiredPlanNames)
    if (@($retiredNames | Where-Object { $_ -in $ownedNames }).Count) { throw 'Active and retired response-plan names must be disjoint.' }
    $conflicts = @($Snapshot.filters | Where-Object { $_.properties.isEnabled -and $_.name -notin ($ownedNames + $retiredNames) })
    if ($conflicts.Count) { throw "Unowned enabled routing requires review: $($conflicts.name -join ', '). No plans were changed." }
    foreach ($entry in (, @('subagents', 'agents', $Desired.handler))) {
        $matches = @($Snapshot[$entry[0]] | Where-Object name -CEQ $entry[2].name)
        if ($matches.Count -gt 1) { throw "Duplicate custom handler $($entry[2].name)." }
        $before = if ($matches.Count) { $matches[0] } else { $null }
        if ($before -and $before.properties.Contains('instructionsOverride') -and $before.properties.instructionsOverride) {
            throw 'Existing custom handler has instructionsOverride; review it explicitly before reconciliation.'
        }
        $after = if ($before) { $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable } else { $entry[2] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
        foreach ($key in $entry[2].properties.Keys) { $after.properties[$key] = $entry[2].properties[$key] }
        if (-not $before -or -not (Test-SreProperties $before.properties $entry[2].properties)) {
            $operations.Add(@{ collection = $entry[0]; method = 'Put'; path = "/api/v2/extendedAgent/$($entry[1])/$([uri]::EscapeDataString($after.name))"; name = $after.name; before = $before; after = $after })
        }
    }
    function Add-FilterChange($Before, $DesiredFilter, [string]$Phase) {
        $after = if ($Before) { $Before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable } else { $DesiredFilter | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
        $null = $after.Remove('scenario')
        foreach ($key in @('createdAt', 'updatedAt', 'configurationWarning')) { $null = $after.properties.Remove($key) }
        foreach ($key in $DesiredFilter.properties.Keys) { $after.properties[$key] = $DesiredFilter.properties[$key] }
        if (-not $Before -or -not (Test-SreProperties $Before.properties $DesiredFilter.properties)) {
            $operations.Add(@{
                collection = 'filters'; method = 'Put'; phase = $Phase
                path = "/api/v2/extendedAgent/incidentFilters/$([uri]::EscapeDataString($DesiredFilter.name))"
                name = $DesiredFilter.name; before = $Before; after = $after
            })
        }
    }
    $activeRetired = @($Snapshot.filters | Where-Object { $_.name -in $retiredNames -and $_.properties.isEnabled })
    if ($activeRetired.Count) {
        foreach ($plan in $Desired.plans) {
            $matches = @($Snapshot.filters | Where-Object name -CEQ $plan.name)
            if ($matches.Count -gt 1) { throw "Duplicate modern filter $($plan.name)." }
            $before = if ($matches.Count) { $matches[0] } else { $null }
            if ($before -and $before.properties.isEnabled) { throw 'Both modern and retired routing are enabled. Inspect this conflict before cutover.' }
            $staged = $plan | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            $staged.properties.isEnabled = $false
            Add-FilterChange $before $staged 'stage-disabled'
        }
        if (@($operations | Where-Object collection -EQ 'filters').Count) {
            return @{ legacyMigrationRequired = $true; operations = @($operations.ToArray()) }
        }
        foreach ($before in $activeRetired) {
            if ($before.properties.incidentPlatform -ne 'AzMonitor') { throw "Retired filter $($before.name) is not the expected AzMonitor platform." }
            $disabled = @{ name = $before.name; properties = @{ isEnabled = $false } }
            if (@($before.properties.priorities | Where-Object { $_ -notmatch '^Sev[0-4]$' }).Count) {
                $disabled.properties.priorities = @('Sev2')
            }
            Add-FilterChange $before $disabled 'disable-retired'
        }
        return @{ legacyMigrationRequired = $true; operations = @($operations.ToArray()) }
    }
    foreach ($plan in $Desired.plans) {
        $matches = @($Snapshot.filters | Where-Object name -CEQ $plan.name)
        if ($matches.Count -gt 1) { throw "Duplicate incident filter $($plan.name)." }
        $before = if ($matches.Count) { $matches[0] } else { $null }
        if ($before -and @($before.properties.priorities | Where-Object { $_ -notmatch '^Sev[0-4]$' }).Count) { $legacy = $true }
        $handlers = @($Snapshot.handlers | Where-Object { $_.incidentFilterId -ceq $plan.name -and -not $_['isDeleted'] })
        if ($handlers.Count -gt 1) { throw "Multiple response handlers for $($plan.name); review before migration." }
        foreach ($handler in $handlers) {
            $hasLegacy = $handler.customInstructions -or @($handler.tools).Count -or @($handler.incidentProcessingGuide).Count
            if ($hasLegacy) {
                $legacy = $true
                # Keep handler identity, incident history and descriptive fields.
                $clean = @{}
                foreach ($key in @('id', 'name', 'description', 'incidentFilterId', 'incidents')) { $clean[$key] = $handler[$key] }
                $clean.customInstructions = ''; $clean.tools = @(); $clean.incidentProcessingGuide = @()
                $operations.Add(@{
                    collection = 'handlers'; path = "/api/v1/incidentPlayground/handlers/$([uri]::EscapeDataString($handler.id))"
                    name = $handler.id; before = $handler; after = $clean
                    method = $null
                    capabilityRequirement = 'Existing legacy handler update: public examples only show PUT, but live service rejects existing IDs and requests POST. A supported update contract or portal migration is required; do not guess POST.'
                })
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
    @{ legacyMigrationRequired = $legacy; operations = @($operations.ToArray()) }
}

function Get-SreCompleteConfigurationPlan {
    param([Collections.IDictionary]$Desired, [Collections.IDictionary]$Snapshot)
    $simulation = $Snapshot | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $all = [Collections.Generic.List[object]]::new()
    $legacy = $false
    for ($phase = 0; $phase -lt 4; $phase++) {
        $plan = Get-SreConfigurationPlan $Desired $simulation
        $legacy = $legacy -or $plan.legacyMigrationRequired
        if (-not $plan.operations.Count) { return @{ legacyMigrationRequired = $legacy; operations = @($all.ToArray()) } }
        foreach ($operation in $plan.operations) {
            $all.Add($operation)
            $key = if ($operation.collection -eq 'handlers') { 'id' } else { 'name' }
            $simulation[$operation.collection] = @($simulation[$operation.collection] | Where-Object { $_[$key] -cne $operation.name }) + @($operation.after)
        }
    }
    throw 'Configuration planning did not converge within four phases.'
}

function Find-SreConfigurationObject {
    param([Collections.IDictionary]$Snapshot, [Collections.IDictionary]$Operation)
    $matches = @($Snapshot[$Operation.collection] | Where-Object {
        if ($Operation.collection -eq 'handlers') { $_.id -ceq $Operation.name } else { $_.name -ceq $Operation.name }
    })
    if ($matches.Count -gt 1) { throw "Ambiguous read-back for $($Operation.name)." }
    if ($matches.Count) { return $matches[0] }
    return $null
}

function Set-SreConfigurationOperation {
    param([Collections.IDictionary]$Session, [Collections.IDictionary]$Operation)
    if ($Operation.method -ne 'Put') { throw 'SRE_EXISTING_HANDLER_UPDATE_UNVERIFIED: no source-verified update method; no write attempted.' }
    $current = Find-SreConfigurationObject (Get-SreConfigurationSnapshot $Session) $Operation
    if ((Get-SreComparableJson $current) -cne (Get-SreComparableJson $Operation.before)) {
        throw "Concurrent change detected for $($Operation.name); stop and create a new backup/preview."
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $writeError = $null
        try { Invoke-SreConfigurationRequest -Session $Session -Method Put -Path $Operation.path -Body $Operation.after | Out-Null }
        catch {
            $writeError = $_
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -in @(400, 401, 403, 404) -or ($status -ge 400 -and $status -lt 500 -and $status -notin @(408, 429))) {
                throw
            }
        }
        # A timeout may have committed. Never replay a write before read-back.
        $observed = Find-SreConfigurationObject (Get-SreConfigurationSnapshot $Session) $Operation
        $matches = $null -ne $observed
        if ($matches -and $Operation.collection -eq 'handlers') {
            $matches = Test-SreProperties $observed $Operation.after
        } elseif ($matches) {
            $matches = Test-SreProperties $observed.properties $Operation.after.properties
        }
        if ($matches) { return $observed }
        if (-not $writeError) { throw "PUT returned but desired state is not verified for $($Operation.name); do not claim success." }
        if ($attempt -eq 3) { throw $writeError }
        if ((Get-SreComparableJson $observed) -cne (Get-SreComparableJson $Operation.before)) {
            throw "Ambiguous/partial update for $($Operation.name); inspect the saved backup and current state before retrying."
        }
        Start-Sleep -Seconds (2 * $attempt)
    }
}

function Invoke-SreConfigurationReconcile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Collections.IDictionary]$Desired, [Collections.IDictionary]$Session,
        [Parameter(Mandatory)][string]$BackupPath, [switch]$AllowLegacyMigration)
    $before = Get-SreConfigurationSnapshot $Session
    $plan = Get-SreCompleteConfigurationPlan $Desired $before
    if ($plan.legacyMigrationRequired -and -not $AllowLegacyMigration) {
        throw 'SRE_LEGACY_MIGRATION_REQUIRED: AzMonitor P1/P2 and response-level instructions/tools/steps need a separately approved migration. Preview first; pass -AllowLegacyMigration only with that scope authorized.'
    }
    if (-not $plan.operations.Count) { return @{ changed = $false; verified = $true; operations = @() } }
    if (-not $PSCmdlet.ShouldProcess($Session.resourceId, "Back up and reconcile $($plan.operations.Count) named SRE configuration objects (Review only, no delete)")) {
        return @{ changed = $false; verified = $false; preview = $plan }
    }
    $unsupported = @($plan.operations | Where-Object { -not $_.method })
    if ($unsupported.Count) {
        throw "SRE_EXISTING_HANDLER_UPDATE_UNVERIFIED: $($unsupported.name -join ', '). Public PUT examples collide with existing handler IDs. Migrate these existing response settings through the supported portal or establish a public update contract. No objects were written."
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
    $expected = $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    foreach ($planned in $plan.operations) {
        $operation = $planned | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $operation.before = Find-SreConfigurationObject $expected $operation
        if ($operation.before -and $operation.collection -ne 'handlers') {
            $body = $operation.before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            foreach ($key in $operation.after.properties.Keys) { $body.properties[$key] = $operation.after.properties[$key] }
            foreach ($key in @('createdAt', 'updatedAt', 'configurationWarning')) { $null = $body.properties.Remove($key) }
            $operation.after = $body
        }
        $observed = Set-SreConfigurationOperation -Session $Session -Operation $operation
        $key = if ($operation.collection -eq 'handlers') { 'id' } else { 'name' }
        $expected[$operation.collection] = @($expected[$operation.collection] | Where-Object { $_[$key] -cne $operation.name }) + @($observed)
    }
    $after = Get-SreConfigurationSnapshot $Session
    $remaining = Get-SreConfigurationPlan $Desired $after
    if ($remaining.operations.Count) { throw 'Final SRE configuration verification failed; retain backup and inspect partial state.' }
    @{ changed = $true; verified = $true; backupPath = $fullPath; before = $before; after = $after; operations = @($plan.operations | ForEach-Object { $_.path }) }
}

Export-ModuleMember -Function Get-SreDesiredConfiguration, New-SreConfigurationSession, Get-SreConfigurationSnapshot, Get-SreConfigurationPlan, Get-SreCompleteConfigurationPlan, Invoke-SreConfigurationReconcile, Test-SreProperties
