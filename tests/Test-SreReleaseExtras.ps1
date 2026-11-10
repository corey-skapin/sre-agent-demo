#Requires -Version 7.4
# Offline checks for what the T12 scenario puts on the SRE agent besides its handler and plan: the GitHub tool policy and repository-only
# instruction, two skills, a Stop hook and the code repository. The pure comparison runs on plain data; the apply engine and the data-plane
# helpers run for real against a small stand-in agent on a loopback port (tests\TestHelpers.ps1). No Azure, no network beyond loopback.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreConfiguration.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreReleaseExtras.psm1') -Force
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$githubHost = 'github.com'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "T12 extras assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}

$previousResponder = $global:AzResponder
$agents = [Collections.Generic.List[object]]::new()
$files = [Collections.Generic.List[string]]::new()
function New-Agent {
    $agent = Start-FakeAgent
    $agents.Add($agent)
    $agent
}
function New-BackupBase {
    $base = Join-Path ([IO.Path]::GetTempPath()) "t12-backup-$([guid]::NewGuid())"
    $files.Add("$base.release-before.json"); $files.Add("$base.release-after.json")
    $base
}
try {
    $skinPath = New-TestT12SkinFile -Root $root
    $files.Add($skinPath)
    $desired = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath
    $release = $desired.release
    $hookName = $release.hook.name
    $repoName = $release.repository.name
    $skillNames = @($release.skills | ForEach-Object { $_.name })
    $beforeOperations = @('tool-policy', 'guard-instruction') + @($skillNames | ForEach-Object { "skill:$_" }) + @("hook:$hookName")

    # --- Pure comparison -------------------------------------------------------------------------------------------------------------
    function New-Observed {
        param([switch]$Applied, [string]$Eol = "`n", [switch]$SignedIn, [switch]$Repo)
        $live = { param($text) ([string]$text) -replace "`n", $Eol }
        $observed = @{ policy = @{ allow = @(); ask = @(); deny = @(); etag = $null }; instructions = ''; skills = @{}; hook = $null; domains = @(); repository = $null }
        if ($Applied) {
            $observed.policy = @{ allow = @($release.policy.allow); ask = @($release.policy.ask); deny = @($release.policy.deny); etag = $null }
            $observed.instructions = & $live (Get-SreReleaseGuardInstruction -Current '' -Guard $release.guard)
            foreach ($skill in $release.skills) {
                $observed.skills[$skill.name] = @{ name = $skill.name; type = 'Skill'; properties = @{ name = $skill.name; description = $skill.description; tools = @(); skillContent = (& $live $skill.content); additionalFiles = @() } }
            }
            $observed.hook = @{ name = $hookName; type = 'GlobalHook'; properties = @{
                eventType = $release.hook.eventType; activationMode = $release.hook.activationMode; description = $release.hook.description; enabled = $true
                hook = @{ type = 'prompt'; prompt = (& $live $release.hook.prompt); timeout = $release.hook.timeout; maxRejections = $release.hook.maxRejections } } }
        }
        if ($SignedIn) { $observed.domains = @(@{ name = 'github.com' }) }
        if ($Repo) { $observed.repository = @{ name = $repoName; type = 'CodeRepo'; properties = @{ url = $release.repository.url; branch = $release.repository.branch; type = 'GitHub'; latestCommit = 'abcdef0123456789' } } }
        $observed
    }
    $empty = Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed) -Stage Before
    Check ((@($empty.operations | ForEach-Object { $_.name }) -join ',') -ceq ($beforeOperations -join ',')) 'An empty agent needs the policy first, then the guard instruction, the skills and the hook'
    Check (@($empty.operations | Where-Object { $_.name -like 'repository:*' }).Count -eq 0) 'Stage Before never touches the repository'
    $blocked = Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -SignedIn) -Stage After
    Check ($blocked.operations.Count -eq 0 -and -not $blocked.guardInPlace -and $blocked.notes[0] -match '^Blocked') 'Signed in but no guard: the repository is blocked, not connected'
    $onlyPolicy = New-Observed -SignedIn
    $onlyPolicy.policy = @{ allow = @($release.policy.allow); ask = @($release.policy.ask); deny = @($release.policy.deny); etag = $null }
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed $onlyPolicy -Stage After).notes[0] -match '^Blocked') 'The policy alone is not enough: the repository-only instruction must be there too'
    $onlyGuard = New-Observed -Applied -SignedIn
    $onlyGuard.policy = @{ allow = @(); ask = @(); deny = @(); etag = $null }
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed $onlyGuard -Stage After).notes[0] -match '^Blocked') 'The instruction alone is not enough: the ask rules must be there too'
    $applied = Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -Applied) -Stage Before
    Check ($applied.operations.Count -eq 0 -and $applied.guardInPlace) 'A fully applied agent needs no writes'
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -Applied -Eol "`r`n") -Stage Before).operations.Count -eq 0) 'Text the service returns with CRLF is not drift'
    $noSignIn = Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -Applied) -Stage After
    Check ($noSignIn.operations.Count -eq 0 -and $noSignIn.notes[0] -match 'not signed in' -and $noSignIn.notes[0] -match 'once per agent build') 'Without a GitHub sign-in the plan says so and writes nothing'
    $connect = Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -Applied -SignedIn) -Stage After
    Check ($connect.operations.Count -eq 1 -and $connect.operations[0].name -ceq "repository:$repoName" -and $connect.operations[0].reason -ceq 'connect') 'Guard in place and signed in: one repository connection'
    Check ($connect.operations[0].body.type -ceq 'CodeRepo' -and $connect.operations[0].body.properties.url -ceq "https://$githubHost/example-owner/ticketing-app" -and $connect.operations[0].body.properties.type -ceq 'GitHub' -and $connect.operations[0].body.properties.branch -ceq 'main') 'The repository body names only the demo repository'
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed (New-Observed -Applied -SignedIn -Repo) -Stage After).operations.Count -eq 0) 'A connected repository needs no write'
    $moved = New-Observed -Applied -SignedIn -Repo
    $moved.repository.properties.branch = 'other'
    $update = Get-SreReleaseExtrasPlan -Desired $desired -Observed $moved -Stage After
    Check ($update.operations.Count -eq 1 -and $update.operations[0].reason -ceq 'update') 'A repository on the wrong branch is updated'
    $changed = New-Observed -Applied
    $changed.skills[$skillNames[0]].properties.skillContent += ' edited'
    $skillPlan = Get-SreReleaseExtrasPlan -Desired $desired -Observed $changed -Stage Before
    Check ($skillPlan.operations.Count -eq 1 -and $skillPlan.operations[0].name -ceq "skill:$($skillNames[0])" -and $skillPlan.operations[0].reason -ceq 'update') 'An edited skill is updated and nothing else'
    $withTools = New-Observed -Applied
    $withTools.skills[$skillNames[1]].properties.tools = @('SomeTool')
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed $withTools -Stage Before).operations[0].name -ceq "skill:$($skillNames[1])") 'A skill that lists tools is rewritten: skills here carry instructions only'
    $nullTools = New-Observed -Applied
    $nullTools.skills[$skillNames[0]].properties.tools = $null
    $noToolsKey = New-Observed -Applied
    $null = $noToolsKey.skills[$skillNames[1]].properties.Remove('tools')
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed $nullTools -Stage Before).operations.Count -eq 0 -and (Get-SreReleaseExtrasPlan -Desired $desired -Observed $noToolsKey -Stage Before).operations.Count -eq 0) 'A skill the service returns with tools null or left out has no tools: that is not drift, so the apply converges'
    $unread = New-Observed -Applied
    $unread.domainsStatus = 500
    $readable = New-Observed -Applied
    $readable.domainsStatus = 200
    Check ((Get-SreReleaseExtrasPlan -Desired $desired -Observed $unread -Stage After).notes[0] -match 'not signed in.*returned HTTP 500' -and (Get-SreReleaseExtrasPlan -Desired $desired -Observed $readable -Stage After).notes[0] -notmatch 'HTTP') 'A sign-in state that could not be read is called that, not just "not signed in"'
    $disabled = New-Observed -Applied
    $disabled.hook.properties.enabled = $false
    $hookPlan = Get-SreReleaseExtrasPlan -Desired $desired -Observed $disabled -Stage Before
    Check ($hookPlan.operations.Count -eq 1 -and $hookPlan.operations[0].name -ceq "hook:$hookName" -and $hookPlan.operations[0].body.properties.enabled -eq $true -and $hookPlan.operations[0].body.type -ceq 'GlobalHook') 'A disabled hook is enabled again'
    $partial = New-Observed -Applied
    $partial.policy = @{ allow = @('MyAllow') + @($release.policy.allow[0]); ask = @('MyAsk'); deny = @('MyDeny'); etag = '"e1"' }
    $policyPlan = Get-SreReleaseExtrasPlan -Desired $desired -Observed $partial -Stage Before
    $merged = $policyPlan.operations[0].body.permissions
    Check ($policyPlan.operations[0].name -ceq 'tool-policy' -and 'MyAllow' -in $merged.allow -and 'MyAsk' -in $merged.ask -and 'MyDeny' -in $merged.deny) 'The policy write keeps every rule that was already there'
    Check (@($release.policy.ask | Where-Object { $_ -notin $merged.ask }).Count -eq 0 -and @($release.policy.allow | Where-Object { $_ -notin $merged.allow }).Count -eq 0 -and @($release.policy.deny | Where-Object { $_ -notin $merged.deny }).Count -eq 0) 'The policy write adds every rule this scenario needs'
    Check (@($merged.allow | Group-Object | Where-Object Count -GT 1).Count -eq 0) 'The merged policy has no duplicates'
    $nullPolicy = New-Observed
    $nullPolicy.policy = @{ allow = $null; ask = $null; deny = $null; etag = $null }
    $nullMerged = (Get-SreReleaseExtrasPlan -Desired $desired -Observed $nullPolicy -Stage Before).operations[0].body.permissions
    Check (@($nullMerged.allow + $nullMerged.ask + $nullMerged.deny | Where-Object { $null -eq $_ }).Count -eq 0 -and @($nullMerged.ask).Count -eq @($release.policy.ask).Count) 'A policy the agent returns as null lists is treated as empty, never written back with null entries'

    # --- The guard paragraph ----------------------------------------------------------------------------------------------------------
    $guard = $release.guard
    Check ((Get-SreReleaseGuardInstruction -Current '' -Guard $guard) -ceq $guard.text -and (Get-SreReleaseGuardInstruction -Current $null -Guard $guard) -ceq $guard.text) 'An agent with no instructions gets just the guard paragraph'
    Check ((Get-SreReleaseGuardInstruction -Current 'Be brief.' -Guard $guard) -ceq "Be brief.`n`n$($guard.text)") 'Existing instructions are kept and the guard paragraph follows a blank line'
    $once = Get-SreReleaseGuardInstruction -Current 'Be brief.' -Guard $guard
    Check ((Get-SreReleaseGuardInstruction -Current $once -Guard $guard) -ceq $once -and (Get-SreReleaseGuardInstruction -Current ($once -replace "`n", "`r`n") -Guard $guard) -ceq $once) 'Applying it again changes nothing, whatever the line endings'
    $stale = "Be brief.`n`n$($guard.marker) an older repository-only paragraph`nover two lines.`n`nTail paragraph."
    $fresh = Get-SreReleaseGuardInstruction -Current $stale -Guard $guard
    Check ($fresh -ceq "Be brief.`n`n$($guard.text)`n`nTail paragraph." -and ([regex]::Matches($fresh, [regex]::Escape($guard.marker))).Count -eq 1) 'An older guard paragraph is replaced in place and the text around it is kept'

    # --- Apply: stage Before on an empty agent ----------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $base = New-BackupBase
    $preview = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath $base -WhatIf 6>$null
    Check (-not $preview.changed -and $preview.preview.operations.Count -eq 5) 'WhatIf previews the five writes'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0 -and -not (Test-Path "$base.release-before.json")) 'WhatIf writes nothing, not even a backup'
    $result = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath $base 6>$null
    Check ($result.changed -and $result.verified -and ((@($result.operations) -join ',') -ceq ($beforeOperations -join ','))) 'Stage Before applies the five writes and verifies them by reading back'
    $expectedWrites = @('PUT /api/v2/agent/settings/global', 'PUT /api/v2/agent/customInstructions') + @($skillNames | ForEach-Object { "PUT /api/v2/extendedAgent/skills/$_" }) + @("PUT /api/v2/extendedAgent/hooks/$hookName")
    Check (((Get-FakeAgentWrites -Agent $agent) -join '|') -ceq ($expectedWrites -join '|')) 'The ask policy and the repository-only instruction are written before the skills and the hook, one PUT each'
    Check (-not (@(Get-FakeAgentWrites -Agent $agent) -match '/repos/')) 'Stage Before never writes the repository'
    $policyPut = @($agent.state.log | Where-Object { $_.method -eq 'PUT' -and $_.path -eq '/api/v2/agent/settings/global' })
    Check ($policyPut.Count -eq 1 -and $policyPut[0].ifMatch -ceq '*') 'With no ETag the policy PUT sends If-Match: *'
    Check (@($agent.state.log | Where-Object { $_.authorization -cne 'Bearer test-token' }).Count -eq 0) 'Every request carried the bearer token and nothing else'
    $sent = $policyPut[0].body.permissions
    Check (@($sent.allow).Count -eq @($release.policy.allow).Count -and @($sent.ask).Count -eq @($release.policy.ask).Count -and @($sent.deny).Count -eq @($release.policy.deny).Count -and @($sent.allow + $sent.ask + $sent.deny | Where-Object { $null -eq $_ }).Count -eq 0) 'The first policy write holds exactly the scenario rules, with no null entries'
    Check ('*Github*' -in $agent.state.policy.ask -and 'bash(gh *)' -in $agent.state.policy.ask -and 'FetchGithubIssue' -in $agent.state.policy.allow -and 'CreateGithubIssue' -notin $agent.state.policy.allow) 'GitHub reads are allowed, GitHub writes ask'
    Check ($agent.state.instructions.StartsWith($release.guard.marker) -and $agent.state.instructions.Contains('example-owner/ticketing-app')) 'The repository-only instruction is on the agent'
    Check ($agent.state.skills.Keys.Count -eq 2 -and $agent.state.skills[$skillNames[0]].properties.skillContent -ceq $release.skills[0].content -and @($agent.state.skills[$skillNames[0]].properties.tools).Count -eq 0) 'Both skills are on the agent with their text and no tool list'
    Check ($agent.state.hooks[$hookName].properties.eventType -ceq 'Stop' -and $agent.state.hooks[$hookName].properties.hook.type -ceq 'prompt' -and $agent.state.hooks[$hookName].properties.enabled -eq $true) 'The Stop hook is on the agent and enabled'
    $backup = Get-Content -LiteralPath "$base.release-before.json" -Raw | ConvertFrom-Json
    Check (@($backup.policy.ask).Count -eq 0 -and $backup.instructions -eq '' -and $result.backupPath -ceq [IO.Path]::GetFullPath("$base.release-before.json")) 'The backup holds what was there before, outside the repository'
    $mark = $agent.state.log.Count
    $again = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check (-not $again.changed -and $again.verified -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0) 'Running stage Before again writes nothing'
    $readiness = @(Get-SreReleaseDataChecks -Context $context -Desired $desired)
    Check (@($readiness | Where-Object { $_.required -and $_.status -ne 'pass' }).Count -eq 0 -and @($readiness | Where-Object { $_.id -eq 'T12-github-signin' -and $_.status -eq 'pending' -and -not $_.required }).Count -eq 1 -and @($readiness | Where-Object { $_.id -eq 'T12-repository' -and $_.status -eq 'pending' }).Count -eq 1) 'Readiness: guard, skills and hook pass; sign-in and repository are pending and optional'

    # --- Apply: stage After -----------------------------------------------------------------------------------------------------------
    $mark = $agent.state.log.Count
    $waiting = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) 6>$null
    Check (-not $waiting.changed -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0 -and @($agent.state.log | Select-Object -Skip $mark | Where-Object { $_.path -like '*oauth*' }).Count -eq 0) 'Without -GitHubSignIn the repository stage fetches no sign-in link and writes nothing'
    $mark = $agent.state.log.Count
    $output = @(Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) -GitHubSignIn 6>&1)
    $result = $output | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
    $text = (@($output | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n")
    Check ($result.changed -and $result.verified -and $result.latestCommit -ceq 'abcdef0' -and $result.connectivity -ceq 'HTTP 200') 'With -GitHubSignIn the repository is connected, cloned and tested'
    Check (((Get-FakeAgentWrites -Agent $agent -Since $mark) -join '|') -ceq "PUT /api/v2/repos/$repoName|POST /api/v2/repos/$repoName/test") 'One repository PUT, then one connectivity test'
    Check (@($agent.state.log | Select-Object -Skip $mark | Where-Object { $_.path -eq '/api/v2/github/oauth/config' }).Count -eq 1) 'The sign-in link was requested once'
    Check ($text -match 'https://github\.com/login/oauth/authorize' -and $text -match 'repo scope' -and $text -match 'every repository' -and $text -match 'once per agent build') 'The sign-in text shows the link and says the grant reaches every repository'
    Check ($agent.state.repos[$repoName].properties.url -ceq "https://$githubHost/example-owner/ticketing-app" -and $agent.state.repos[$repoName].properties.branch -ceq 'main') 'The agent holds the demo repository only'
    $readiness = @(Get-SreReleaseDataChecks -Context $context -Desired $desired)
    Check (@($readiness | Where-Object { $_.status -ne 'pass' }).Count -eq 0) 'Readiness: everything passes once the repository is cloned'
    $mark = $agent.state.log.Count
    $second = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) -GitHubSignIn 6>$null
    Check (-not $second.changed -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0 -and @($agent.state.log | Select-Object -Skip $mark | Where-Object { $_.path -like '*oauth*' }).Count -eq 0) 'Signed in and connected already: a second apply writes nothing and asks for no second sign-in'

    # --- The guard order: no repository without the guard -----------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.domains = @(@{ name = 'github.com' })
    $held = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) 6>$null
    Check (-not $held.changed -and $held.notes[0] -match '^Blocked' -and @(Get-FakeAgentWrites -Agent $agent).Count -eq 0) 'Signed in but no guard: stage After refuses to connect the repository'
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) -GitHubSignIn 6>$null } '^Blocked'
    $agent.state.domains = @()
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) -GitHubSignIn 6>$null } '^Blocked'
    Check (@($agent.state.log | Where-Object { $_.path -like '*oauth*' }).Count -eq 0 -and @(Get-FakeAgentWrites -Agent $agent).Count -eq 0) 'Without the guard the sign-in link is not even requested'
    $readiness = @(Get-SreReleaseDataChecks -Context $context -Desired $desired)
    Check (@($readiness | Where-Object { $_.required -and $_.status -eq 'fail' }).Count -eq 3 -and @($readiness | Where-Object { $_.id -eq 'T12-github-guard' -and $_.status -eq 'fail' }).Count -eq 1) 'Readiness on an empty agent fails the three required rows'
    $preview = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath (New-BackupBase) -GitHubSignIn -WhatIf 6>$null
    Check (-not $preview.changed -and $preview.notes[0] -match '^Blocked' -and @(Get-FakeAgentWrites -Agent $agent).Count -eq 0 -and @($agent.state.log | Where-Object { $_.path -like '*oauth*' }).Count -eq 0) 'A preview with -GitHubSignIn on an agent that has no guard yet says the guard comes first, instead of failing'

    # --- A service that drops an empty tool list, and a sign-in read that fails -------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.omitSkillTools = $true
    $dropped = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) -ReadBackSeconds 5 6>$null
    Check ($dropped.changed -and $dropped.verified) 'Stage Before verifies even when the service returns skills without a tools list'
    $mark = $agent.state.log.Count
    $droppedAgain = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check (-not $droppedAgain.changed -and @(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0) 'A second apply against that service writes nothing'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.domainsStatus = 500
    $observedNow = Get-SreReleaseObserved -Context $context -Desired $desired
    Check (@($observedNow.domains).Count -eq 0 -and $observedNow.domainsStatus -eq 500) 'A sign-in read that fails is no sign-in, not an error'
    $guardOnly = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check ($guardOnly.changed -and $guardOnly.verified -and @($guardOnly.operations).Count -eq 5) 'The guard, skills and hook are still applied when the sign-in state cannot be read'

    # --- Failures never replay a write ------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.ignoreWrites = $true
    $slow = $null
    try { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) -ReadBackSeconds 2 6>$null } catch { $slow = $_.Exception.Message }
    Check ($slow -match 'Read-back does not show' -and $slow -match 'Nothing was replayed' -and $slow -match 'after 2 s') 'A write the read-back never shows is reported, not repeated'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 5) 'Exactly one PUT per operation, none replayed'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.failPut = "skills/$($skillNames[0])$"
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null } "Apply skill:$($skillNames[0]) failed: HTTP 400"
    Check (((Get-FakeAgentWrites -Agent $agent) -join '|') -ceq ((@('PUT /api/v2/agent/settings/global', 'PUT /api/v2/agent/customInstructions', "PUT /api/v2/extendedAgent/skills/$($skillNames[0])")) -join '|')) 'A rejected write stops the stage: it is not retried and nothing after it is attempted'
    $agent.state.failPut = $null
    $retry = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check ($retry.changed -and $retry.verified -and @($retry.operations).Count -eq 3) 'A later apply converges and writes only what is still missing'

    # --- Backups ----------------------------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (Join-Path $root 'backup-inside-repo') 6>$null } 'outside the repository'
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (Join-Path ([IO.Path]::GetTempPath()) "missing-$([guid]::NewGuid())\backup") 6>$null } 'parent directory must already exist'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0) 'A bad backup path stops the apply before the first write'
    $base = New-BackupBase
    [IO.File]::WriteAllText("$base.release-before.json", '{}')
    Throws { Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath $base 6>$null } 'already exists'
    Check (@(Get-FakeAgentWrites -Agent $agent).Count -eq 0 -and (Get-Content -LiteralPath "$base.release-before.json" -Raw) -eq '{}') 'An existing backup is never overwritten, and nothing is written without one'

    # --- Existing settings survive ----------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.policy = @{ allow = @('MyAllow'); ask = @('MyAsk'); deny = @('MyDeny') }
    $agent.state.instructions = 'Be brief.'
    $agent.state.etag = 'v1'
    $null = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check ('MyAllow' -in $agent.state.policy.allow -and 'MyAsk' -in $agent.state.policy.ask -and 'MyDeny' -in $agent.state.policy.deny -and '*Github*' -in $agent.state.policy.ask) 'Existing policy rules stay and the scenario rules are added'
    Check ($agent.state.instructions -ceq "Be brief.`n`n$($release.guard.text)") 'Existing instructions stay and the guard paragraph is added after them'
    $policyPut = @($agent.state.log | Where-Object { $_.method -eq 'PUT' -and $_.path -eq '/api/v2/agent/settings/global' })
    Check ($policyPut.Count -eq 1 -and $policyPut[0].ifMatch -ceq '"v1"') 'The policy PUT carries the ETag it read'
    $agent.state.instructions = "Be brief.`n`n$($release.guard.marker) an older paragraph.`n`nTail paragraph."
    $null = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    Check ($agent.state.instructions -ceq "Be brief.`n`n$($release.guard.text)`n`nTail paragraph.") 'A refreshed guard paragraph keeps the instructions around it'
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    $agent.state.etag = 'v1'
    $agent.state.rejectEtagOnce = $true
    $null = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath (New-BackupBase) 6>$null
    $policyPuts = @($agent.state.log | Where-Object { $_.method -eq 'PUT' -and $_.path -eq '/api/v2/agent/settings/global' })
    Check ($policyPuts.Count -eq 2 -and $policyPuts[0].ifMatch -ceq '"v1"' -and $policyPuts[1].ifMatch -ceq '*' -and '*Github*' -in $agent.state.policy.ask) 'A refused ETag is retried once with If-Match: *, the only retry in the engine'

    # --- The data-plane helpers -------------------------------------------------------------------------------------------------------
    $agent = New-Agent
    $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
    Check ($null -eq (Get-SreProperty $null 'x') -and (Get-SreProperty @{ a = 1 } 'a') -eq 1 -and $null -eq (Get-SreProperty @{ a = 1 } 'b') -and (Get-SreProperty ([pscustomobject]@{ a = 2 }) 'a') -eq 2 -and $null -eq (Get-SreProperty ([pscustomobject]@{ a = 2 }) 'b')) 'Get-SreProperty is safe on null, dictionaries and objects'
    $missing = Invoke-SreData -Context $context -Method GET -Path '/api/v2/nothing/here'
    Check ($missing.Status -eq 404 -and $missing.Ms -ge 0) 'A 404 is returned, not thrown'
    Throws { Assert-SreDataSuccess -Response $missing -What 'Read the nothing' } 'Read the nothing failed: HTTP 404'
    Throws { Invoke-SreData -Context $context -Method GET -Path '/etc/passwd' } 'pattern|does not match|Cannot validate'
    Throws { Invoke-SreData -Context $context -Method PATCH -Path '/api/v2/agent/settings/global' } 'ValidateSet|does not belong'
    $agent.state.threads = @(@{ id = 'thread-1'; title = 'Sev2 ticketing-checkout-failures'; createdTimestamp = '2026-11-12T01:00:00Z' }, @{ id = 'thread-2'; title = 'other'; createdTimestamp = '2026-11-12T00:00:00Z' })
    $agent.state.messages['thread-1'] = @(
        @{ author = @{ role = 'SREAgent' }; timeStamp = '2026-11-12T01:00:05Z'; text = 'Investigating' },
        @{ azCliExecution = @{ id = 'card-1'; status = 'Pending'; description = 'Redeploy the last good release'; createdTimestamp = '2026-11-12T01:02:00Z'; originalFunctionCall = @{ command = 'az webapp config appsettings set' } } },
        @{ azCliExecution = @{ id = 'card-0'; status = 'Completed'; description = 'Earlier write' } },
        @{ approval = @{ id = 'approval-1'; status = 'Pending'; createdTimestamp = '2026-11-12T01:03:00Z'; title = 'CreateGithubIssue'; command = 'create issue' } },
        @{ approval = @{ id = 'approval-0'; status = 'Approved' } }
    )
    $threads = @(Get-SreThreads -Context $context -Top 5)
    Check ($threads.Count -eq 2 -and $threads[0].id -ceq 'thread-1') 'Threads are listed'
    $thread = Get-SreThreadMessages -Context $context -ThreadId 'thread-1'
    Check ($thread.State -ceq 'Running' -and $thread.Messages.Count -eq 5) 'Thread messages are read with their state'
    Throws { Get-SreThreadMessages -Context $context -ThreadId 'thread-1/../x' } 'pattern|does not match|Cannot validate'
    $cards = @(Get-SrePendingCards -Messages $thread.Messages)
    Check ($cards.Count -eq 2 -and $cards[0].kind -ceq 'azure-write' -and $cards[0].id -ceq 'card-1' -and $cards[1].kind -ceq 'permission-rule' -and $cards[1].id -ceq 'approval-1') 'Only the cards waiting for a person are listed: one Azure write and one permission rule'
    Check (@(Get-SrePendingCards -Messages @()).Count -eq 0 -and @(Get-SrePendingCards -Messages $null).Count -eq 0) 'No messages, no cards'
    $mark = $agent.state.log.Count
    Remove-SreThread -Context $context -ThreadId 'thread-2' -WhatIf 6>$null | Out-Null
    Check (@(Get-FakeAgentWrites -Agent $agent -Since $mark).Count -eq 0 -and @($agent.state.threads).Count -eq 2) 'Deleting a thread previews under WhatIf'
    Remove-SreThread -Context $context -ThreadId 'thread-2' | Out-Null
    Check (@($agent.state.threads).Count -eq 1 -and $agent.state.threads[0].id -ceq 'thread-1' -and (Get-FakeAgentWrites -Agent $agent -Since $mark) -contains 'DELETE /api/v1/threads/thread-2') 'Deleting a thread removes only that thread'
    $global:AzCalls.Clear()
    $global:AzResponder = { 'refreshed-token' }
    $context.tokenAtUtc = [DateTime]::UtcNow.AddMinutes(-31)
    $mark = $agent.state.log.Count
    $null = Invoke-SreData -Context $context -Method GET -Path '/api/v2/github/domains'
    Check ($context.token -ceq 'refreshed-token' -and $global:AzCalls.Count -eq 1 -and $global:AzCalls[0] -like 'account get-access-token --resource https://azuresre.dev --query accessToken -o tsv --subscription *') 'A token older than 30 minutes is refreshed for the SRE audience, with the explicit subscription'
    Check (@($agent.state.log | Select-Object -Skip $mark)[0].authorization -ceq 'Bearer refreshed-token') 'The refreshed token is the one that is sent'
} finally {
    foreach ($agent in $agents) { Stop-FakeAgent -Agent $agent }
    foreach ($path in $files) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $global:AzResponder = $previousResponder
}
Write-Host "$count T12 extras and data-plane assertions passed. Only a loopback stand-in agent was used."
