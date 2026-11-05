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
    $pickup = "Everything you've seen so far told us what's true. Now something goes wrong. The same alert rules you saw start an investigation by themselves: the agent gathers the evidence, proposes an action and stops at a person for anything that changes Azure. We'll watch that happen three times: the orders database, the application worker, and a container app."
    $closing = "Back to Monday morning. How many servers, are they safe, do we have room, where is the money going, and who is looking when it breaks? You've seen each answered from one view, with the gaps showing as gaps. Arc gave every server, Windows, Linux and SQL, an identity in Azure. Azure Monitor gave us evidence that says when it doesn't know. The workbooks turned that evidence into decisions we can defend. And the SRE agent turned an alert into an investigation while a person decided what, if anything, changed."
    Check ($text.Contains("## 1. Pick up from Arc`n`n**Say:** `"$pickup`"") -or
        $text.Contains("## 1. Pick up from Arc`r`n`r`n**Say:** `"$pickup`"")) 'Exact story pickup starts step one'
    Check ($text.TrimEnd().EndsWith("**Say:** `"$closing`"")) 'Exact shared Arc closing is the last spoken text'
    Check (($text -replace '\s+', ' ').Contains('first live fault is **SQL**, then LOB, then T09')) 'Live story follows the orders database first'
    Check (($text -replace '\s+', ' ').Contains('only **after Arc chapter 7 has shown the alert rules**') -and
        $text.Contains('best moment is its audience question') -and $text.Contains('Prepare disables the')) 'GO follows the Arc alert-rule view, at the audience question'
    # The companion Arc repo splices this guide into its whole-demo run-through and refuses a guide without these level-2 headings.
    function Test-ArcSpliceShape([string]$Markdown) {
        $inFence = $false
        $headings = @(foreach ($line in ($Markdown -split '\r?\n')) {
                if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
                if (-not $inFence -and $line -match '^## (?<text>.+?)\s*$') { $Matches.text }
            })
        $steps = @($headings | Where-Object { $_ -match '^\d+\. ' })
        $numbers = ($steps | ForEach-Object { [int](($_ -split '\.')[0]) }) -join ','
        $afternoon = @($headings | Where-Object { $_ -ceq 'This afternoon: verified existing investigations' })
        $faults = @($headings | Where-Object { $_ -ceq 'Live faults' })
        $afternoon.Count -eq 1 -and $faults.Count -eq 1 -and $numbers -eq '1,2,3,4,5,6,7' -and $steps[6] -ceq '7. Close' -and
            [array]::IndexOf($headings, $afternoon[0]) -lt [array]::IndexOf($headings, $faults[0]) -and
            [array]::IndexOf($headings, $faults[0]) -lt [array]::IndexOf($headings, $steps[0])
    }
    Check (Test-ArcSpliceShape $text) 'Guide keeps the headings the Arc whole-demo run-through splices: This afternoon, Live faults, steps 1 to 7'
    $flat = $text -replace '\s+', ' '
    Check ($flat.Contains('| SQL | about 2 | about 2.5 | report about 4.5 |') -and
        $flat.Contains('| LOB | about 6 | about 6.5 | report about 8.5 |') -and
        $flat.Contains('| T09 | about 5 to 7 | about 6 to 8 | Review card about 7 to 10 |')) 'Observed live-fault timings are tabulated'
    Check ($flat.Contains('Prepare takes 1 to 2 minutes') -and $flat.Contains('about 25 minutes') -and $flat.Contains('about 21 to 31 minutes') -and
        $flat.Contains('No approval-card expiry is documented') -and $flat.Contains('One run per scenario per three hours')) 'Prepare time, total time, auto-resolve window, approval wait and cooldown are stated'
    Check ($flat.Contains('### Running the live faults inside a 30-minute slot') -and $flat.Contains('before the Arc half or early in it') -and
        $flat.Contains('Fire T09 about 10 minutes before its Review beat') -and
        $flat.Contains('say the copies are the same rules, temporary, and leave the originals alone')) 'The 30-minute slot note runs Prepare, SQL and LOB early and T09 ten minutes ahead of its Review beat'
    Check ($flat.Contains('Say "a person approved it", never "the audit proves it"') -and $flat.Contains('(`approveScope` none)') -and
        $flat.Contains('Say that a person approved it, never that the audit proves it') -and
        [regex]::Matches($flat, 'audit proves').Count -eq [regex]::Matches($flat, 'never (?:that )?(?:"?the )?audit proves').Count) 'Approval wording says a person approved it and never that the audit proves it'
    $handlerText = Get-Content -LiteralPath (Join-Path $root 'config\sre-handler.instructions.txt') -Raw
    Check ($flat.Contains('**Builder** > **Agent Canvas**') -and $flat.Contains('click the **sre-demo** subagent node') -and
        $flat.Contains('**Instructions** box in the right panel') -and $flat.Contains('**Governance** section') -and
        $flat.Contains('**Separate Container App recovery policy** section') -and $flat.Contains('do not edit or save')) 'Portal path to the handling agent instructions is the observed one and looks without saving'
    Check ($handlerText -match '(?m)^Governance\r?$' -and $handlerText -match '(?m)^Separate Container App recovery policy\r?$') 'The instruction sections the guide points to exist in the handler instructions'
    Check ($text.Contains($context.arcMachineResourceId)) 'KQL scope contains the exact supplied Arc ID'
    Check ($text.Contains("Log Analytics workspace: $($context.logAnalyticsWorkspaceId)")) 'SRE prompt uses the exact saved workspace resource ID'
    Check ($text.Contains("Tenant: $($context.tenantId)") -and $text.Contains("Subscription: $subscription")) 'Investigation target is fully explicit'
    Check ($text.Contains('ago(30m)') -and $text.Contains('top 50') -and $text.Contains('EventID in (4000, 4100, 4101, 4200)')) 'Investigation query is bounded and covers healthy, fatal, invalid-config and degraded signals'
    Check ($text.Contains('union kind=outer') -and $text.Contains('top 250') -and $text.Contains('bin(TimeGenerated, 1m)')) 'One bounded query correlates app signals and per-minute host metrics'
    Check ($text.Contains('ObjectName =~ "Processor Information"') -and $text.Contains('"% Committed Bytes In Use"') -and $text.Contains('"Available MBytes"') -and $text.Contains('CounterName =~ "% Free Space"')) 'Performance query uses the exact configured Windows CPU, memory and disk counters'
    Check ($text.Contains('missing counters or time bins') -and $text.Contains('not disk latency or IOPS')) 'Missing performance data and unsupported disk metrics are explicit'
    Check ($text.Contains('Do not infer a resource bottleneck') -and $text.Contains('supporting and contradicting evidence') -and
        $text -notmatch 'Degraded is a scripted application warning') 'Investigation ranks evidence without prescribing a scripted cause or host load'
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
    Check ($sqlText.Contains('owned checkpoint row') -and $sqlText -notmatch 'dbo\.IncidentProbe') 'SQL scene uses the current checkpoint contract, not the retired table'
    Check ($sqlText.Contains('original') -and $sqlText.Contains('Session Insights') -and $sqlText.Contains('freshly verified')) 'Existing investigation walkthrough distinguishes verified reports from generated summaries'
    Check ($sqlText.Contains($context.sql.machineResourceId) -and $sqlText.Contains($context.sql.alertResourceId)) 'SQL scene uses explicit host/alert resource links'
    Check ($sqlText.Contains('actual automatically created') -and $sqlText.Contains('sequentially') -and $sqlText.Contains('6001')) 'SQL scene requires automatic delivery, recovery evidence and sequential faults'
    Check ($sqlText.Contains('normal Orders') -or $sqlText.Contains('Normal Orders')) 'SQL scene preserves the normal worker'
    Check ($sqlText.Contains('../docs/sre-response-plan-automation.md#observed-lob-warning-and-reporting-limits') -and
        $sqlText.Contains('../docs/sre-response-plan-automation.md#reset-between-demo-runs')) 'Rehearsal and reset links resolve from the generated guide, preserving section fragments'
    Check ($sqlText -notmatch '\{\{|\}\}|SQL:START|SQL:END') 'Optional SQL section has no unresolved markers'
    Check (Test-ArcSpliceShape $sqlText) 'The SQL render keeps the same Arc splice headings'
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
    $examplePath = Join-Path $fixture '.local\example-context.json'
    Copy-Item -LiteralPath (Join-Path $root 'config\demo-context.example.json') -Destination $examplePath
    $example = Get-Content -LiteralPath (& $scriptPath -ContextPath $examplePath) -Raw
    Check ($example -notmatch '\{\{|\}\}' -and $example.Contains('agents%2Fsre-arc-demo')) 'Shipped example context renders a guide'
    Check ((Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -match '(?m)^\.local/\r?$') 'Entire local context/output directory ignored'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    Check ($source -notmatch '\bInvoke-(SreAz|AzCli|WebRequest|RestMethod)\b|\baz\s+(account|rest|resource|deployment)\b') 'Generator has no cloud/network operation'
    Write-Host "$count presenter assertions passed; offline rendering only."
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
