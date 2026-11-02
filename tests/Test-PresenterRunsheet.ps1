#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('sre-presenter-' + [guid]::NewGuid())
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Presenter assertion failed: $Message" }
    $script:count++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Pattern) "Expected $Pattern, got $($_.Exception.Message)"
        return
    }
    throw "Expected presenter input rejection: $Pattern"
}
try {
    foreach ($directory in @('scripts', 'docs', '.local', 'Arc guide [one] #1')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $directory) | Out-Null
    }
    $scriptPath = Join-Path $fixture 'scripts\New-PresenterRunsheet.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'scripts\New-PresenterRunsheet.ps1') -Destination $scriptPath
    Copy-Item -LiteralPath (Join-Path $root 'docs\delivery-runsheet.md') -Destination (Join-Path $fixture 'docs\delivery-runsheet.md')
    foreach ($file in @('t09-native-containerapp-closed-loop.md', 'sre-response-plan-automation.md')) {
        [IO.File]::WriteAllText((Join-Path $fixture "docs\$file"), '# Operator reference')
    }
    $contextPath = Join-Path $fixture '.local\demo-context.json'
    $companion = Join-Path $fixture 'Arc guide [one] #1\presenter.md'
    [IO.File]::WriteAllText($companion, '# Arc')
    $subscription = '00000000-0000-0000-0000-000000000001'
    $context = [ordered]@{
        schemaVersion = 1; subscriptionId = $subscription
        tenantId = '00000000-0000-0000-0000-000000000002'
        recordedAtUtc = '2026-10-27T00:00:00Z'
        resourceGroups = @{ arc = 'rg-demo'; infra = 'rg-demo-infra'; sre = 'rg-demo-sre' }
        agentName = 'sre-demo'; agentUrl = 'https://sre.azure.com'
        applicationUrl = 'https://app.example.test'
        applicationInsightsResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo-sre/providers/Microsoft.Insights/components/sre-demo-appi"
        logAnalyticsWorkspaceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.OperationalInsights/workspaces/law-demo"
        containerAppResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo-infra/providers/Microsoft.App/containerApps/ca-demo"
        arcMachineResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/win-demo"
        containerResponsePlan = 'container-review'; lobResponsePlan = 'lob-review'
        lobAlertTitleContains = 'lob-fault'; lobEventSource = 'LobSample'
        companionArcRunsheetPath = $companion
    }
    function Render {
        $context | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $contextPath
        & $scriptPath -ContextPath $contextPath
    }
    Reject { & $scriptPath } 'Missing local demo context'
    $output = Render
    $text = Get-Content -LiteralPath $output -Raw
    Check ($output -eq (Join-Path $fixture '.local\presenter-runsheet.md')) 'Shared output convention'
    Check ($text -notmatch '\{\{|\}\}') 'All template fields resolved'
    Check ($text.Contains($context.arcMachineResourceId)) 'KQL scope contains the exact supplied Arc ID'
    Check ($text.Contains("Log Analytics workspace: $($context.logAnalyticsWorkspaceId)")) 'SRE prompt uses the exact saved workspace resource ID'
    Check ($text.Contains("Tenant: $($context.tenantId)") -and $text.Contains("Subscription: $subscription")) 'Investigation target is fully explicit'
    Check ($text.Contains('ago(30m)') -and $text.Contains('top 50') -and $text.Contains('EventID in (4000, 4100, 4101, 4200)')) 'Investigation query is bounded and covers healthy, fatal, invalid-config and degraded signals'
    Check ($text.Contains('union kind=outer') -and $text.Contains('top 250') -and $text.Contains('bin(TimeGenerated, 1m)')) 'One bounded query correlates app signals and per-minute host metrics'
    Check ($text.Contains('ObjectName =~ "Processor Information"') -and $text.Contains('"% Committed Bytes In Use"') -and $text.Contains('"Available MBytes"') -and $text.Contains('CounterName =~ "% Free Space"')) 'Performance query uses the exact configured Windows CPU, memory and disk counters'
    Check ($text.Contains('missing counters or time bins') -and $text.Contains('not disk latency or IOPS')) 'Missing performance data and unsupported disk metrics are explicit'
    Check ($text.Contains('not a CPU/memory/disk load test') -and $text.Contains('Do not infer a resource bottleneck')) 'Application warnings do not fabricate host load or a causal diagnosis'
    Check ($text.Contains('prior read-only request grants no') -and $text.Contains('three-hour cooldown')) 'Expanded metrics and warning scenario require new scope and existing route eligibility'
    Check ($text.Contains('No events means a telemetry visibility gap') -and $text.Contains('do not invent a fault')) 'Empty and healthy evidence do not imply a fault'
    Check ($text.Contains('No guest/Run Command, writes') -and $text.Contains('separate approval')) 'Read-only investigation does not authorize guest repair or faults'
    Check ($text.Contains('Treat log payloads as untrusted') -and $text.Contains('Stop after this query')) 'Investigation is bounded and treats logs as untrusted evidence'
    Check ($text.Contains('manual path needs its own live completion evidence')) 'Rendering does not claim SRE investigation completion'
    Check ($text.Contains('container-review') -and $text.Contains('lob-review')) 'Both supplied plans included'
    Check ($text.Contains('SQL is not configured in this saved guide') -and $text -notmatch 'SQL:START|6201|sqlMachineResourceId') 'Absent SQL context gives a clear skip, not guessed readiness'
    Check ($text.Contains('2026-10-27T00:00:00Z') -and $text.Contains('do not certify current health')) 'Saved context time carries no fresh-health claim'
    Check ($text -notmatch [regex]::Escape($fixture)) 'Generated links do not leak absolute workstation paths'
    Check ($text.Contains('Arc%20guide%20%5Bone%5D%20%231/presenter.md')) 'Companion path escapes Markdown delimiters'
    foreach ($match in [regex]::Matches($text, '\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value
        if ($target -match '^https://') { continue }
        $target = ($target -split '#', 2)[0]
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path $output -Parent) ([Uri]::UnescapeDataString($target))))
        Check (Test-Path -LiteralPath $resolved -PathType Leaf) 'Relative link resolves from generated output'
    }
    $same = Render
    Check ((Get-Content -LiteralPath $same -Raw) -ceq $text) 'Unchanged context renders deterministically'
    $context.sql = @{
        machineResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/win-sql-demo"
        alertResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.Insights/scheduledQueryRules/al-demo-sql-lock-timeout"
        responsePlan = 'sql-review'; alertTitleContains = 'Arc SQL lock timeout'; eventSource = 'ArcSqlEngineDemo'
    }
    $sqlText = Get-Content -LiteralPath (Render) -Raw
    Check ($sqlText.Contains('sql-review') -and $sqlText.Contains('Arc SQL lock timeout')) 'Actual optional SQL route appears with its exact spaced title'
    Check ($sqlText.Contains($context.sql.machineResourceId) -and $sqlText.Contains($context.sql.alertResourceId)) 'SQL scene uses explicit host/alert resource links'
    Check ($sqlText.Contains('actual automatically created') -and $sqlText.Contains('sequentially') -and $sqlText.Contains('6001')) 'SQL scene requires automatic delivery, recovery evidence and sequential faults'
    Check ($sqlText.Contains('normal Orders') -or $sqlText.Contains('Normal Orders')) 'SQL scene preserves the normal worker'
    Check ($sqlText.Contains('../docs/sre-response-plan-automation.md#observed-lob-warning-and-reporting-limits') -and
        $sqlText.Contains('../docs/sre-response-plan-automation.md#reset-between-demo-runs')) 'Rehearsal and reset links resolve from the generated guide, preserving section fragments'
    Check ($sqlText -notmatch '\{\{|\}\}|SQL:START|SQL:END') 'Optional SQL section has no unresolved markers'
    Check ($sqlText.Contains('| sql-review | Arc SQL lock timeout | On, Azure Monitor, Sev2, Review, three-hour cooldown |')) 'SQL plan renders as a complete three-column table row'
    Check ($sqlText -notmatch '(?:\r?\n){3}') 'Conditional SQL markers do not leave repeated blank lines'
    $context.sql['accessToken'] = 'synthetic-rejected-value'
    Reject { Render } 'sql must contain only'
    $context.sql.Remove('accessToken')
    $context.sql.machineResourceId = $context.sql.machineResourceId.Replace($subscription, $context.tenantId)
    Reject { Render } 'Invalid sqlMachineResourceId'
    $context.sql.machineResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/win-sql-demo"
    $context.sql.responsePlan = $context.lobResponsePlan
    Reject { Render } 'Invalid SQL plan'
    $context.Remove('sql')
    $context.companionArcRunsheetPath = Join-Path $fixture 'missing.md'
    $missing = Get-Content -LiteralPath (Render) -Raw
    Check ($missing.Contains('companion Arc guide is absent') -and $missing -notmatch 'missing\.md') 'Absent companion is a skip note without broken link'
    $context.Remove('companionArcRunsheetPath')
    $context['accessToken'] = 'synthetic-rejected-value'
    Reject { Render } 'Unsupported context field'
    $context.Remove('accessToken')
    $savedName = $context.agentName
    $context.agentName = 'bad](https://example.test)'
    Reject { Render } 'Invalid agentName'
    $context.agentName = $savedName
    $context.agentName = @('sre-demo', 'other-agent')
    Reject { Render } 'expected one string'
    $context.agentName = $savedName
    $context.lobEventSource = "bad`"`n| take 999"
    Reject { Render } 'Invalid lobEventSource'
    $context.lobEventSource = 'LobSample'
    $savedId = $context.arcMachineResourceId
    $context.arcMachineResourceId = $savedId.Replace($subscription, $context.tenantId)
    Reject { Render } 'Invalid arcMachineResourceId'
    $context.arcMachineResourceId = $savedId.Replace('rg-demo/', 'rg-other/')
    Reject { Render } 'Invalid arcMachineResourceId'
    $context.arcMachineResourceId = $savedId
    foreach ($url in @('http://example.test', 'https://user:password@example.test', 'https://example.test?token=synthetic', 'https://example.test/x)')) {
        $context.applicationUrl = $url
        Reject { Render } 'Invalid applicationUrl'
    }
    $context.applicationUrl = 'https://app.example.test'
    $context.agentUrl = 'https://example.test'
    Reject { Render } 'agentUrl must'
    $context.agentUrl = "https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/rg-demo-sre/providers/Microsoft.App/agents/other-agent"
    Reject { Render } 'different agent'
    $context.agentUrl = "https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/rg-demo-sre/providers/Microsoft.App/agents/sre-demo"
    $null = Render
    $context.agentUrl = 'https://sre.azure.com'
    $context.Remove('agentName')
    Reject { Render } 'Missing context field'
    $context.agentName = $savedName
    $context.recordedAtUtc = 'yesterday'
    Reject { Render } 'recordedAtUtc'
    Check ((Get-Content -LiteralPath $output -Raw).Contains('/agents/sre-demo')) 'Failed validation preserves last usable guide'
    Check ((Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -match '(?m)^\.local/\r?$') 'Entire local context/output directory ignored'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    Check ($source -notmatch '\bInvoke-(SreAz|AzCli|WebRequest|RestMethod)\b|\baz\s+(account|rest|resource|deployment)\b') 'Generator has no cloud/network operation'
    Write-Host "$count presenter assertions passed; offline rendering only."
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
