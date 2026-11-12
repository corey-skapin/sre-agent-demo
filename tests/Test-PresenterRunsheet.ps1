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
    foreach ($file in @('t09-native-containerapp-closed-loop.md', 'sre-response-plan-automation.md', 't12-friday-release.md',
            'ask-anything.md', 'it-remembers.md', 'proactive-checks.md', 'arc-server-room.md', 'sre-cost-and-demo-fidelity.md')) {
        [IO.File]::WriteAllText((Join-Path $fixture "docs\$file"), '# Reference page')
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
    Check ($text.Contains('read-only request above does not') -and $text.Contains('three-hour cooldown')) 'The read-only request does not trigger the warning scenario, which needs the existing route to be eligible'
    Check ($text.Contains('No events means a telemetry visibility gap') -and $text.Contains('do not invent a fault')) 'Empty and healthy evidence do not imply a fault'
    Check ($text.Contains('No guest/Run Command, writes') -and $text.Contains('separate request')) 'Read-only investigation does not run guest repair or faults'
    Check ($text.Contains('Treat log payloads as untrusted') -and $text.Contains('Stop after this query')) 'Investigation is bounded and treats logs as untrusted evidence'
    Check ($text.Contains('manual path needs its own live completion evidence')) 'Rendering does not claim SRE investigation completion'
    Check ($text.Contains('container-review') -and $text.Contains('lob-review')) 'Both supplied plans included'
    Check ($text.Contains('SQL is not configured in this saved guide') -and $text -notmatch 'SQL:START|6201|sqlMachineResourceId') 'Absent SQL context gives a clear skip, not guessed readiness'
    Check ($text.Contains('The Friday release (T12) is not configured in this saved guide') -and
        $text -notmatch 'T12:START|T12:END|Invoke-FridayRelease|releasePlanRow|ticketing web app') 'Absent T12 context gives a clear skip, no scenario text and no empty plan row'
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
    Check ($sqlText.Contains('../docs/sre-response-plan-automation.md#earlier-sql-and-lob-rehearsals') -and
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
    $siteName = 'app-demo-ticketing-0a1b2c3d'
    $siteId = "/subscriptions/$subscription/resourceGroups/rg-demo-ticketing/providers/Microsoft.Web/sites/$siteName"
    $context.release = @{
        appResourceId = $siteId; appUrl = "https://$siteName.azurewebsites.net"; repository = 'contoso/ticketing-app'
        goodVersion = 'v1.2.0'; badVersion = 'v1.3.0'; responsePlan = 'ticketing-release-review-v1'
    }
    $releaseText = Get-Content -LiteralPath (Render) -Raw
    $releaseFlat = $releaseText -replace '\s+', ' '
    Check ($releaseText -notmatch '\{\{|\}\}|T12:START|T12:END|Friday release \(T12\) is not configured') 'Optional T12 section has no unresolved markers or skip note'
    Check ($releaseFlat.Contains('| ticketing-release-review-v1 | Checkout failures on the ticketing web app | On, Azure Monitor, Sev2, Review, cooldown off |')) 'T12 plan renders as a complete three-column table row'
    Check ($releaseFlat.Contains("[$siteName](https://portal.azure.com/#resource$siteId)") -and $releaseFlat.Contains("[the app](https://$siteName.azurewebsites.net)")) 'T12 section links the exact web app and its address'
    Check ($releaseFlat.Contains('Invoke-FridayRelease.ps1 -Action Start') -and $releaseFlat.Contains('-Action Status -Wait') -and
        $releaseFlat.Contains('-Action Reset -DeleteThreads') -and $releaseFlat.Contains('sets `WEBSITE_RUN_FROM_PACKAGE` to the package URL of v1.2.0')) 'T12 section runs the scenario and names the exact fix to check before approving'
    Check ($releaseFlat.Contains('assigned to Copilot in contoso/ticketing-app') -and $releaseFlat.Contains('stops for a second **Approve**')) 'T12 section names the repository and the second approval'
    Check ($releaseFlat.Contains('Review only governs Azure changes') -and $releaseFlat.Contains('blocked both commands in a live test') -and $releaseFlat.Contains('reaches every repository the signed-in account can reach')) 'T12 trust beat is honest about the Review boundary, the measured deny rules and the sign-in scope'
    Check ($releaseFlat.Contains('never that the audit proves it') -and $releaseFlat.Contains('doesn''t predict when the alert clears')) 'T12 section keeps the approval and closing-summary wording'
    Check ($releaseText.Contains('../docs/t12-friday-release.md#what-is-proven-and-what-isnt') -and $releaseText.Contains('(../docs/t12-friday-release.md)')) 'T12 runbook links resolve from the generated guide, preserving the section fragment'
    Check ($releaseText.IndexOf('## 6. Optional: one live incident') -lt $releaseText.IndexOf('### The Friday release (T12)') -and
        $releaseText.IndexOf('### The Friday release (T12)') -lt $releaseText.IndexOf('## 7. Close')) 'T12 section sits inside step 6 so the Arc splice headings stay put'
    Check (Test-ArcSpliceShape $releaseText) 'The T12 render keeps the same Arc splice headings'
    Check ($releaseText.TrimEnd().EndsWith("**Say:** `"$closing`"")) 'The shared Arc closing is still the last spoken text with T12'
    Check ($releaseText -notmatch '(?:\r?\n){3}') 'Conditional T12 markers do not leave repeated blank lines'
    foreach ($link in [regex]::Matches($releaseText, '\]\((?<target>[^)]+)\)')) {
        $target = $link.Groups['target'].Value
        if ($target -match '^https://') { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path $output -Parent) ([Uri]::UnescapeDataString(($target -split '#', 2)[0]))))
        Check (Test-Path -LiteralPath $resolved -PathType Leaf) 'Relative link in the T12 render resolves'
    }
    $context.release['accessToken'] = 'synthetic-rejected-value'
    Reject { Render } 'release must contain only'
    $context.release.Remove('accessToken')
    $context.release.Remove('repository')
    Reject { Render } 'Missing or invalid release.repository'
    $context.release.repository = 'contoso/ticketing-app'
    $context.release.appResourceId = $siteId.Replace($subscription, $context.tenantId)
    Reject { Render } 'Invalid releaseAppResourceId'
    $context.release.appResourceId = $siteId.Replace('Microsoft.Web/sites', 'Microsoft.Web/serverfarms')
    Reject { Render } 'Invalid releaseAppResourceId'
    $context.release.appResourceId = $siteId
    foreach ($url in @('http://app.azurewebsites.net', 'https://app.example.test', 'https://app.azurewebsites.net/checkout', 'https://app.azurewebsites.net?token=synthetic', ('https://u' + [char]64 + 'app.azurewebsites.net'))) {
        $context.release.appUrl = $url
        Reject { Render } 'Invalid releaseAppUrl'
    }
    $context.release.appUrl = "https://$siteName.azurewebsites.net"
    foreach ($bad in @(@('badVersion', '1.3.0'), @('goodVersion', 'v1.2'), @('repository', 'no-owner'), @('responsePlan', $context.lobResponsePlan), @('responsePlan', 'Bad Plan'))) {
        $saved = $context.release[$bad[0]]
        $context.release[$bad[0]] = $bad[1]
        Reject { Render } 'Invalid T12 repository, version or response plan'
        $context.release[$bad[0]] = $saved
    }
    # The act modules are optional: no acts field leaves no trace, each listed module renders, each unlisted one is a skip note.
    $actsTrace = 'Running order|ask it anything|it remembers|works when nothing is broken|the server room|ACTS:|ASK:|MEMORY:|PROACTIVE:|ARC:|CUT:'
    Check ($text -notmatch $actsTrace -and $releaseText -notmatch $actsTrace) 'No acts field leaves no trace of the act modules'
    # Every script command the act blocks tell you to run must name a real script, real parameters and valid -Action or -Source values.
    function Test-ScriptCommands([string]$Markdown) {
        $commands = 0
        foreach ($span in [regex]::Matches($Markdown, '`(?<code>[A-Za-z][\w-]*\.ps1(?: [^`]*)?)`')) {
            $tokens = @($span.Groups['code'].Value -split '\s+')
            $scriptFile = Join-Path $root "scripts\$($tokens[0])"
            Check (Test-Path -LiteralPath $scriptFile -PathType Leaf) "The guide names a script that exists: $($tokens[0])"
            $ast = [Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$null, [ref]$null)
            $accepted = @{}
            foreach ($parameter in $ast.ParamBlock.Parameters) {
                $accepted[$parameter.Name.VariablePath.UserPath] = @($parameter.Attributes |
                        Where-Object { $_ -is [Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'ValidateSet' } |
                        ForEach-Object { $_.PositionalArguments.Value })
            }
            for ($i = 1; $i -lt $tokens.Count; $i++) {
                if ($tokens[$i] -match '^-(?<name>[A-Za-z]+)$') {
                    $name = $Matches.name
                    Check $accepted.ContainsKey($name) "$($tokens[0]) has a -$name parameter"
                    if ($i + 1 -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-' -and $accepted[$name].Count) {
                        Check ($tokens[$i + 1] -cin $accepted[$name]) "$($tokens[0]) -$name accepts $($tokens[$i + 1])"
                    }
                }
            }
            $commands++
        }
        return $commands
    }
    $context.acts = @('ASK', 'MEMORY', 'PROACTIVE')
    $actsText = Get-Content -LiteralPath (Render) -Raw
    $actsFlat = $actsText -replace '\s+', ' '
    Check ($actsText -notmatch '\{\{|\}\}|<!-- [A-Z0-9]+:(START|END)|(Act 1 \(ask it anything\)|Act 3 \(it remembers\)|Act 4 \(it works when nothing is broken\)) is not configured|no executive cut') 'All three modules render with no markers, skip notes or missing cut'
    Check ($actsFlat.Contains('| 1. Ask it anything | configured | 3 | skipped |') -and $actsFlat.Contains('| 2. The Friday release | configured | 9 | 6, short form |') -and
        $actsFlat.Contains('| 3. It remembers | configured | 3 | skipped |') -and $actsFlat.Contains('| 4. It works when nothing is broken | configured | 4 | 3, the governance deck only |') -and
        $actsFlat.Contains('| 5. Why you can trust it | configured | 3 | 3 |') -and $actsFlat.Contains('| 6. The server room (Arc) | not configured | 5 | skipped, or 4 in place of the deck |')) 'Running order says which acts this guide has and how each runs in each cut'
    $rows = @($actsText -split '\r?\n' | Where-Object { $_ -match '^\| (Open|Close|[1-6]\. )' })
    $fullMinutes = 0
    $cutMinutes = 0
    foreach ($row in $rows) {
        $cells = @($row.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells[2] -match '^\d+$') { $fullMinutes += [int]$cells[2] }
        if ($cells[3] -match '^(?<minutes>\d+)') { $cutMinutes += [int]$Matches.minutes }
    }
    Check ($rows.Count -eq 8 -and $fullMinutes -eq 28 -and $cutMinutes -eq 15) "Running order adds up to the 28-minute run and the 15-minute cut (got $fullMinutes and $cutMinutes)"
    Check ($actsFlat.Contains('are a budget from one rehearsal')) 'Running order is honest that the minutes are a budget from one rehearsal'
    $positions = @('## 6. Optional: one live incident', '### Running order', '### Act 1: ask it anything', '### The Friday release (T12)', '### Act 3: it remembers',
        '### Act 4: it works when nothing is broken', '## 7. Close') | ForEach-Object { $actsText.IndexOf($_) }
    Check (@($positions | Where-Object { $_ -lt 0 }).Count -eq 0 -and (@($positions | Sort-Object) -join ',') -ceq ($positions -join ',')) 'Every act block sits inside step 6, in act order, so the Arc splice headings stay put'
    Check ((Test-ScriptCommands $actsText) -ge 8) 'The act blocks and the T12 block name real scripts and parameters'
    Check ($actsFlat.Contains('Invoke-ScheduledTask.ps1 -Action Run -Name governance-deck') -and $actsFlat.Contains('Invoke-DriftDemo.ps1 -Action Start') -and
        $actsFlat.Contains('Invoke-DriftDemo.ps1 -Action Reset') -and $actsFlat.Contains('Export-SreAgentFiles.ps1 -Source Notes -List') -and
        $actsFlat.Contains('Export-SreAgentFiles.ps1 -Source Thread -ThreadId')) 'Act 3 and Act 4 give the exact commands'
    Check ($actsFlat.Contains('read-only by design') -and $actsFlat.Contains('never "it can''t change anything"') -and $actsFlat.Contains('Review mode governs the Azure write tool, not Python')) 'Act 4 keeps the honest read-only wording and the Python caveat'
    Check ($actsFlat.Contains('there is no way to clear the notes in place') -and $actsFlat.Contains('Don''t present the hand-written overview as something the agent learned')) 'Act 3 says plainly what the notes are and that rebuilding is the only clear'
    Check (Test-ArcSpliceShape $actsText) 'The acts render keeps the same Arc splice headings'
    Check ($actsText.TrimEnd().EndsWith("**Say:** `"$closing`"")) 'The shared Arc closing is still the last spoken text with the acts'
    Check ($actsText -notmatch '(?:\r?\n){3}') 'Act markers do not leave repeated blank lines'
    foreach ($link in [regex]::Matches($actsText, '\]\((?<target>[^)]+)\)')) {
        $target = $link.Groups['target'].Value
        if ($target -match '^https://') { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path $output -Parent) ([Uri]::UnescapeDataString(($target -split '#', 2)[0]))))
        Check (Test-Path -LiteralPath $resolved -PathType Leaf) 'Relative link in the acts render resolves'
    }
    Check ($actsText.Contains('../docs/ask-anything.md') -and $actsText.Contains('../docs/it-remembers.md') -and $actsText.Contains('../docs/proactive-checks.md') -and
        $actsText.Contains('../docs/sre-cost-and-demo-fidelity.md')) 'The acts link their module pages and the cost reference'
    Check ($actsText.Contains('Act 6 (the server room) is not configured in this saved guide') -and $actsText -notmatch '### Act 6|Invoke-ArcServerRoom|arc-server-room\.md') 'Without the ARC module, Act 6 is a skip note with no commands and no link'
    $context.acts = @('ASK', 'MEMORY', 'PROACTIVE', 'ARC')
    $arcText = Get-Content -LiteralPath (Render) -Raw
    $arcFlat = $arcText -replace '\s+', ' '
    Check ($arcFlat.Contains('| 6. The server room (Arc) | configured | 5 | skipped, or 4 in place of the deck |') -and $arcText.Contains('### Act 6: the server room (Arc)') -and
        $arcText -notmatch '\{\{|\}\}|<!-- [A-Z0-9]+:(START|END)|Act \d \([^)]+\) is not configured in this saved guide|no executive cut') 'The ARC module adds Act 6 to the running order and the guide'
    $arcPositions = @('### Act 4: it works when nothing is broken', '### Act 6: the server room (Arc)', '## 7. Close') | ForEach-Object { $arcText.IndexOf($_) }
    Check (@($arcPositions | Where-Object { $_ -lt 0 }).Count -eq 0 -and (@($arcPositions | Sort-Object) -join ',') -ceq ($arcPositions -join ',')) 'Act 6 sits after Act 4 and before the close, inside step 6'
    Check ($arcFlat.Contains('Invoke-ArcServerRoom.ps1 -Action Check') -and $arcFlat.Contains('Invoke-ArcServerRoom.ps1 -Action Start -ApproveFault') -and
        $arcFlat.Contains('Invoke-ArcServerRoom.ps1 -Action Status -Wait') -and $arcFlat.Contains('Invoke-ArcServerRoom.ps1 -Action Reset -DeleteThreads')) 'Act 6 gives the exact commands'
    Check ((Test-ScriptCommands $arcText) -ge ((Test-ScriptCommands $actsText) + 4)) 'Every Act 6 command names a real script, parameter and -Action value'
    Check ($arcFlat.Contains('a person approved it, never that the audit proves who') -and $arcFlat.Contains('If it says the card is not the allowed repair, don''t approve it') -and
        $arcFlat.Contains('The cut leaves out the server room (Act 6)') -and $arcFlat.Contains('the cut then runs 16 minutes')) 'Act 6 keeps the approval wording and the executive-cut verdict'
    Check ($arcText -notmatch '(?:\r?\n){3}' -and (Test-ArcSpliceShape $arcText) -and $arcText.Contains('../docs/arc-server-room.md') -and $arcText.TrimEnd().EndsWith("**Say:** `"$closing`"")) 'The render with Act 6 keeps the Arc splice headings, the shared closing and its module page link'
    foreach ($link in [regex]::Matches($arcText, '\]\((?<target>[^)]+)\)')) {
        $target = $link.Groups['target'].Value
        if ($target -match '^https://') { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path $output -Parent) ([Uri]::UnescapeDataString(($target -split '#', 2)[0]))))
        Check (Test-Path -LiteralPath $resolved -PathType Leaf) "Relative link in the Act 6 render resolves: $target"
    }
    $context.acts = @('ASK')
    $askText = Get-Content -LiteralPath (Render) -Raw
    Check ($askText.Contains('### Act 1: ask it anything') -and $askText.Contains('Act 3 (it remembers) is not configured in this saved guide') -and
        $askText.Contains('Act 4 (it works when nothing is broken) is not configured in this saved guide') -and
        $askText.Contains('There is no executive cut in this saved guide') -and $askText -notmatch '### Act [34]|Invoke-ScheduledTask|Invoke-DriftDemo|Export-SreAgentFiles') 'A guide with only the ASK module skips Acts 3 and 4 and the executive cut, with no leftover commands'
    Check ($askText -notmatch '(?:\r?\n){3}|\{\{|\}\}|<!-- [A-Z0-9]+:(START|END)' -and (Test-ArcSpliceShape $askText)) 'The ASK-only render is clean and keeps the Arc splice headings'
    $savedRelease = $context.release
    $context.Remove('release')
    $context.acts = @('MEMORY')
    $memoryText = Get-Content -LiteralPath (Render) -Raw
    Check ($memoryText.Contains('### Act 3: it remembers') -and $memoryText.Contains('| 3. It remembers | configured | 3 | skipped |') -and
        $memoryText.Contains('| 2. The Friday release | not configured | 9 | 6, short form |') -and $memoryText.Contains('Act 1 (ask it anything) is not configured in this saved guide') -and
        $memoryText.Contains('The Friday release (T12) is not configured in this saved guide') -and $memoryText.Contains('There is no executive cut in this saved guide') -and
        $memoryText -notmatch 'Invoke-FridayRelease|WEBSITE_RUN_FROM_PACKAGE|ticketing web app|Invoke-ScheduledTask|Invoke-DriftDemo') 'The MEMORY module stands alone without the Friday release and leaves no scenario text'
    Check ($memoryText -notmatch '(?:\r?\n){3}|\{\{|\}\}|<!-- [A-Z0-9]+:(START|END)' -and (Test-ArcSpliceShape $memoryText)) 'The MEMORY-only render is clean and keeps the Arc splice headings'
    $context.acts = @('ARC')
    $arcOnlyText = Get-Content -LiteralPath (Render) -Raw
    Check ($arcOnlyText.Contains('### Act 6: the server room (Arc)') -and $arcOnlyText.Contains('| 6. The server room (Arc) | configured | 5 |') -and $arcOnlyText.Contains('| 2. The Friday release | not configured | 9 | 6, short form |') -and
        $arcOnlyText.Contains('Act 1 (ask it anything) is not configured in this saved guide') -and $arcOnlyText.Contains('There is no executive cut in this saved guide') -and
        $arcOnlyText -notmatch 'Invoke-FridayRelease|WEBSITE_RUN_FROM_PACKAGE|ticketing web app|Invoke-ScheduledTask|Invoke-DriftDemo') 'The ARC module stands alone without the Friday release or the other acts'
    Check ($arcOnlyText -notmatch '(?:\r?\n){3}|\{\{|\}\}|<!-- [A-Z0-9]+:(START|END)' -and (Test-ArcSpliceShape $arcOnlyText)) 'The ARC-only render is clean and keeps the Arc splice headings'
    $context.acts = @('PROACTIVE')
    Reject { Render } 'PROACTIVE needs the release'
    $context.acts = @('ASK', 'PROACTIVE')
    Reject { Render } 'PROACTIVE needs the release'
    $context.release = $savedRelease
    foreach ($badActs in @('ASK', @(), @('ASK', 'ASK'), @('ask'), @('BOGUS'), @('ASK', 7), @($null), $null)) {
        $context.acts = $badActs
        Reject { Render } 'acts must be a list of one or more of ASK, MEMORY, PROACTIVE and ARC'
    }
    $context.Remove('acts')
    $context.sql = @{
        machineResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/win-sql-demo"
        alertResourceId = "/subscriptions/$subscription/resourceGroups/rg-demo/providers/Microsoft.Insights/scheduledQueryRules/al-demo-sql-lock-timeout"
        responsePlan = 'sql-review'; alertTitleContains = 'Arc SQL lock timeout'; eventSource = 'ArcSqlEngineDemo'
    }
    $bothText = Get-Content -LiteralPath (Render) -Raw
    Check ($bothText.Contains('sql-review') -and $bothText.Contains('ticketing-release-review-v1') -and $bothText -notmatch '\{\{|\}\}|SQL:START|T12:START' -and (Test-ArcSpliceShape $bothText)) 'SQL and T12 can both be configured'
    $context.release.responsePlan = 'sql-review'
    Reject { Render } 'Invalid T12 repository, version or response plan'
    $context.release.responsePlan = 'ticketing-release-review-v1'
    $context.Remove('sql')
    $context.Remove('release')
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
