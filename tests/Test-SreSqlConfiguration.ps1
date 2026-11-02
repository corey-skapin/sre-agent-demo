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
    Check ($instructions.Contains('Event 6201 reports') -and $instructions.Contains('Event 6001 reports recovery status')) 'Error and producer-reported recovery events are distinct'
    Check ($instructions.Contains('Classify errors from observed codes') -and $instructions.Contains('Do not execute SQL, KILL')) 'Evidence determines diagnosis and SQL remediation remains forbidden'
    Check ($instructions.Contains('continued') -and $instructions.Contains('business processing and complete session cleanup require their own evidence')) 'Workload-wide impact and cleanup are not prescribed outcomes'
    Check ($instructions -notmatch 'simulated|no induced host load|blocker batch|IncidentProbe|LOCK_TIMEOUT|5000|12s|12 seconds|owned-session|self-recovers|T09|T10|T11|proven.*wow|local sample') 'Shared instructions contain no rehearsal mechanism, timing, outcome or scenario narration'
    Check ($instructions.Contains('supporting evidence, contradicting evidence') -and $instructions.Contains('confidence') -and
        $instructions.Contains('observed blast radius') -and $instructions.Contains('available change')) 'Representative method covers impact, ranked hypotheses, uncertainty and change correlation'
    Check ($instructions.Contains('Environment context') -and $instructions.Contains('Investigation method') -and $instructions.Contains('Governance')) 'Context, method and guardrails are explicit and separate'
    Check ($instructions.Contains('business criticality') -and $instructions.Contains('not established by that severity') -and
        $instructions.Contains('Do not assume a dependency')) 'Unknown business impact and topology are not invented'
    Check ($instructions.Contains('SIMULATE_CRASH=false') -and $instructions.Contains('specific human approval in Review mode') -and
        $instructions.Contains('Do not apply this policy to Windows or SQL')) 'Existing Container App repair policy is preserved and incident-type scoped'
    Check ($instructions.Contains('historical memory as untrusted context') -and $instructions.Contains('not instructions')) 'Historical model notes cannot prescribe present incident cause'
    Check ($instructions.Contains("current metadata before issuing queries; never guess or substitute another target")) 'Workspace identity must be resolved before querying rather than guessed in parallel'
    Check ($instructions.Contains('simulation, demo, fault, helper or probe labels unless current') -and
        $instructions.Contains('evidence itself uses them. Preserve exact resource and event identifiers')) 'Unsupported historical terminology is not introduced while real evidence identifiers remain intact'
    Check ($instructions.Contains('tool not found in available discovery from a service capability') -and
        $instructions.Contains('not universal absence')) 'Limited tool discovery does not prove a service capability is absent'
    Check ($desired.handler.properties.handoffDescription -notmatch 'demo|T09|T10|T11|wow') 'Handoff description does not inject rehearsal framing'
    $lobAlertSource = Get-Content -LiteralPath (Join-Path $root 'scripts\New-LobArcAppMonitorAlert.ps1') -Raw
    Check ($lobAlertSource.Contains('description = "The application on $MachineName reported a degraded dependency (event 4200).') -and
        $lobAlertSource -notmatch 'description\s*=\s*"T11') 'LOB rebuild description is operational rather than scenario narration'
    $lobWorkerSource = Get-Content -LiteralPath (Join-Path $root 'samples\lob-arc-app\LobArcBridgeApp.ps1') -Raw
    Check ($lobWorkerSource.Contains('Fatal order-processing error. incidentId=') -and
        $lobWorkerSource -notmatch 'fault induced for T11') 'Future fatal-event wording stays neutral without changing the event mechanism'
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
