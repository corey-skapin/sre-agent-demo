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
Check ($desired.schemaVersion -eq 2) 'Current configuration format is versioned separately from readiness'
foreach ($plan in $desired.plans) {
    Check ($plan.properties.priorities.Count -eq 1 -and $plan.properties.priorities[0] -ceq 'Sev2') 'AzMonitor requires exact Sev2, never high/P1/P2'
    Check (-not $plan.properties.ContainsKey('customInstructions') -and -not $plan.properties.ContainsKey('tools')) 'Instructions/tools belong to custom agent'
}
Check ('RunAzCliWriteCommands' -in $desired.handler.properties.tools) 'T09 write capability is explicitly selected on custom agent, still governed by Review'
$fixture = @{ subagents = @(); filters = @(); handlers = @() }
foreach ($plan in $desired.plans) {
    $filter = $plan | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $filter.properties.priorities = @('P1', 'P2')
    $filter.properties.titleContains += ' OR obsolete'
    $filter.properties.mergeWindowHours = 3
    $filter.properties.updatedAt = 'before'
    $fixture.filters += $filter
    $fixture.handlers += @{
        id = "$($plan.name)-handler"; name = $plan.name; incidentFilterId = $plan.name
        description = 'Preserve this description'; incidents = @('historical-incident')
        customInstructions = 'legacy'; tools = @(); incidentProcessingGuide = @('legacy step')
        isDeleted = $false
    }
}
$fixture.subagents = @($desired.handler | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
$fixture.subagents[0].properties.instructions = 'old instructions'
$fixture.subagents[0].properties.tools = @()
$plan = Get-SreConfigurationPlan $desired $fixture
Check ($plan.legacyMigrationRequired -and $plan.operations.Count -eq 5) 'Existing resources require one agent, two legacy-handler and two in-place filter updates'
Check (@($plan.operations | Where-Object { $_.collection -eq 'handlers' -and $_.after.incidents[0] -eq 'historical-incident' }).Count -eq 2) 'Migration preserves handler IDs/history'
Check (@($plan.operations | Where-Object { $_.collection -eq 'filters' -and $_.after.properties.mergeWindowHours -eq 3 }).Count -eq 2) 'Unrelated routing settings survive migration'
$conflict = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$conflict.filters += @{ name = 'quickstart'; properties = @{ isEnabled = $true } }
Throws { Get-SreConfigurationPlan $desired $conflict } 'Unowned enabled'

$temp = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
try {
    & $module {
        param($Fixture)
        $script:TestSnapshot = $Fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $script:TestCalls = [Collections.Generic.List[string]]::new()
        $script:TestTimeoutAfterCommit = $false
        $script:TestForbidden = $false
        $script:TestConcurrent = $false
        $script:TestAgentReads = 0
        function script:Invoke-RestMethod {
            param($Uri, $Method, $TimeoutSec, $Headers, $ErrorAction, $ContentType, $Body)
            $script:TestCalls.Add("$Method $Uri")
            $collection = if ($Uri -match '/incidentPlayground/handlers') { 'handlers' } elseif ($Uri -match '/incidentFilters') { 'filters' } else { 'subagents' }
            if ($Method -eq 'Get') {
                if ($collection -eq 'subagents') {
                    $script:TestAgentReads++
                    if ($script:TestConcurrent -and $script:TestAgentReads -eq 2) {
                        $script:TestSnapshot.subagents[0].properties.instructions = 'external concurrent edit'
                    }
                }
                if ($collection -eq 'handlers') { return ,$script:TestSnapshot.handlers }
                return @{ value = @($script:TestSnapshot[$collection]); nextLink = $null }
            }
            if ($script:TestForbidden) {
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden))
            }
            $value = $Body | ConvertFrom-Json -AsHashtable
            $key = if ($collection -eq 'handlers') { 'id' } else { 'name' }
            $script:TestSnapshot[$collection] = @($script:TestSnapshot[$collection] | Where-Object { $_[$key] -cne $value[$key] }) + @($value)
            if ($script:TestTimeoutAfterCommit) { $script:TestTimeoutAfterCommit = $false; throw [TimeoutException]::new('Ambiguous timeout after commit') }
            return $value
        }
    } $fixture
    $session = @{ endpoint = 'https://unit-test.azuresre.ai'; token = 'unit-test'; resourceId = '/unit-test'; deadlineUtc = [DateTime]::UtcNow.AddMinutes(3) }
    Throws { Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp } 'SRE_LEGACY_MIGRATION_REQUIRED'
    Check (-not (Test-Path -LiteralPath $temp)) 'Migration refusal makes no backup or write'
    $preview = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp -AllowLegacyMigration -WhatIf
    Check (-not $preview.verified -and -not (Test-Path -LiteralPath $temp)) 'WhatIf is read-only and never success-shaped'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 0) 'WhatIf/refusal have no HTTP mutation'
    & $module { $script:TestTimeoutAfterCommit = $true }
    $result = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp -AllowLegacyMigration
    Check ($result.verified -and $result.changed) 'Full migration read-back verifies'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 5) 'Ambiguous committed timeout is read back, not replayed'
    $backup = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
    Check ($backup.filters[0].properties.priorities[0] -eq 'P1') 'Backup captures original legacy state before any mutation'
    $again = Invoke-SreConfigurationReconcile $desired $session -BackupPath $temp -AllowLegacyMigration
    Check ($again.verified -and -not $again.changed) 'Second ensure is idempotent and does not overwrite backup'
    Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 5) 'Second ensure makes no write'
    & $module { $script:TestSnapshot.subagents[0].properties.instructions = 'concurrent edit'; $script:TestForbidden = $true }
    $other = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
    try {
        Throws { Invoke-SreConfigurationReconcile $desired $session -BackupPath $other } 'Forbidden'
        Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 6) 'Authorization denial is never retried'
    } finally { if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Force } }
    & $module {
        param($Fixture)
        $script:TestSnapshot = $Fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $script:TestConcurrent = $true; $script:TestForbidden = $false; $script:TestAgentReads = 0
        $script:TestCalls.Clear()
    } $fixture
    $other = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
    try {
        Throws { Invoke-SreConfigurationReconcile $desired $session -BackupPath $other -AllowLegacyMigration } 'Concurrent change'
        Check ((& $module { @($script:TestCalls | Where-Object { $_ -like 'Put *' }).Count }) -eq 0) 'Concurrent user edit stops before mutation'
    } finally { if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Force } }
    & $module {
        $script:TestSnapshot = @{ subagents = @(); filters = @(); handlers = @() }
        $script:TestConcurrent = $false; $script:TestCalls.Clear()
    }
    $other = Join-Path ([IO.Path]::GetTempPath()) "sre-config-$([guid]::NewGuid()).json"
    try {
        $fresh = Invoke-SreConfigurationReconcile $desired $session -BackupPath $other
        Check ($fresh.verified -and $fresh.operations.Count -eq 3) 'Clean rebuild creates only one custom agent and two current-schema filters'
        Check ((& $module { $script:TestSnapshot.handlers.Count }) -eq 0) 'Clean reconstruction never creates legacy response handlers'
        $freshAgain = Invoke-SreConfigurationReconcile $desired $session -BackupPath $other
        Check ($freshAgain.verified -and -not $freshAgain.changed) 'Clean reconstruction is repeatable'
    } finally { if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Force } }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    & $module { Remove-Item Function:\Invoke-RestMethod; Remove-Variable TestSnapshot,TestCalls,TestTimeoutAfterCommit,TestForbidden,TestConcurrent,TestAgentReads -Scope Script }
}
Write-Host "SRE configuration: $count assertions passed."
