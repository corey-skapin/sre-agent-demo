#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\SreConfiguration.psm1') -Force
$module = Get-Module SreConfiguration
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Configuration assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected failure: $Pattern"
}
$desired = Get-SreDesiredConfiguration -SubscriptionId '00000000-0000-0000-0000-000000000001' -TenantId '00000000-0000-0000-0000-000000000002'
Check ($desired.schemaVersion -eq 2) 'Configuration and readiness remain separately versioned'
foreach ($plan in $desired.plans) {
    Check ($plan.properties.priorities.Count -eq 1 -and $plan.properties.priorities[0] -ceq 'Sev2') 'AzMonitor requires exact Sev2'
    Check (-not $plan.properties.ContainsKey('customInstructions') -and -not $plan.properties.ContainsKey('tools')) 'Instructions/tools belong to custom agent'
    Check ($plan.properties.mergeEnabled -and $plan.properties.mergeWindowHours -eq 3) 'Fresh/reused filters enforce three-hour cooldown'
}
Check ('RunAzCliWriteCommands' -in $desired.handler.properties.tools) 'T09 write tool remains governed by Review'
$fixture = @{
    subagents = @($desired.handler | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
    filters = @($desired.plans | ForEach-Object { $_ | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable })
    handlers = @()
}
$fixture.subagents[0].properties.instructions = 'previous instructions'
foreach ($filter in $fixture.filters) {
    $filter.properties.mergeEnabled = $false
    $filter.properties.mergeWindowHours = 1
    $filter.properties.serverDefault = 'preserve'
}
Check ((Get-SreConfigurationPlan $desired $fixture).operations.Count -eq 3) 'Reused state needs only one agent and two cooldown updates'
$conflict = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$conflict.filters += @{ name = 'unowned'; properties = @{ isEnabled = $true } }
Throws { Get-SreConfigurationPlan $desired $conflict } 'Unowned enabled'
foreach ($kind in @('duplicate', 'override')) {
    $ambiguous = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    if ($kind -eq 'duplicate') { $ambiguous.subagents += $ambiguous.subagents[0] }
    else { $ambiguous.subagents[0].properties.instructionsOverride = 'external instructions' }
    Throws { Get-SreConfigurationPlan $desired $ambiguous } 'Duplicate custom handler|instructionsOverride'
}
$history = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$history.filters += @{ name = 'container-app-restart-review-v2'; properties = @{ isEnabled = $false; priorities = @('P1') } }
$history.handlers += @{ id = 'historical'; incidentFilterId = 'container-app-restart-review-v2'; isDeleted = $false; customInstructions = 'historical'; tools = @(); incidentProcessingGuide = @() }
Check ((Get-SreConfigurationPlan $desired $history).operations.Count -eq 3) 'Disabled unrelated history is preserved without migration'
$history.filters[-1].properties.isEnabled = $true
Throws { Get-SreConfigurationPlan $desired $history } 'Unowned enabled'
foreach ($kind in @('priorities', 'response')) {
    $legacy = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    if ($kind -eq 'priorities') { $legacy.filters[0].properties.priorities = @('P1', 'P2') }
    else { $legacy.handlers += @{ id = 'old'; incidentFilterId = $desired.plans[0].name; isDeleted = $false; customInstructions = 'old'; tools = @(); incidentProcessingGuide = @() } }
    Throws { Get-SreConfigurationPlan $desired $legacy } 'not migrated.*No objects were written'
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
try {
    & $module {
        param($Fixture)
        $script:TestSnapshot = $Fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $script:TestCalls = [Collections.Generic.List[string]]::new()
        $script:TestTimeoutAfterCommit = $false
        $script:TestForbidden = $false
        $script:TestConcurrent = ''
        $script:TestAgentReads = 0
        $script:TestSchema = ''
        function script:Invoke-RestMethod {
            param($Uri, $Method, $TimeoutSec, $Headers, $ErrorAction, $ContentType, $Body)
            $script:TestCalls.Add("$Method $Uri")
            $collection = if ($Uri -match '/incidentPlayground/handlers') { 'handlers' } elseif ($Uri -match '/incidentFilters') { 'filters' } else { 'subagents' }
            if ($Method -eq 'Get') {
                if ($script:TestSchema -eq 'empty') { return $null }
                if ($script:TestSchema -eq 'missing-value') { return @{} }
                if ($script:TestSchema -eq 'pagination') { return @{ value = @(); nextLink = 'https://untrusted.invalid/next' } }
                if ($script:TestSchema -eq 'wrong-value') { return @{ value = @{} } }
                if ($collection -eq 'subagents') {
                    $script:TestAgentReads++
                    if ($script:TestAgentReads -eq 2) {
                        if ($script:TestConcurrent -eq 'target') { $script:TestSnapshot.subagents[0].properties.instructions = 'external edit' }
                        if ($script:TestConcurrent -eq 'routing') { $script:TestSnapshot.filters += @{ name = 'concurrent-unowned'; properties = @{ isEnabled = $true } } }
                    }
                }
                if ($collection -eq 'handlers') { return ,$script:TestSnapshot.handlers }
                return @{ value = @($script:TestSnapshot[$collection]); nextLink = $null }
            }
            if ($script:TestForbidden) {
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden))
            }
            $value = $Body | ConvertFrom-Json -AsHashtable
            $script:TestSnapshot[$collection] = @($script:TestSnapshot[$collection] | Where-Object name -CNE $value.name) + @($value)
            if ($script:TestTimeoutAfterCommit) { $script:TestTimeoutAfterCommit = $false; throw [TimeoutException]::new('Ambiguous timeout after commit') }
            return $value
        }
    } $fixture
    $session = @{ endpoint = 'https://unit-test.azuresre.ai'; token = 'unit-test'; resourceId = '/unit-test'; deadlineUtc = [DateTime]::UtcNow.AddMinutes(3) }
    $preview = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp -WhatIf
    Check (-not $preview.verified -and -not (Test-Path -LiteralPath $temp)) 'WhatIf has no backup and is not success-shaped'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 0) 'WhatIf has no HTTP mutation'
    & $module { $script:TestTimeoutAfterCommit = $true }
    $result = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp
    Check ($result.verified -and $result.changed) 'Modern in-place update verifies'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 3) 'Committed timeout is read back, not replayed'
    Check (@($result.after.filters | Where-Object { $_.properties.serverDefault -eq 'preserve' }).Count -eq 2) 'Unrelated properties survive updates'
    $backup = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
    Check (-not $backup.filters[0].properties.mergeEnabled) 'Backup captures original state before mutation'
    $again = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp
    Check ($again.verified -and -not $again.changed) 'Second ensure is no-op and does not overwrite backup'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 3) 'Second ensure makes no write'
    foreach ($case in @('forbidden', 'target', 'routing', 'priorities', 'response')) {
        & $module {
            param($Fixture, $Case)
            $script:TestSnapshot = $Fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            $script:TestForbidden = $Case -eq 'forbidden'
            $script:TestConcurrent = $Case
            $script:TestAgentReads = 0
            $script:TestCalls.Clear()
            if ($Case -eq 'priorities') { $script:TestSnapshot.filters[0].properties.priorities = @('P1') }
            if ($Case -eq 'response') { $script:TestSnapshot.handlers += @{ id = 'old'; incidentFilterId = $script:TestSnapshot.filters[0].name; isDeleted = $false; customInstructions = 'old'; tools = @(); incidentProcessingGuide = @() } }
        } $fixture $case
        $other = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
        try {
            $pattern = switch ($case) { 'forbidden' { 'Forbidden' }; 'target' { 'Concurrent change' }; 'routing' { 'Concurrent routing' }; default { 'not migrated' } }
            Throws { Invoke-SreConfigurationReconcile $desired $session -BackupPath $other } $pattern
            $expectedWrites = if ($case -eq 'forbidden') { 1 } else { 0 }
            Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq $expectedWrites) "$case does not retry or partially migrate"
            if ($case -in @('priorities', 'response')) { Check (-not (Test-Path -LiteralPath $other)) 'Legacy refusal precedes backup/write' }
        } finally { if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Force } }
    }
    foreach ($schema in @('empty', 'missing-value', 'pagination', 'wrong-value')) {
        & $module { param($Schema) $script:TestSchema = $Schema } $schema
        Throws { Get-SreConfigurationSnapshot $session } 'Empty SRE GET|Unexpected SRE list|paginated|not an array'
    }
    & $module {
        $script:TestSnapshot = @{ subagents = @(); filters = @(); handlers = @() }
        $script:TestSchema = ''; $script:TestConcurrent = ''; $script:TestForbidden = $false; $script:TestCalls.Clear()
    }
    $other = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
    try {
        $fresh = Invoke-SreConfigurationReconcile $desired $session -BackupPath $other
        Check ($fresh.verified -and $fresh.operations.Count -eq 3) 'Fresh rebuild creates only one agent and two filters'
        Check ((& $module { $script:TestSnapshot.handlers.Count }) -eq 0) 'Fresh bootstrap never creates legacy handlers'
        $freshAgain = Invoke-SreConfigurationReconcile $desired $session -BackupPath $other
        Check ($freshAgain.verified -and -not $freshAgain.changed) 'Fresh bootstrap is repeatable'
        Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 3) 'Fresh repeat makes no write'
        Throws { & $module { param($Session) Invoke-SreConfigurationRequest $Session Put '/api/v1/incidentPlayground/handlers/old' @{} } $session } 'read-only'
        Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put */api/v1/*' }).Count }) -eq 0) 'Legacy update route cannot reach HTTP'
    } finally { if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Force } }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    & $module { Remove-Item Function:\Invoke-RestMethod; Remove-Variable TestSnapshot,TestCalls,TestTimeoutAfterCommit,TestForbidden,TestConcurrent,TestAgentReads,TestSchema -Scope Script }
}
Write-Host "SRE configuration: $count assertions passed."
