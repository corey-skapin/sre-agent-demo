#Requires -Version 7.4
# Offline checks for the ASK, MEMORY and PROACTIVE modules (Acts 1, 3 and 4): what they render from config\acts and the skin, how the plan compares
# it with an agent, the apply engine, the scheduled-task and export helpers, and the readiness rows. The comparison runs on plain data; everything
# that talks to the agent runs for real against a small stand-in agent on a loopback port (tests\TestHelpers.ps1). No Azure, no network beyond loopback.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRelease.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreConfiguration.psm1') -Force
$actsModule = Import-Module (Join-Path $root 'scripts\lib\SreActs.psm1') -Force -PassThru
Import-Module (Join-Path $root 'scripts\lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreReleaseExtras.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreActsExtras.psm1') -Force
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$workspaceRoot = '/root/sreagent/terminalRoot'
$notesFolder = "$workspaceRoot/memories/synthesizedKnowledge"
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Acts assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}
function Get-HostText($Output) { (@($Output | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n") }
function Get-WarningText($Output) { (@($Output | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message }) -join "`n") }
function Join-Sorted($Items) {
    $sorted = [string[]]@($Items)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $sorted -join ','
}

$agents = [Collections.Generic.List[object]]::new()
$temps = [Collections.Generic.List[string]]::new()
function New-Agent {
    $agent = Start-FakeAgent
    $agents.Add($agent)
    $agent
}
function New-TempPath([string]$Suffix = '') {
    $path = Join-Path ([IO.Path]::GetTempPath()) "acts-test-$([guid]::NewGuid())$Suffix"
    $temps.Add($path)
    $path
}
function New-BackupBase {
    $base = New-TempPath
    $temps.Add("$base.acts.json")
    $base
}
function New-ActsSkinFile {
    param([Parameter(Mandatory)][string[]]$Scenarios, [hashtable]$Memory)
    $path = New-TestT12SkinFile -Root $root -Scenarios $Scenarios
    $temps.Add($path)
    if ($Memory) {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $data.memory = $Memory
        [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20))
    }
    $path
}
function Get-ActsFor([string[]]$Scenarios, [hashtable]$Memory) {
    Get-SreActsDesired -Skin (Get-DemoSkin -Path (New-ActsSkinFile -Scenarios $Scenarios -Memory $Memory) -RepoRoot $root) -SubscriptionId $subscription
}
function New-SeedFolder([hashtable]$Files) {
    $folder = New-TempPath
    New-Item -ItemType Directory -Path $folder | Out-Null
    foreach ($name in $Files.Keys) {
        $target = Join-Path $folder ($name -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($target, [string]$Files[$name])
    }
    $folder
}

try {
    # --- Which modules a skin turns on, and what each renders ---------------------------------------------------------------------------
    $allPath = New-ActsSkinFile -Scenarios @('T12', 'ASK', 'MEMORY', 'PROACTIVE')
    $allSkin = Get-DemoSkin -Path $allPath -RepoRoot $root
    $all = Get-SreActsDesired -Skin $allSkin -SubscriptionId $subscription
    Check ((@($all.modules) -join ',') -ceq 'ASK,MEMORY,PROACTIVE') 'All three modules are on'
    Check ((@($all.skills | ForEach-Object { $_.name }) -join ',') -ceq 'estate-query,estate-health-check,bicep-drift-scan,governance-deck') 'Four skills: the question skill and the three proactive ones'
    Check ((@($all.agents | ForEach-Object { $_.name }) -join ',') -ceq 'estate-auditor,deck-builder') 'Two read-only agents'
    Check ((@($all.tasks | ForEach-Object { $_.name }) -join ',') -ceq 'estate-health-check,bicep-drift-scan,governance-deck') 'Three scheduled tasks'
    Check (@($all.tasks | Where-Object { $_.enabled -or $_.agentMode -cne 'Review' -or $_.cronExpression -notmatch '^\S+( \S+){4}$' }).Count -eq 0) 'Every task is Off, in Review mode and has a five-field schedule'
    Check (@($all.tasks | Where-Object { $_.agent -notin @($all.agents | ForEach-Object { $_.name }) }).Count -eq 0) 'Every task runs one of the two agents'
    Check ($all.seed.source -ceq 'repo' -and (@($all.seed.files.Keys) -join ',') -ceq 'overview.md' -and $all.seed.files['overview.md'].Length -le 2000 -and $all.seed.files['overview.md'] -notmatch "`r") 'The seed is the repo overview.md, in at most 2,000 characters, with LF line endings'
    foreach ($agent in $all.agents) {
        Check ($agent.type -ceq 'ExtendedAgent' -and $agent.properties.enableSkills -eq $true -and @($agent.properties.handoffs).Count -eq 0 -and 'RunAzCliWriteCommands' -notin $agent.properties.tools -and @($agent.properties.tools | Where-Object { $_ -like '*Github*' }).Count -eq 0) "Agent $($agent.name) is an extended agent with skills, no handoffs, no write tool and no GitHub tool"
    }
    Check ((@(($all.agents | Where-Object { $_.name -ceq 'estate-auditor' }).properties.tools) -join ',') -ceq 'RunAzCliReadCommands,QueryLogAnalyticsByWorkspaceId,SearchMemory') 'The auditor reads with the CLI read tool, Log Analytics and memory only'
    Check ((@(($all.agents | Where-Object { $_.name -ceq 'deck-builder' }).properties.tools) -join ',') -ceq 'RunAzCliReadCommands,QueryLogAnalyticsByWorkspaceId,SearchMemory,ReadFile,ExecutePythonCode') 'The deck builder adds a file reader and Python, and nothing that writes to Azure'

    $askOnly = Get-ActsFor @('ASK')
    Check ((@($askOnly.modules) -join ',') -ceq 'ASK' -and (@($askOnly.skills | ForEach-Object { $_.name }) -join ',') -ceq 'estate-query' -and @($askOnly.agents).Count -eq 0 -and @($askOnly.tasks).Count -eq 0 -and $null -eq $askOnly.seed) 'ASK alone is one skill: no agent, no task, no seed, and no T09 or T12 needed'
    Check ($askOnly.skills[0].content -notmatch 'Container App ca-' -and $askOnly.skills[0].content -notmatch 'ticketing web app') 'Without T09 or T12 the skill says nothing about the Container App or the ticketing app'
    $memoryOnly = Get-ActsFor @('MEMORY')
    Check ((@($memoryOnly.modules) -join ',') -ceq 'MEMORY' -and @($memoryOnly.skills).Count -eq 0 -and @($memoryOnly.tasks).Count -eq 0 -and $memoryOnly.seed.source -ceq 'repo') 'MEMORY alone is only the seed'
    $withT09 = Get-ActsFor @('T09', 'ASK', 'MEMORY')
    Check ($withT09.skills[0].content -match 'ca-arc-demo-fault' -and $withT09.seed.files['overview.md'] -match 'ca-arc-demo-fault' -and $withT09.seed.files['overview.md'] -notmatch 'WEBSITE_RUN_FROM_PACKAGE') 'With T09 the Container App is named and the ticketing paragraph stays out'
    Check ($all.skills[0].content -match 'AppRequests' -and $all.seed.files['overview.md'] -match 'WEBSITE_RUN_FROM_PACKAGE' -and $all.seed.files['overview.md'] -notmatch 'ca-arc-demo-fault') 'With T12 the ticketing app is named and the Container App paragraph stays out'
    Check ($null -eq (Get-ActsFor @('T09', 'T11'))) 'A skin with none of the three modules renders nothing'
    $skinWithoutT12 = Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('T12', 'PROACTIVE')) -RepoRoot $root
    $skinWithoutT12.sre.requiredScenarios = @('T09', 'PROACTIVE')
    Throws { Get-SreActsDesired -Skin $skinWithoutT12 -SubscriptionId $subscription } 'must also require T12'
    $skinWithoutT12.sre.requiredScenarios = @('PROACTIVE')
    Throws { Get-SreActsDesired -Skin $skinWithoutT12 -SubscriptionId $subscription } 'must also require T12'
    Check ((Get-SreActsModules -Skin $allSkin) -join ',' -ceq 'ASK,MEMORY,PROACTIVE' -and @(Get-SreActsModules -Skin (Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('T12')) -RepoRoot $root)).Count -eq 0) 'The module list follows the skin and ignores the other scenarios'

    # --- The text of every rendered file ------------------------------------------------------------------------------------------------
    $rendered = [Collections.Generic.List[string]]::new()
    foreach ($skill in $all.skills) { $rendered.Add($skill.content) }
    foreach ($agent in $all.agents) { $rendered.Add([string]$agent.properties.instructions) }
    foreach ($task in $all.tasks) { $rendered.Add([string]$task.agentPrompt) }
    $everything = ($rendered -join "`n")
    Check ($everything -notmatch '\{[A-Za-z][A-Za-z0-9]*\}' -and $everything -notmatch "`r" -and $everything -notmatch '<!--') 'No unfilled token, no CR and no leftover comment or block marker in any rendered text'
    Check (@($all.skills | Where-Object { -not $_.description -or $_.description.Length -gt 400 }).Count -eq 0 -and @($all.tasks | Where-Object { -not $_.description }).Count -eq 0) 'Every skill and task has a description, and no skill description is long'
    $urls = @([regex]::Matches($everything, 'https://management\.azure\.com\S*') | ForEach-Object { $_.Value })
    Check ($urls.Count -ge 2 -and @($urls | Where-Object { $_ -match '[$]' }).Count -eq 0 -and @($everything -split "`n" | Where-Object { $_ -match '^\s*(az rest|`az rest)\s.*[$]' }).Count -eq 0) 'No az rest URL or command in any text has a dollar sign: the agent''s CLI tool refuses them'
    Check ($everything -match 'must not contain a dollar sign in the URL' -and $everything -match 'no dollar signs in the URL' -and $everything -match 'Keep dollar signs out of every az rest URL') 'The skills tell the agent why: the read tool rejects a dollar sign in an az rest URL'
    $guids = @([regex]::Matches($everything + $all.seed.files['overview.md'], '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '^00000000-0000-0000-0000-0000000000\d\d$' })
    Check ($guids.Count -eq 0) 'No real GUID in any rendered text or in the seed'
    foreach ($task in $all.tasks) { Check ($task.agentPrompt -match '(?i)read-only|change nothing|never change|never deploy|only report') "Task $($task.name) tells the agent it changes nothing" }
    Check (($all.agents | Where-Object { $_.name -ceq 'deck-builder' }).properties.instructions -match 'never install a package' -and ($all.agents | Where-Object { $_.name -ceq 'deck-builder' }).properties.instructions -match 'Never call Azure, GitHub or any other service from Python') 'The deck builder is told to keep Python local and never to install a package'
    Check (@($all.skills | Where-Object { $_.name -ceq 'governance-deck' }).Count -eq 1 -and ($all.skills | Where-Object { $_.name -ceq 'governance-deck' }).content -match 'python-pptx') 'The deck skill builds the file with python-pptx'

    # The drift skill must say what the Bicep says: when the Bicep changes, this fails until the skill follows.
    $bicep = Get-Content -LiteralPath (Join-Path $root 'infra\ticketing\workload.bicep') -Raw
    $drift = ($all.skills | Where-Object { $_.name -ceq 'bicep-drift-scan' }).content
    $rows = @($drift -split "`n" | Where-Object { $_ -like '| *' })
    foreach ($item in @(
            @{ row = 'FTP state'; pattern = "ftpsState: '([^']+)'" }, @{ row = 'Minimum TLS'; pattern = "[^m]minTlsVersion: '([^']+)'" }, @{ row = 'Minimum TLS'; pattern = "scmMinTlsVersion: '([^']+)'" },
            @{ row = 'HTTPS only'; pattern = 'httpsOnly: (true|false)' }, @{ row = 'Always on'; pattern = 'alwaysOn: (true|false)' }, @{ row = 'Health check path'; pattern = "healthCheckPath: '([^']+)'" })) {
        $declared = [regex]::Match($bicep, $item.pattern).Groups[1].Value
        $row = @($rows | Where-Object { $_ -like "| $($item.row) |*" })[0]
        Check ($declared -and $row -and ($row -split '\|')[2].Trim().Contains($declared)) "The drift skill's '$($item.row)' row declares what the Bicep declares ($declared)"
    }
    $planRow = @($rows | Where-Object { $_ -like '| Plan |*' })[0]
    $allSettings = Get-SreActsSettings -Skin $allSkin -SubscriptionId $subscription
    Check ($bicep -match '(?s)resource appServicePlan .*?capacity: 1\b.*?reserved: true' -and $planRow -match 'Linux, one instance' -and $allSettings.tokens.appSku -and $planRow.Contains("SKU $($allSettings.tokens.appSku)")) 'The drift skill expects the one-instance Linux plan the Bicep declares, with the skin''s SKU'
    Check ($bicep -match "(?s)resource checkoutFailureAlert '[^']+' = \{.*?severity: 2.*?enabled: true" -and $bicep -match "(?s)resource checkoutFailureAlertSpare '[^']+' = \{.*?severity: 2.*?enabled: false" -and $drift -match 'both Sev2' -and $drift -match 'enabled, .* disabled') 'The drift skill expects the primary alert rule enabled and the spare disabled, both Sev2, as the Bicep declares'
    $ruleApi = [regex]::Match($bicep, "Microsoft\.Insights/scheduledQueryRules@([0-9a-z-]+)'").Groups[1].Value
    Check ($ruleApi -and $drift.Contains("api-version=$ruleApi")) 'The drift skill reads the alert rules with the API version the Bicep deploys them with'
    Check ($bicep -match "union\(tags, \{\s*sreScenario: 'T12'" -and $drift.Contains('sreScenario=T12')) 'The drift skill lists the sreScenario tag the Bicep puts on the web app'
    foreach ($tag in (Get-SreReleaseDemoTags -Skin $allSkin).GetEnumerator()) { Check ($drift.Contains("$($tag.Key)=$($tag.Value)")) "The drift skill lists the deploy tag $($tag.Key)" }
    foreach ($grade in 'Benign', 'Risky', 'Critical') { Check ($drift -match $grade) "The drift skill grades $grade" }
    Check ($drift -match 'never call the write tool' -and $drift -match 'proposed, not run') 'The drift skill only proposes reverts'

    # The Stop hook must leave these reports alone: it judges closing summaries of incident investigations only.
    $hook = Get-Content -LiteralPath (Join-Path $root 'config\t12\hooks\release-closing-check.md') -Raw
    Check ($hook -match 'First determine whether this response is the incident investigation summary' -and $hook -match 'scheduled health checks, drift scans and governance reports' -and $hook -match 'deck-building notes' -and $hook -match 'answers about the estate') 'The Stop hook says scheduled reports, deck notes and estate answers are not investigation summaries'

    # --- Rendering helpers and the guards on what an agent file may say ----------------------------------------------------------------
    $settingsT09 = Get-SreActsSettings -Skin (Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('T09', 'ASK')) -RepoRoot $root) -SubscriptionId $subscription
    Check ($settingsT09.flags.T09 -and -not $settingsT09.flags.T12 -and -not $settingsT09.tokens.ContainsKey('appName') -and $settingsT09.tokens.arcWorkspaceId -ceq "/subscriptions/$subscription/resourceGroups/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo") 'Settings carry the Arc names always and the ticketing names only with T12'
    $overview = Read-SreActsText -RelativePath 'memory\overview.md' -Settings $settingsT09
    Check ($overview -match 'ca-arc-demo-fault' -and $overview -notmatch '<!--') 'Read-SreActsText resolves a block whose flag is on and drops a block whose flag is off'
    Throws { Read-SreActsText -RelativePath 'memory\overview.md' -Settings @{ tokens = @{}; flags = @{ T09 = $true; T12 = $false } } } 'unfilled tokens'
    Throws { Read-SreActsText -RelativePath 'memory\overview.md' -Settings @{ tokens = $settingsT09.tokens; flags = @{ T09 = $true } } } "conditional block 'T12' that nothing defines"
    $badAgent = {
        param([string]$Text)
        & $actsModule {
            param($Text)
            $script:probeText = $Text
            function script:Read-SreActsText { param($RelativePath, $Settings) $script:probeText }
            try { $null = Get-SreActsAgent -Name 'estate-auditor' -Settings @{ tokens = @{}; flags = @{} }; 'accepted' } catch { $_.Exception.Message }
        } $Text
    }
    $agentFile = { param($Tools, $Name = 'estate-auditor', $Body = 'Body.') "---`nname: $Name`ndescription: d`ntools: $Tools`n---`n$Body`n" }
    Check ((& $badAgent (& $agentFile 'RunAzCliReadCommands, RunAzCliWriteCommands')) -match 'must stay read-only but lists: RunAzCliWriteCommands') 'An agent file that lists the Azure write tool is refused'
    Check ((& $badAgent (& $agentFile 'RunAzCliReadCommands, FetchGithubIssue')) -match 'must stay read-only but lists: FetchGithubIssue' -and (& $badAgent (& $agentFile 'CreateGithubIssue')) -match 'CreateGithubIssue') 'An agent file that lists any GitHub tool is refused'
    Check ((& $badAgent (& $agentFile 'RunAzCliReadCommands')) -ceq 'accepted') 'A read-only agent file is accepted'
    Check ((& $badAgent (& $agentFile 'RunAzCliReadCommands' 'other-name')) -match "must have the name 'estate-auditor'" -and (& $badAgent (& $agentFile 'RunAzCliReadCommands' 'estate-auditor' '')) -match 'has no body') 'An agent file must carry its own file name and a body'
    Check ((& $badAgent "---`nname: estate-auditor`ndescription: d`n---`nBody`n") -match "needs a 'tools' line") 'An agent file without a tools line is refused'
    $badTask = {
        param([string]$Text)
        & $actsModule {
            param($Text)
            $script:probeText = $Text
            function script:Read-SreActsText { param($RelativePath, $Settings) $script:probeText }
            try { $null = Get-SreActsTask -Name 'estate-health-check' -Settings @{ tokens = @{}; flags = @{} }; 'accepted' } catch { $_.Exception.Message }
        } $Text
    }
    Check ((& $badTask "---`nname: estate-health-check`ndescription: d`ncron: 0 8 * *`nagent: estate-auditor`n---`nBody`n") -match 'five-field cron' -and (& $badTask "---`nname: estate-health-check`ndescription: d`ncron: 0 8 * * 1-5`nagent: estate-auditor`n---`nBody`n") -ceq 'accepted') 'A task needs a five-field schedule'
    $null = Import-Module (Join-Path $root 'scripts\lib\SreActs.psm1') -Force -PassThru

    # --- The seed: the repo's overview, or a private folder ------------------------------------------------------------------------------
    $private = New-SeedFolder @{ 'overview.md' = "# Notes`r`nline two`r`n"; 'sub/more.md' = 'more'; '.hidden/skip.md' = 'hidden'; 'ignore.txt' = 'not markdown' }
    $fromPrivate = Get-ActsFor @('MEMORY') @{ seedPath = $private }
    Check ($fromPrivate.seed.source -ceq 'private' -and (@($fromPrivate.seed.files.Keys) -join ',') -ceq 'overview.md,sub/more.md' -and $fromPrivate.seed.files['overview.md'] -ceq "# Notes`nline two`n") 'A private seed holds its .md files in sub-folders too, skips hidden folders and other file types, and has LF endings'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (Join-Path $root 'docs') } } 'outside the repository'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = 'relative\folder' } } 'existing folder, given as a full path'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-TempPath) } } 'existing folder, given as a full path'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-SeedFolder @{ 'readme.txt' = 'no notes here' }) } } 'between 1 and 40'
    $many = @{}
    1..41 | ForEach-Object { $many["n$_.md"] = 'x' }
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-SeedFolder $many) } } 'between 1 and 40'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-SeedFolder @{ 'big.md' = ('x' * 65537) }) } } 'over 64 KB'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-SeedFolder @{ 'my notes.md' = 'x' }) } } 'needs a plain name'
    Throws { Get-ActsFor @('MEMORY') @{ seedPath = (New-SeedFolder @{ 'sub folder/a.md' = 'x' }) } } 'needs a plain name'
    foreach ($good in 'a.md', 'A-b_c.1.md', 'x/y/z.md') { Check ($null -ne (New-SreNotesArchive -Files @{ $good = 'x' })) "The archive builder accepts the name the seed check accepts: $good" }
    foreach ($bad in '../x.md', '/abs.md', '.hidden.md', 'a b.md', 'a//b.md', ('a' * 91)) { Throws { New-SreNotesArchive -Files @{ $bad = 'x' } } 'not a plain relative path' }

    # --- The whole desired configuration -------------------------------------------------------------------------------------------------
    $desiredAll = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $allPath
    Check ($null -eq $desiredAll.handler -and (@($desiredAll.extraHandlers | ForEach-Object { $_.name }) -join ',') -match ',estate-auditor,deck-builder$' -and @($desiredAll.extraHandlers).Count -eq 3 -and @($desiredAll.plans).Count -eq 1) 'T12 with all three modules has no base handler, three extra handlers (the release investigator and the two agents) and the one T12 plan'
    $desiredAsk = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath (New-ActsSkinFile -Scenarios @('ASK', 'MEMORY'))
    Check ($null -eq $desiredAsk.handler -and @($desiredAsk.extraHandlers).Count -eq 0 -and @($desiredAsk.plans).Count -eq 0 -and $null -eq $desiredAsk.release -and (@($desiredAsk.acts.modules) -join ',') -ceq 'ASK,MEMORY') 'ASK and MEMORY alone need no handler, no plan and no release'
    $desiredT09 = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath (New-ActsSkinFile -Scenarios @('T09', 'ASK'))
    Check ($null -ne $desiredT09.handler -and @($desiredT09.extraHandlers).Count -eq 0 -and @($desiredT09.plans).Count -eq 1 -and $null -ne $desiredT09.acts) 'T09 with ASK keeps the base handler and its plan'
    Check ($null -eq (Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath (New-ActsSkinFile -Scenarios @('T09', 'T11'))).acts) 'A skin without the three modules has no acts section'
    $initializeText = Get-Content -LiteralPath (Join-Path $root 'scripts\Initialize-SreConfiguration.ps1') -Raw
    $orderMarkers = @('Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before', 'Invoke-SreConfigurationReconcile -Desired', 'Invoke-SreActs -Context', 'Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After')
    $positions = @($orderMarkers | ForEach-Object { $initializeText.IndexOf($_, [StringComparison]::Ordinal) })
    Check (@($positions | Where-Object { $_ -lt 0 }).Count -eq 0 -and ($positions[0] -lt $positions[1]) -and ($positions[1] -lt $positions[2]) -and ($positions[2] -lt $positions[3])) 'Apply order: the GitHub guard first, then the handlers and plans, then the acts, and the repository (the one human sign-in) last'

    # --- The schema -----------------------------------------------------------------------------------------------------------------------
    foreach ($ok in @(@('ASK'), @('MEMORY'), @('T12', 'PROACTIVE'), @('T09', 'T12', 'ASK', 'MEMORY', 'PROACTIVE'))) { Check ($null -ne (Get-DemoSkin -Path (New-ActsSkinFile -Scenarios $ok) -RepoRoot $root)) "The schema accepts $($ok -join ' + ')" }
    Throws { Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('T09', 'PROACTIVE')) -RepoRoot $root } 'Invalid|not valid|schema'
    Throws { Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('NOPE')) -RepoRoot $root } 'Invalid|not valid|schema'
    Throws { Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('ASK') -Memory @{ seedPath = 5 }) -RepoRoot $root } 'Invalid|not valid|schema'
    Throws { Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('ASK') -Memory @{ other = 'x' }) -RepoRoot $root } 'Invalid|not valid|schema'
    Check ($null -ne (Get-DemoSkin -Path (New-ActsSkinFile -Scenarios @('MEMORY') -Memory @{}) -RepoRoot $root)) 'An empty memory section is valid'

    # --- The plan: what an apply would write ---------------------------------------------------------------------------------------------
    $desired = $desiredAll
    function New-Observed {
        param([switch]$Applied, [string]$Eol = "`n", [switch]$Envelope, [switch]$On)
        $live = { param($text) ([string]$text) -replace "`n", $Eol }
        $observed = @{ skills = @{}; tasks = @{}; notes = [pscustomobject]@{ exists = $false; path = $notesFolder; files = @() } }
        foreach ($skill in $desired.acts.skills) { $observed.skills[$skill.name] = $null }
        foreach ($task in $desired.acts.tasks) { $observed.tasks[$task.name] = $null }
        if ($Applied) {
            foreach ($skill in $desired.acts.skills) {
                $observed.skills[$skill.name] = @{ name = $skill.name; type = 'Skill'; properties = @{ name = $skill.name; description = $skill.description; tools = @(); skillContent = (& $live $skill.content); additionalFiles = @() } }
            }
            foreach ($task in $desired.acts.tasks) {
                $flat = @{ id = "id-$($task.name)"; name = $task.name; description = $task.description; cronExpression = $task.cronExpression; agentPrompt = (& $live $task.agentPrompt); agent = $task.agent; agentMode = 'Review' }
                if ($Envelope) { $flat.isEnabled = [bool]$On } else { $flat.status = $(if ($On) { 'Active' } else { 'Paused' }) }
                $observed.tasks[$task.name] = if ($Envelope) { @{ name = $task.name; type = 'ScheduledTask'; properties = $flat } } else { $flat }
            }
            $observed.notes = [pscustomobject]@{ exists = $true; path = $notesFolder; files = @([pscustomobject]@{ path = "$notesFolder/overview.md"; relativePath = 'overview.md'; size = 10; modified = '' }) }
        }
        $observed
    }
    $skillNames = @($desired.acts.skills | ForEach-Object { $_.name })
    $taskNames = @($desired.acts.tasks | ForEach-Object { $_.name })
    $empty = Get-SreActsPlan -Desired $desired -Observed (New-Observed)
    Check ((@($empty.operations | ForEach-Object { $_.name }) -join ',') -ceq ((@($skillNames | ForEach-Object { "skill:$_" }) + @($taskNames | ForEach-Object { "task:$_" }) + 'seed:notes') -join ',')) 'An empty agent needs the skills, then the tasks, then the seed'
    $taskOperation = $empty.operations | Where-Object { $_.name -ceq "task:$($taskNames[0])" }
    Check ($taskOperation.reason -ceq 'create (Off)' -and $taskOperation.body.type -ceq 'ScheduledTask' -and $taskOperation.body.properties.isEnabled -eq $false -and $taskOperation.body.properties.agentMode -ceq 'Review' -and $taskOperation.body.properties.agent -ceq 'estate-auditor' -and $taskOperation.path -ceq "/api/v2/extendedAgent/scheduledtasks/$($taskNames[0])") 'A new task is one REST PUT, created Off, in Review mode, for its agent'
    $skillOperation = $empty.operations | Where-Object { $_.name -ceq "skill:$($skillNames[0])" }
    Check ($skillOperation.reason -ceq 'create' -and $skillOperation.body.type -ceq 'Skill' -and @($skillOperation.body.properties.tools).Count -eq 0 -and $skillOperation.body.properties.skillContent -ceq $desired.acts.skills[0].content) 'A new skill carries its text and no tool list'
    $seedOperation = $empty.operations | Where-Object { $_.name -ceq 'seed:notes' }
    Check ($seedOperation.method -ceq 'Post' -and $seedOperation.kind -ceq 'notes' -and (@($seedOperation.files.Keys) -join ',') -ceq 'overview.md') 'The seed is one POST of overview.md'
    $applied = Get-SreActsPlan -Desired $desired -Observed (New-Observed -Applied)
    Check ($applied.operations.Count -eq 0 -and $applied.notes.Count -eq 1 -and $applied.notes[0] -match 'already has 1 notes file') 'An applied agent needs no writes, and a notes folder that has files is left alone'
    Check ((Get-SreActsPlan -Desired $desired -Observed (New-Observed -Applied -Eol "`r`n")).operations.Count -eq 0) 'Text the service returns with CRLF is not drift'
    Check ((Get-SreActsPlan -Desired $desired -Observed (New-Observed -Applied -Envelope -On)).operations.Count -eq 0 -and (Get-SreActsPlan -Desired $desired -Observed (New-Observed -Applied -On)).operations.Count -eq 0) 'A task the agent returns wrapped in name, type and properties, or one that is On, is not drift: on or off is yours'
    $view = Get-SreActsTaskView $null
    Check ($null -eq $view) 'No task reads as no view'
    $flatView = Get-SreActsTaskView @{ id = 'x'; status = 'Active'; cronExpression = '0 8 * * *'; agentPrompt = "a`r`nb"; agent = 'estate-auditor'; agentMode = 'Review'; executionCount = 3; lastExecutionTime = 't1'; nextExecutionTime = 't2' }
    Check ($flatView.enabled -and $flatView.agentPrompt -ceq "a`nb" -and $flatView.runs -ceq '3' -and $flatView.lastRun -ceq 't1' -and -not (Get-SreActsTaskView @{ status = 'Paused'; isEnabled = $true }).enabled -and (Get-SreActsTaskView @{ properties = @{ isEnabled = $true } }).enabled -and -not (Get-SreActsTaskView @{ name = 'x' }).enabled) 'A task view is Active or Paused by its status, else by isEnabled, else Off, with CRLF removed from the prompt'
    $edited = New-Observed -Applied
    $edited.skills[$skillNames[1]].properties.skillContent += ' edited'
    $editedPlan = Get-SreActsPlan -Desired $desired -Observed $edited
    Check ($editedPlan.operations.Count -eq 1 -and $editedPlan.operations[0].name -ceq "skill:$($skillNames[1])" -and $editedPlan.operations[0].reason -ceq 'update') 'An edited skill is updated and nothing else'
    $withTools = New-Observed -Applied
    $withTools.skills[$skillNames[2]].properties.tools = @('SomeTool')
    $noTools = New-Observed -Applied
    $noTools.skills[$skillNames[0]].properties.tools = $null
    $null = $noTools.skills[$skillNames[1]].properties.Remove('tools')
    Check ((Get-SreActsPlan -Desired $desired -Observed $withTools).operations[0].name -ceq "skill:$($skillNames[2])" -and (Get-SreActsPlan -Desired $desired -Observed $noTools).operations.Count -eq 0) 'A skill that lists tools is rewritten; one the service returns with tools null or left out is not drift'
    $moved = New-Observed -Applied -On
    $moved.tasks[$taskNames[1]].cronExpression = '0 1 * * *'
    $movedPlan = Get-SreActsPlan -Desired $desired -Observed $moved
    Check ($movedPlan.operations.Count -eq 1 -and $movedPlan.operations[0].name -ceq "task:$($taskNames[1])" -and $movedPlan.operations[0].reason -match '^update' -and $movedPlan.operations[0].body.properties.isEnabled -eq $true -and $movedPlan.operations[0].body.properties.cronExpression -ceq $desired.acts.tasks[1].cronExpression) 'A task with another schedule is put back, and a task you turned On stays On'
    $movedOff = New-Observed -Applied
    $movedOff.tasks[$taskNames[1]].cronExpression = '0 1 * * *'
    Check ((Get-SreActsPlan -Desired $desired -Observed $movedOff).operations[0].body.properties.isEnabled -eq $false) 'A task that is Off stays Off when it is corrected'
    $autonomous = New-Observed -Applied
    $autonomous.tasks[$taskNames[2]].agentMode = 'Autonomous'
    $reviewCase = New-Observed -Applied
    $reviewCase.tasks[$taskNames[2]].agentMode = 'review'
    Check ((Get-SreActsPlan -Desired $desired -Observed $autonomous).operations[0].name -ceq "task:$($taskNames[2])" -and (Get-SreActsPlan -Desired $desired -Observed $autonomous).operations[0].body.properties.agentMode -ceq 'Review' -and (Get-SreActsPlan -Desired $desired -Observed $reviewCase).operations.Count -eq 0) 'A task that is not in Review mode is put back in Review mode; the case of the word does not matter'
    $reworded = New-Observed -Applied
    $reworded.tasks[$taskNames[0]].description = 'other'
    $reprompted = New-Observed -Applied
    $reprompted.tasks[$taskNames[0]].agentPrompt += ' more'
    $rebound = New-Observed -Applied
    $rebound.tasks[$taskNames[0]].agent = 'deck-builder'
    Check ((Get-SreActsPlan -Desired $desired -Observed $reworded).operations.Count -eq 1 -and (Get-SreActsPlan -Desired $desired -Observed $reprompted).operations.Count -eq 1 -and (Get-SreActsPlan -Desired $desired -Observed $rebound).operations.Count -eq 1) 'A changed description, prompt or agent is corrected'
    $folderEmpty = New-Observed -Applied
    $folderEmpty.notes = [pscustomobject]@{ exists = $true; path = $notesFolder; files = @() }
    $folderUnread = New-Observed -Applied
    $folderUnread.notes = [pscustomobject]@{ error = 'List failed: HTTP 500'; exists = $false; files = @() }
    $emptyFolderPlan = Get-SreActsPlan -Desired $desired -Observed $folderEmpty
    $unreadPlan = Get-SreActsPlan -Desired $desired -Observed $folderUnread
    Check (@($emptyFolderPlan.operations | Where-Object { $_.name -ceq 'seed:notes' }).Count -eq 1 -and @($unreadPlan.operations).Count -eq 0 -and $unreadPlan.notes[0] -match 'could not be read' -and $unreadPlan.notes[0] -match 'HTTP 500') 'An empty notes folder is seeded; one that cannot be read is reported and never written to'
    $askDesired = @{ acts = $askOnly }
    Check ((Get-SreActsPlan -Desired $askDesired -Observed @{ skills = @{ 'estate-query' = $null }; tasks = @{}; notes = $null }).operations.Count -eq 1) 'A skin with only ASK plans only its one skill'

    # --- The apply against a stand-in agent ----------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $base = New-BackupBase
    $preview = Invoke-SreActs -Context $context -Desired $desired -BackupPath $base -WhatIf 6>$null
    Check (-not $preview.changed -and $preview.preview.operations.Count -eq 8) 'WhatIf previews the eight writes'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0 -and -not (Test-Path "$base.acts.json")) 'WhatIf writes nothing, not even a backup'
    $output = @(Invoke-SreActs -Context $context -Desired $desired -BackupPath $base 6>&1)
    $result = $output | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
    Check ($result.changed -and $result.verified -and $result.seed -ceq 'verified' -and @($result.operations).Count -eq 8) 'The apply writes the eight settings and verifies them by reading back'
    $expectedWrites = @($skillNames | ForEach-Object { "PUT /api/v2/extendedAgent/skills/$_" }) + @($taskNames | ForEach-Object { "PUT /api/v2/extendedAgent/scheduledtasks/$_" }) + 'POST /api/v1/WorkspaceMemory/synthesized-knowledge'
    Check (((Get-FakeAgentWrites -Agent $agent) -join '|') -ceq ($expectedWrites -join '|')) 'One write each: the skills, then the tasks, then the notes'
    Check (@($agent.state.tasks.Values | Where-Object { $_.status -ne 'Paused' }).Count -eq 0 -and @($agent.state.tasks.Values | Where-Object { $_.agentMode -cne 'Review' }).Count -eq 0 -and $agent.state.tasks.Count -eq 3) 'Three tasks exist, all Off and in Review mode'
    Check ((@($agent.state.log | Where-Object { $_.method -eq 'PUT' -and $_.path -like '*scheduledtasks*' } | ForEach-Object { $_.body.properties.isEnabled }) -join ',') -ceq 'False,False,False') 'Each task PUT says isEnabled false'
    Check (@($agent.state.log | Where-Object { $_.path -like '*github*' -or $_.path -like '*repos*' -or $_.path -like '*settings*' -or $_.path -like '*hooks*' -or $_.path -like '*customInstructions*' -or $_.path -like '*/agents/*' }).Count -eq 0) 'The acts touch no GitHub, repository, tool policy, hook, instruction or agent route'
    $seedFile = "$notesFolder/overview.md"
    Check ($agent.state.files.ContainsKey($seedFile) -and [Text.Encoding]::UTF8.GetString([byte[]]$agent.state.files[$seedFile]) -ceq $desired.acts.seed.files['overview.md'] -and (@($agent.state.uploads[0]) -join ',') -ceq 'overview.md') 'The seed arrives as one tar.gz and unpacks to overview.md with the exact text'
    $upload = @($agent.state.log | Where-Object { $_.path -like '*synthesized-knowledge' })
    Check ($upload.Count -eq 1 -and $upload[0].contentType -like 'application/gzip*' -and $upload[0].bytes -gt 100) 'The upload is application/gzip'
    $backup = Get-Content -LiteralPath "$base.acts.json" -Raw | ConvertFrom-Json
    Check ($result.backupPath -ceq [IO.Path]::GetFullPath("$base.acts.json") -and -not $result.backupPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and $null -ne $backup.skills -and $null -ne $backup.tasks) 'The backup of what was there before is outside the repository'
    $mark = $agent.state.log.Count
    $again = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    Check (-not $again.changed -and $again.verified -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0) 'Applying again writes nothing'
    $agent.state.tasks[$taskNames[1]].status = 'Active'
    $agent.state.tasks[$taskNames[1]].cronExpression = '0 1 * * *'
    $mark = $agent.state.log.Count
    $fixed = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    $fixPut = @($agent.state.log | Select-Object -Skip $mark | Where-Object { $_.method -eq 'PUT' })
    Check ($fixed.changed -and $fixPut.Count -eq 1 -and $fixPut[0].path -ceq "/api/v2/extendedAgent/scheduledtasks/$($taskNames[1])" -and $fixPut[0].body.properties.isEnabled -eq $true -and $agent.state.tasks[$taskNames[1]].status -ceq 'Active' -and $agent.state.tasks[$taskNames[1]].cronExpression -ceq $desired.acts.tasks[1].cronExpression) 'A task you turned On has its schedule corrected and stays On'
    $readiness = @(Get-SreActsDataChecks -Context $context -Desired $desired)
    $byId = @{}
    foreach ($row in $readiness) { $byId[$row.id] = $row }
    Check (@($readiness | Where-Object { $_.required -and $_.status -ne 'pass' }).Count -eq 0 -and $byId['ACTS-skills'].required -and $byId['ACTS-tasks'].required -and -not $byId['ACTS-schedules'].required -and -not $byId['ACTS-notes'].required -and $byId['ACTS-notes'].status -ceq 'pass') 'Readiness: skills and tasks pass and are required; schedules and notes are informational'
    Check ($byId['ACTS-schedules'].observed[$taskNames[1]] -ceq 'On' -and $byId['ACTS-schedules'].observed[$taskNames[0]] -ceq 'Off' -and $byId['ACTS-schedules'].status -ceq 'pass') 'The schedules row shows which task you turned On, and never fails'

    $empty = New-Agent
    $emptyContext = New-TestDataContext -Agent $empty -SubscriptionId $subscription -TenantId $tenant
    $rows = @(Get-SreActsDataChecks -Context $emptyContext -Desired $desired)
    Check (@($rows | Where-Object { $_.id -in 'ACTS-skills', 'ACTS-tasks' -and $_.status -eq 'fail' -and $_.required }).Count -eq 2 -and @($rows | Where-Object { $_.id -ceq 'ACTS-notes' -and $_.status -ceq 'pending' }).Count -eq 1 -and (@($rows | Where-Object { $_.id -ceq 'ACTS-schedules' })[0].observed[$taskNames[0]]) -ceq 'absent') 'Readiness on an empty agent fails the two required rows, shows the tasks absent and leaves the notes pending'
    Check (@(Get-SreActsDataChecks -Context $emptyContext -Desired @{ acts = $askOnly }).Count -eq 1) 'An ASK-only skin has only the skills row'

    # --- Failures never replay a write -----------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.ignoreWrites = $true
    $slow = $null
    try { Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) -ReadBackSeconds 1 6>$null } catch { $slow = $_.Exception.Message }
    Check ($slow -match 'Read-back does not show' -and $slow -match 'Nothing was replayed' -and $slow -match 'after 1 s') 'A write the read-back never shows is reported, not repeated'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 8) 'Exactly one write per setting, none replayed'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.failPut = "scheduledtasks/$($taskNames[1])$"
    Throws { Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null } "Apply task:$($taskNames[1]) failed: HTTP 400"
    Check ((@(Get-FakeAgentWrites -Agent $agent).Count) -eq 6 -and $agent.state.tasks.Count -eq 1 -and $agent.state.files.Count -eq 0) 'A rejected write stops the apply: it is not retried and nothing after it is attempted'
    $agent.state.failPut = $null
    $retry = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    Check ($retry.changed -and $retry.verified -and @($retry.operations).Count -eq 3 -and $agent.state.tasks.Count -eq 3) 'A later apply converges and writes only what is still missing'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.ignoreUpload = $true
    $softOutput = @(Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) -ReadBackSeconds 1 *>&1)
    $soft = $softOutput | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
    Check ($soft.changed -and $soft.seed -ceq 'unverified' -and (Get-WarningText $softOutput) -match 'upload was accepted but no notes file appeared' -and (Get-WarningText $softOutput) -match 'was not repeated') 'A notes upload that does not show up is a warning, never a reason to fail the skills and tasks'
    Check (@(Get-FakeAgentWrites -Agent $agent | Where-Object { $_ -like 'POST *' }).Count -eq 1) 'The unverified upload was sent once'

    # --- The notes folder is only seeded when it is empty ------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.files["$notesFolder/learned.md"] = [Text.Encoding]::UTF8.GetBytes("learned`n")
    $noSeed = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    Check ($noSeed.changed -and @($noSeed.operations).Count -eq 7 -and @(Get-FakeAgentWrites -Agent $agent | Where-Object { $_ -like 'POST *' }).Count -eq 0 -and $noSeed.notes[0] -match 'already has 1 notes file') 'A notes folder that already has files is not seeded, and the rest still applies'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.listStatus = 500
    $unreadOutput = @(Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>&1)
    $unread = $unreadOutput | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
    Check ($unread.changed -and @($unread.operations).Count -eq 7 -and @(Get-FakeAgentWrites -Agent $agent | Where-Object { $_ -like 'POST *' }).Count -eq 0 -and (Get-HostText $unreadOutput) -match 'could not be read') 'A notes folder that cannot be read is never seeded: it is not taken for empty'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.dirs = @("$workspaceRoot/memories", $notesFolder)
    $seeded = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    Check ($seeded.seed -ceq 'verified' -and @(Get-FakeAgentWrites -Agent $agent | Where-Object { $_ -like 'POST *' }).Count -eq 1) 'A notes folder that exists and is empty is seeded'

    # --- Backups ------------------------------------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    Throws { Invoke-SreActs -Context $context -Desired $desired -BackupPath (Join-Path $root 'backup-inside-repo') 6>$null } 'outside the repository'
    Throws { Invoke-SreActs -Context $context -Desired $desired -BackupPath (Join-Path ([IO.Path]::GetTempPath()) "missing-$([guid]::NewGuid())\backup") 6>$null } 'parent directory must already exist'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0) 'A bad backup path stops the apply before the first write'
    $base = New-BackupBase
    [IO.File]::WriteAllText("$base.acts.json", '{}')
    Throws { Invoke-SreActs -Context $context -Desired $desired -BackupPath $base 6>$null } 'already exists'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0 -and (Get-Content -LiteralPath "$base.acts.json" -Raw) -eq '{}') 'An existing backup is never overwritten, and nothing is written without one'

    # --- Threads and the scheduled-task helper -----------------------------------------------------------------------------------------------
    Check ((Find-SreThreadId -Value @{ execution = @{ threadId = 'abc-1'; manualExecution = $true } }) -ceq 'abc-1' -and (Find-SreThreadId -Value ([pscustomobject]@{ threadId = 'def' })) -ceq 'def' -and (Find-SreThreadId -Value ([pscustomobject]@{ a = [pscustomobject]@{ b = @{ ThreadID = 'deep' } } })) -ceq 'deep') 'A thread ID is found wherever the answer puts it'
    Check ((Find-SreThreadId -Value $null) -ceq '' -and (Find-SreThreadId -Value 'text') -ceq '' -and (Find-SreThreadId -Value @{ threadId = 5 }) -ceq '' -and (Find-SreThreadId -Value @{ x = @{ y = @{ z = @{ w = @{ v = @{ threadId = 'too-deep' } } } } } }) -ceq '') 'No thread ID in the answer reads as empty'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $null = Invoke-SreActs -Context $context -Desired $desired -BackupPath (New-BackupBase) 6>$null
    $agent.state.threads = @(@{ id = 'idle-thread' }, @{ id = 'busy-thread' })
    $agent.state.messages['idle-thread'] = @(@{ id = 'm1'; text = 'a' }, @{ id = 'm2'; text = 'b' })
    $agent.state.messages['busy-thread'] = @(@{ id = 'm1'; text = 'a' })
    $agent.state.threadStates['idle-thread'] = 'Idle'
    $agent.state.threadStates['busy-thread'] = 'Running'
    $idle = Wait-SreThreadIdle -Context $context -ThreadId 'idle-thread' -TimeoutSeconds 20 -PollSeconds 1
    Check ($idle.idle -and $idle.messages -eq 2 -and $idle.state -ceq 'Idle') 'An idle thread whose message count has stopped changing is idle'
    $busy = Wait-SreThreadIdle -Context $context -ThreadId 'busy-thread' -TimeoutSeconds 2 -PollSeconds 1
    Check (-not $busy.idle -and $busy.state -ceq 'Running' -and $busy.messages -eq 1) 'A thread that is still running is reported as running at the timeout'
    $missing = Wait-SreThreadIdle -Context $context -ThreadId 'not-there' -TimeoutSeconds 1 -PollSeconds 1
    Check (-not $missing.idle -and $missing.messages -eq 0) 'A thread that has no messages yet is not idle'
    Throws { Wait-SreThreadIdle -Context $context -ThreadId 'x' -TimeoutSeconds 0 } 'Cannot validate|range'

    $status = Get-HostText (Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Status 6>&1)
    Check (@($status -split "`n" | Where-Object { $_ -match ' Off ' -and $_ -match "schedule '" -and $_ -match 'mode Review' }).Count -eq 3 -and $status -match 'not scheduled') 'Status shows each task Off, with its schedule and mode'
    $none = New-Agent
    $noneContext = New-TestDataContext -Agent $none -SubscriptionId $subscription -TenantId $tenant
    Check ((Get-HostText (Invoke-SreActsTask -Context $noneContext -TaskNames $taskNames -Action Status 6>&1)) -match 'not on the agent') 'Status says so when the tasks are not on the agent'
    Throws { Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run } 'Say which task with -Name'
    Throws { Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Enable -Name 'not-a-task' } "Unknown task 'not-a-task'"
    Throws { Invoke-SreActsTask -Context $noneContext -TaskNames $taskNames -Action Run -Name $taskNames[0] } 'is not on the agent'
    $mark = $agent.state.log.Count
    Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run -Name $taskNames[0] -WhatIf 6>$null | Out-Null
    Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Enable -Name $taskNames[0] -WhatIf 6>$null | Out-Null
    Check (@(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0) 'Run and Enable preview under WhatIf and write nothing'
    $mark = $agent.state.log.Count
    $runOutput = @(Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run -Name $taskNames[0] -Wait -PollSeconds 1 6>&1)
    $run = $runOutput | Where-Object { $_.PSObject.Properties['threadId'] } | Select-Object -First 1
    $taskId = $agent.state.tasks[$taskNames[0]].id
    Check ($run.task -ceq $taskNames[0] -and $run.status -eq 200 -and $run.threadId -and $run.waited.idle -and (Get-FakeAgentWrites -Agent $agent -Since $mark) -contains "POST /api/v1/scheduledtasks/$taskId/execute" -and (Get-HostText $runOutput) -match 'Started' -and (Get-HostText $runOutput) -match 'The agent is idle after') 'Run starts the task by its ID, prints the thread and follows it until the agent is idle'
    Check ($agent.state.tasks[$taskNames[0]].status -ceq 'Paused') 'Running a task does not turn its schedule On'
    $deckRun = @(Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run -Name 'governance-deck' -Wait -PollSeconds 1 6>&1)
    Check ((Get-HostText $deckRun) -match 'Export-SreAgentFiles\.ps1 -Source Thread -ThreadId') 'After the deck task the helper says how to fetch the file'
    $agent.state.omitTaskId = $true
    $viaList = Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run -Name $taskNames[1] 6>$null
    Check ($viaList.threadId -and $viaList.status -eq 200) 'When the task read has no ID, Run finds it in the task list'
    $agent.state.omitTaskId = $false
    $agent.state.refuseRunNow = $true
    Throws { Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Run -Name $taskNames[0] 6>$null } 'HTTP 409\. The task is Off.*-Action Enable.*-Action Run.*-Action Disable'
    $agent.state.refuseRunNow = $false

    $mark = $agent.state.log.Count
    $enableOutput = Get-HostText (Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Enable -Name $taskNames[0] -PollSeconds 1 6>&1)
    $enablePut = @($agent.state.log | Select-Object -Skip $mark | Where-Object { $_.method -eq 'PUT' })
    Check ($enableOutput -match 'is now On' -and $enablePut.Count -eq 1 -and $enablePut[0].body.properties.isEnabled -eq $true -and $enablePut[0].body.properties.cronExpression -ceq $desired.acts.tasks[0].cronExpression -and $enablePut[0].body.properties.agentPrompt -ceq $desired.acts.tasks[0].agentPrompt -and $enablePut[0].body.properties.agentMode -ceq 'Review' -and $agent.state.tasks[$taskNames[0]].status -ceq 'Active') 'Enable sends the task as it is on the agent with isEnabled true, in Review mode, and checks it is On'
    $mark = $agent.state.log.Count
    Check ((Get-HostText (Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Enable -Name $taskNames[0] 6>&1)) -match 'already On' -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0) 'Enable on a task that is On writes nothing'
    $agent.state.tasks[$taskNames[0]].cronExpression = '15 3 * * *'
    $agent.state.tasks[$taskNames[0]].agentPrompt = 'A prompt edited in the portal.'
    $null = Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Disable -Name $taskNames[0] -PollSeconds 1 6>$null
    Check ($agent.state.tasks[$taskNames[0]].status -ceq 'Paused' -and $agent.state.tasks[$taskNames[0]].cronExpression -ceq '15 3 * * *' -and $agent.state.tasks[$taskNames[0]].agentPrompt -ceq 'A prompt edited in the portal.') 'Disable keeps the schedule and prompt as they are on the agent'
    $agent.state.tasks[$taskNames[1]].status = 'Active'
    $agent.state.ignoreIsEnabled = $true
    $mark = $agent.state.log.Count
    Throws { Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Disable -Name $taskNames[1] -PollSeconds 1 -ReadBackSeconds 1 6>$null } 'does not show .* as Off after 1 s'
    $agent.state.ignoreIsEnabled = $false
    Check (@(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 1) 'A switch the agent does not show is reported after one PUT, not repeated'
    $agent.state.taskEnvelope = $true
    Check ((Get-HostText (Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action Status 6>&1)) -match "$($taskNames[1])\s+On" ) 'Status reads tasks the agent returns wrapped in name, type and properties'
    $agent.state.taskEnvelope = $false

    # --- The workspace file helpers ----------------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $binary = [byte[]](0x50, 0x4B, 0x03, 0x04, 0xFF, 0x00, 0x80, 0x0A, 0x0D, 0x7F)
    $agent.state.files["$notesFolder/overview.md"] = [Text.Encoding]::UTF8.GetBytes("# Overview`n")
    $agent.state.files["$notesFolder/deep/a/b.md"] = [Text.Encoding]::UTF8.GetBytes('b')
    $agent.state.files["$workspaceRoot/memories/sessionInsights/s.md"] = [Text.Encoding]::UTF8.GetBytes('s')
    $agent.state.files["$workspaceRoot/tmp/ThreadFiles/t1/deck.pptx"] = $binary
    $agent.state.files["$workspaceRoot/tmp/ThreadFiles/t2/bad.pptx"] = [Text.Encoding]::UTF8.GetBytes('this is text, not a zip')
    foreach ($ok in $workspaceRoot, $notesFolder, "$workspaceRoot/tmp/ThreadFiles/abc-1.2") { Assert-SreWorkspacePath -Path $ok; Check $true "Workspace path accepted: $ok" }
    foreach ($bad in '/etc/passwd', "$workspaceRoot/../x", "$workspaceRoot/a/./b", "$workspaceRoot/a;b", "$workspaceRoot/a?b", "${workspaceRoot}X", "$workspaceRoot/", '/root/sreagent') { Throws { Assert-SreWorkspacePath -Path $bad } 'Not a plain path' }
    $top = @(Get-SreWorkspaceEntries -Context $context -Path "$workspaceRoot/memories")
    Check ((Join-Sorted ($top | ForEach-Object { $_.name })) -ceq 'sessionInsights,synthesizedKnowledge' -and @($top | Where-Object { -not $_.isDir }).Count -eq 0) 'A folder lists its entries'
    $found = @(Get-SreWorkspaceFiles -Context $context -Path "$workspaceRoot/memories")
    Check ((Join-Sorted ($found | ForEach-Object { $_.relativePath })) -ceq 'sessionInsights/s.md,synthesizedKnowledge/deep/a/b.md,synthesizedKnowledge/overview.md' -and ($found | Where-Object { $_.relativePath -ceq 'synthesizedKnowledge/overview.md' }).size -eq 11) 'Files are listed recursively with their relative path and size'
    Check (@(Get-SreWorkspaceFiles -Context $context -Path "$workspaceRoot/memories" -MaxDepth 1).Count -eq 2 -and @(Get-SreWorkspaceFiles -Context $context -Path "$workspaceRoot/memories" -MaxFiles 2).Count -eq 2 -and @(Get-SreWorkspaceFiles -Context $context -Path "$workspaceRoot/memories" -MaxDepth 0).Count -eq 0) 'Depth and file-count limits are honoured'
    Check ([Convert]::ToBase64String((Get-SreWorkspaceFile -Context $context -Path "$workspaceRoot/tmp/ThreadFiles/t1/deck.pptx")) -ceq [Convert]::ToBase64String($binary)) 'A binary file comes back byte for byte'
    $agent.state.files["$workspaceRoot/tmp/ThreadFiles/t4/empty.bin"] = [byte[]]::new(0)
    $agent.state.files["$workspaceRoot/tmp/ThreadFiles/t4/one.bin"] = [byte[]](65)
    $emptyBytes = Get-SreWorkspaceFile -Context $context -Path "$workspaceRoot/tmp/ThreadFiles/t4/empty.bin"
    $oneByte = Get-SreWorkspaceFile -Context $context -Path "$workspaceRoot/tmp/ThreadFiles/t4/one.bin"
    Check ($emptyBytes -is [byte[]] -and $emptyBytes.Length -eq 0 -and $oneByte -is [byte[]] -and $oneByte.Length -eq 1 -and $oneByte[0] -eq 65) 'An empty file and a one-byte file come back as byte arrays, not nothing or a single number'
    Throws { Get-SreWorkspaceFile -Context $context -Path "$workspaceRoot/tmp/ThreadFiles/t1/nothing.pptx" } 'Read .* failed: HTTP 404'
    Check ((Test-SreWorkspaceFolder -Context $context -Path $notesFolder) -and (Test-SreWorkspaceFolder -Context $context -Path $workspaceRoot) -and -not (Test-SreWorkspaceFolder -Context $context -Path "$workspaceRoot/memories/nothing") -and -not (Test-SreWorkspaceFolder -Context $context -Path "$workspaceRoot/nothing/at/all")) 'A folder is shown to be there or not by listing down from the root'
    $notes = Get-SreNotesState -Context $context
    Check ($notes.exists -and (Join-Sorted ($notes.files | ForEach-Object { $_.relativePath })) -ceq 'deep/a/b.md,overview.md') 'The notes state lists the files under the notes folder only'
    $fresh = New-Agent
    $freshContext = New-TestDataContext -Agent $fresh -SubscriptionId $subscription -TenantId $tenant
    $absent = Get-SreNotesState -Context $freshContext
    Check (-not $absent.exists -and @($absent.files).Count -eq 0) 'No memories folder reads as absent'
    $fresh.state.listStatus = 500
    Throws { Get-SreNotesState -Context $freshContext } 'List .* failed: HTTP 500'
    Throws { Test-SreWorkspaceFolder -Context $freshContext -Path $notesFolder } 'failed: HTTP 500'

    # --- The notes archive ---------------------------------------------------------------------------------------------------------------------
    $archive = New-SreNotesArchive -Files ([ordered]@{ 'overview.md' = "Hello`n"; 'sub/b.md' = 'x'; 'sub/deeper/c.md' = ('y' * 700) })
    Check ($archive[0] -eq 0x1F -and $archive[1] -eq 0x8B) 'The archive is gzip'
    Check ([Convert]::ToBase64String($archive) -ceq [Convert]::ToBase64String((New-SreNotesArchive -Files ([ordered]@{ 'overview.md' = "Hello`n"; 'sub/b.md' = 'x'; 'sub/deeper/c.md' = ('y' * 700) })))) 'The same notes give the same bytes'
    $sink = New-Agent
    $sinkContext = New-TestDataContext -Agent $sink -SubscriptionId $subscription -TenantId $tenant
    $sent = Send-SreNotes -Context $sinkContext -Files ([ordered]@{ 'overview.md' = "Hello`n"; 'sub/b.md' = 'x'; 'sub/deeper/c.md' = ('y' * 700) })
    Check ($sent.Status -eq 200 -and (@($sink.state.uploads[0]) -join ',') -ceq 'overview.md,sub/b.md,sub/deeper/c.md' -and [Text.Encoding]::UTF8.GetString([byte[]]$sink.state.files["$notesFolder/sub/deeper/c.md"]) -ceq ('y' * 700) -and [Text.Encoding]::UTF8.GetString([byte[]]$sink.state.files["$notesFolder/overview.md"]) -ceq "Hello`n") 'The stand-in agent unpacks the archive: checksums valid, nested files in place, text exact'
    $tarCommand = Get-Command tar -CommandType Application -ErrorAction SilentlyContinue
    if ($tarCommand) {
        $archivePath = New-TempPath '.tar.gz'
        [IO.File]::WriteAllBytes($archivePath, $archive)
        $listing = @(& $tarCommand.Source -tzf $archivePath | ForEach-Object { ($_ -replace '^\./', '').TrimEnd('/') } | Where-Object { $_ })
        Check ($LASTEXITCODE -eq 0 -and (Join-Sorted $listing) -ceq 'overview.md,sub,sub/b.md,sub/deeper,sub/deeper/c.md') 'The system tar lists the archive: the files and their folders'
        $extractTo = New-TempPath
        New-Item -ItemType Directory -Path $extractTo | Out-Null
        & $tarCommand.Source -xzf $archivePath -C $extractTo
        Check ($LASTEXITCODE -eq 0 -and (Get-Content -LiteralPath (Join-Path $extractTo 'overview.md') -Raw) -ceq "Hello`n" -and (Get-Content -LiteralPath (Join-Path $extractTo 'sub\deeper\c.md') -Raw) -ceq ('y' * 700)) 'The system tar unpacks it to the same files'
    }

    # --- Exporting files from the agent --------------------------------------------------------------------------------------------------------
    $out = New-TempPath
    $listed = Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" -List
    Check ($listed.exists -and $listed.files.Count -eq 3 -and $listed.written -eq 0 -and -not (Test-Path -LiteralPath $out)) '-List returns the files and writes nothing'
    $exported = Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" -OutputPath $out
    Check ($exported.written -eq 3 -and $exported.skipped -eq 0 -and (Get-Content -LiteralPath (Join-Path $out 'synthesizedKnowledge\overview.md') -Raw) -ceq "# Overview`n" -and (Test-Path -LiteralPath (Join-Path $out 'synthesizedKnowledge\deep\a\b.md')) -and (Test-Path -LiteralPath (Join-Path $out 'sessionInsights\s.md'))) 'Export keeps the folder layout and the exact text'
    $deckOut = New-TempPath
    $deckWarnings = Get-WarningText (@(Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/tmp/ThreadFiles/t1" -OutputPath $deckOut 3>&1))
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $deckOut 'deck.pptx'))) -ceq [Convert]::ToBase64String($binary) -and -not $deckWarnings) 'A deck file is saved byte for byte, with no warning when it starts like a zip'
    $textOut = New-TempPath
    Check ((Get-WarningText (@(Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/tmp/ThreadFiles/t2" -OutputPath $textOut 3>&1))) -match 'does not start like a PowerPoint') 'A .pptx that does not start like a zip is saved with a warning'
    $secondOutput = @(Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" -OutputPath $out 3>&1)
    $second = $secondOutput | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['written'] } | Select-Object -First 1
    Check ($second.written -eq 0 -and $second.skipped -eq 3 -and (Get-WarningText $secondOutput) -match 'Exists, not overwritten') 'An existing file is never overwritten'
    $missingFolder = Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/tmp/ThreadFiles/no-such-thread" -OutputPath (New-TempPath)
    Check (-not $missingFolder.exists -and $missingFolder.written -eq 0) 'A folder that is not there is reported as not there'
    Throws { Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" -OutputPath (Join-Path $root 'export-inside-repo') } 'outside the repository'
    Throws { Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" -OutputPath 'relative\export' } 'must be a full path'
    Throws { Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/memories" } 'Give an output folder'
    Check ((Resolve-SreExportPath -OutputPath "$out\") -ceq [IO.Path]::GetFullPath($out).TrimEnd('\', '/')) 'An export path is returned without a trailing separator'
    if ($IsWindows) {
        $agent.state.files["$workspaceRoot/tmp/ThreadFiles/t3/a\..\..\escape.md"] = [Text.Encoding]::UTF8.GetBytes('x')
        Throws { Export-SreAgentFolder -Context $context -Folder "$workspaceRoot/tmp/ThreadFiles/t3" -OutputPath (New-TempPath) } 'Refusing to write outside the output folder'
    }

    # --- The scripts ---------------------------------------------------------------------------------------------------------------------------
    foreach ($name in 'Invoke-ScheduledTask.ps1', 'Export-SreAgentFiles.ps1', 'Invoke-DriftDemo.ps1') {
        $text = Get-Content -LiteralPath (Join-Path $root "scripts\$name") -Raw
        Check ($text -match '(?m)^#Requires -Version 7\.4' -and $text -match '(?m)^\s*\[Parameter\(Mandatory = \$true\)\]\s*\r?\n\s*\[string\]\$SubscriptionId' -and $text -match '(?m)^\s*\[Parameter\(Mandatory = \$true\)\]\s*\r?\n\s*\[string\]\$TenantId') "$name needs the subscription and the tenant explicitly"
    }
    Check ((Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-ScheduledTask.ps1') -Raw) -match 'SupportsShouldProcess' -and (Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-DriftDemo.ps1') -Raw) -match 'SupportsShouldProcess') 'The scripts that change something support -WhatIf'
    $taskScript = Join-Path $root 'scripts\Invoke-ScheduledTask.ps1'
    $noProactive = New-ActsSkinFile -Scenarios @('ASK')
    Throws { & $taskScript -SubscriptionId $subscription -TenantId $tenant -SkinPath $noProactive -Action Status } 'does not turn on PROACTIVE'
    Throws { & $taskScript -SubscriptionId $subscription -TenantId $tenant -SkinPath $allPath -Action Run } 'Say which task with -Name'
    Throws { & $taskScript -SubscriptionId $subscription -TenantId $tenant -SkinPath $allPath -Action Enable -Name 'nope' } "Unknown task 'nope'"
    $exportScript = Join-Path $root 'scripts\Export-SreAgentFiles.ps1'
    Throws { & $exportScript -SubscriptionId $subscription -TenantId $tenant -Source Thread -OutputPath (New-TempPath) } 'Say which thread with -ThreadId'
    Throws { & $exportScript -SubscriptionId $subscription -TenantId $tenant -Source Notes } 'Give -OutputPath'
    Throws { & $exportScript -SubscriptionId $subscription -TenantId $tenant -Source Notes -OutputPath (Join-Path $root 'export-inside-repo') } 'outside the repository'
    Throws { & $exportScript -SubscriptionId $subscription -TenantId $tenant -Source Notes -OutputPath 'relative' } 'must be a full path'
    Throws { & $exportScript -SubscriptionId $subscription -TenantId $tenant -Source Thread -ThreadId '../x' -OutputPath (New-TempPath) } 'does not match|pattern'
    $hibernateText = Get-Content -LiteralPath (Join-Path $root 'scripts\Hibernate-SreAgent.ps1') -Raw
    Check ($hibernateText -match 'Export-SreAgentFiles\.ps1 -Source Notes' -and $hibernateText.IndexOf('Export-SreAgentFiles.ps1 -Source Notes', [StringComparison]::Ordinal) -lt $hibernateText.IndexOf('$PSCmdlet.ShouldProcess', [StringComparison]::Ordinal)) 'Hibernate says before it asks that deleting the agent deletes its notes, and how to export them'
} finally {
    foreach ($agent in $agents) { Stop-FakeAgent -Agent $agent }
    foreach ($path in $temps) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "$count ASK, MEMORY and PROACTIVE assertions passed. Only a loopback stand-in agent was used."
