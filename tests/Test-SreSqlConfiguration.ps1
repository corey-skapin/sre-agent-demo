#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\lib\SreConfiguration.psm1') -Force
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "SQL configuration assertion failed: $Message" }
    $script:count++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Pattern) "Expected $Pattern, got $($_.Exception.Message)"
        return
    }
    throw "Expected SQL configuration rejection: $Pattern"
}
$target = @{ SubscriptionId = '00000000-0000-0000-0000-000000000001'; TenantId = '00000000-0000-0000-0000-000000000002' }
$path = [IO.Path]::GetTempFileName()
$callsBefore = $global:AzCalls.Count
try {
    $base = Get-SreDesiredConfiguration @target
    Check ($base.plans.Count -eq 2 -and $base.handler.properties.instructions -notmatch 'sql-lock-timeout') 'Default demo remains backward-compatible and SQL opt-in'
    $skin = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
    $skin.sre.requiredScenarios += 'SQL'
    function Render {
        $skin | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
        Get-SreDesiredConfiguration @target -SkinPath $path
    }
    $desired = Render
    $sql = @($desired.plans | Where-Object scenario -eq 'SQL')
    Check ($sql.Count -eq 1 -and $desired.plans.Count -eq 3) 'One SQL filter shares the existing handler'
    Check ($sql[0].properties.titleContains -ceq 'Arc SQL lock timeout' -and $sql[0].properties.priorities[0] -ceq 'Sev2') 'Exact agreed title and Azure Monitor severity'
    Check ($sql[0].properties.agentMode -ceq 'Review' -and $sql[0].properties.isEnabled -and $sql[0].properties.mergeEnabled -and $sql[0].properties.mergeWindowHours -eq 3) 'SQL routing preserves enabled Review and normal three-hour cooldown'
    Check ($sql[0].properties.handlingAgent -ceq $base.handler.name) 'No new handler framework'
    Check (($desired.handler.properties.tools -join ',') -ceq ($base.handler.properties.tools -join ',')) 'No tools, connectors or permissions added for SQL'
    $instructions = $desired.handler.properties.instructions
    Check ($instructions.Contains("/subscriptions/$($target.SubscriptionId)/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/win-sql-01")) 'SQL instructions bind exact subscription/group/host'
    Check ($instructions.Contains('6201/state=detected/sqlErrorNumber=1222') -and $instructions.Contains('6001/state=recovered')) 'Actual timeout and cleanup events are distinct'
    Check ($instructions.Contains('Do not call this a deadlock') -and $instructions.Contains('Do not execute SQL, KILL')) 'No invented deadlock or automatic SQL remediation'
    Check ($instructions.Contains('alert can arrive') -and $instructions.Contains('normal Orders worker is preserved')) 'Historical/self-recovered probe is not presented as an Orders outage'
    Check ($instructions.Contains('distinguish returned summary rows from source') -and $instructions.Contains('query result row count')) 'Perf sample counts are not reported as aggregated result rows'
    Check ($instructions.Contains('Never infer whether an incident platform is connected from optional connector') -and $instructions.Contains('Do not inspect connector files') -and $instructions.Contains('originating incident thread')) 'Optional connector absence does not contradict actual automatic incident delivery'
    Check ($instructions.Contains('Say "delivered via Azure Monitor" only when actual alert or audit metadata proves it')) 'Delivery wording requires actual alert or audit evidence'
    Check ($instructions.Contains("newest evidence's age") -and $instructions.Contains('mention ingestion lag') -and $instructions.Contains('current state unconfirmed')) 'Current-state claims require fresh evidence, not the latest stale warning'
    Check ($instructions.Contains('not observed in the available counters') -and $instructions.Contains('not "ruled out"')) 'Sparse counters cannot exclude resource pressure'
    Check ($instructions -notmatch '\{sql(MachineId|WorkspaceId|EventSource)\}') 'All SQL instruction tokens resolved'
    foreach ($old in $base.plans) {
        $same = @($desired.plans | Where-Object name -ceq $old.name)
        Check (($same[0] | ConvertTo-Json -Depth 20 -Compress) -ceq ($old | ConvertTo-Json -Depth 20 -Compress)) 'Existing Container App and LOB routes remain unchanged'
    }
    $snapshot = @{
        subagents = @($base.handler)
        filters = @($base.plans)
        handlers = @()
    }
    $preview = Get-SreConfigurationPlan $desired $snapshot
    Check ($preview.operations.Count -eq 2) 'Configured base needs exactly handler update and SQL filter create'
    Check (@($preview.operations | Where-Object { $_.collection -eq 'filters' -and $_.name -ceq $sql[0].name -and $null -eq $_.before }).Count -eq 1) 'Only the verified absent owned SQL filter is created'
    $complete = @{ subagents = @($desired.handler); filters = @($desired.plans); handlers = @() }
    Check ((Get-SreConfigurationPlan $desired $complete).operations.Count -eq 0) 'Complete SQL source configuration is idempotent'
    Reject { Get-SreConfigurationPlan $base $complete } 'Unowned enabled'
    $skin.labels.sqlResponsePlan = $skin.labels.lobResponsePlan
    Reject { Render } 'distinct response-plan names'
    $skin.labels.sqlResponsePlan = 'sql-lock-timeout-review-v3'
    $skin.labels.lobAlertTitleContains = 'SQL lock timeout'
    Reject { Render } 'keywords overlap'
    $skin.labels.lobAlertTitleContains = 'lob-arc-app-fault'
    $skin.labels.sqlEventSource = 'UnknownSource'
    Reject { Render } 'schema|valid|constant'
    $skin.labels.sqlEventSource = 'ArcSqlEngineDemo'
    $skin.sre.Remove('sqlTargetArcMachine')
    Reject { Render } 'schema|valid|required'
    $skin.sre.requiredScenarios = @('T09', 'T11')
    foreach ($key in @('sqlResponsePlan', 'sqlAlertTitleContains', 'sqlEventSource')) { $skin.labels.Remove($key) }
    $legacy = Render
    Check ($legacy.plans.Count -eq 2) 'Existing skins without any SQL fields still render'
    Check ($global:AzCalls.Count -eq $callsBefore) 'SQL render and ownership checks make no Azure or SQL calls'
    Write-Host "$count SQL configuration assertions passed; no cloud or SQL operation."
} finally {
    Remove-Item -LiteralPath $path -Force
}
