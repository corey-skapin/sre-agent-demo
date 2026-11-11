Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreConfiguration.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreDataPlane.psm1')

# What the T12 scenario puts on the SRE agent besides its handler and response plan (those go through SreConfiguration.psm1):
# the GitHub tool policy and repository-only instruction, two skills, a Stop hook, and the one code repository.
# Stage Before runs first (guard, skills, hook); stage After connects the repository, and only when the guard is in place and a GitHub sign-in exists.
# Writes are idempotent: a stage reads first, changes only what differs, backs up what it read, and verifies by reading again. It never deletes.

function ConvertTo-SreLf {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "`r`n", "`n")
}

function ConvertTo-SreHashtable {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)
}

function Read-SreItem {
    # 200 returns the response, 404 or an empty body returns $null, anything else throws.
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$What)
    $response = Invoke-SreData -Context $Context -Method GET -Path $Path
    if ($response.Status -eq 404) { return $null }
    Assert-SreDataSuccess -Response $response -What $What
    if ($null -eq $response.Body -or ($response.Body -is [string] -and [string]::IsNullOrWhiteSpace($response.Body))) { return $null }
    return $response
}

function Get-SreReleaseObserved {
    <#
    .SYNOPSIS
    Reads the current T12-related state from the agent. Read-only.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired)
    $release = $Desired.release
    $policyResponse = Invoke-SreData -Context $Context -Method GET -Path '/api/v2/agent/settings/global'
    Assert-SreDataSuccess -Response $policyResponse -What 'Read the tool policy'
    $permissions = ConvertTo-SreHashtable (Get-SreProperty $policyResponse.Body 'permissions')
    # @(if ...) keeps an empty rule list an empty array instead of $null, so no null ever reaches a policy write.
    $rules = @{}
    foreach ($kind in 'allow', 'ask', 'deny') { $rules[$kind] = @(if ($permissions -and $permissions[$kind]) { $permissions[$kind] | Where-Object { $null -ne $_ } }) }
    $etag = if ($policyResponse.Headers -and $policyResponse.Headers.ContainsKey('ETag')) { [string]@($policyResponse.Headers['ETag'])[0] } else { $null }
    $instructionsResponse = Invoke-SreData -Context $Context -Method GET -Path '/api/v2/agent/customInstructions'
    Assert-SreDataSuccess -Response $instructionsResponse -What 'Read the custom instructions'
    $skills = @{}
    foreach ($skill in $release.skills) {
        $item = Read-SreItem -Context $Context -Path "/api/v2/extendedAgent/skills/$([uri]::EscapeDataString($skill.name))" -What "Read skill $($skill.name)"
        $skills[$skill.name] = if ($item) { ConvertTo-SreHashtable $item.Body } else { $null }
    }
    $hookItem = Read-SreItem -Context $Context -Path "/api/v2/extendedAgent/hooks/$([uri]::EscapeDataString($release.hook.name))" -What "Read hook $($release.hook.name)"
    $domainResponse = Invoke-SreData -Context $Context -Method GET -Path '/api/v2/github/domains'
    # A failed read means no sign-in is known. That only holds the repository back; it must not stop the guard from being applied.
    $domains = if ($domainResponse.Status -ge 200 -and $domainResponse.Status -lt 300) { @(Get-SreProperty $domainResponse.Body 'values' | Where-Object { $null -ne $_ }) } else { @() }
    $repoItem = Read-SreItem -Context $Context -Path "/api/v2/repos/$([uri]::EscapeDataString($release.repository.name))" -What "Read repository $($release.repository.name)"
    [ordered]@{
        policy = @{ allow = $rules.allow; ask = $rules.ask; deny = $rules.deny; etag = $etag; body = (ConvertTo-SreHashtable $policyResponse.Body) }
        instructions = [string](Get-SreProperty $instructionsResponse.Body 'instructions')
        skills = $skills
        hook = if ($hookItem) { ConvertTo-SreHashtable $hookItem.Body } else { $null }
        domains = $domains
        domainsStatus = [int]$domainResponse.Status
        repository = if ($repoItem) { ConvertTo-SreHashtable $repoItem.Body } else { $null }
    }
}

function Get-SreReleaseGuardInstruction {
    # The instruction text after the guard paragraph is added or refreshed; unchanged when it is already exact.
    param([AllowNull()][string]$Current, [Parameter(Mandatory)][Collections.IDictionary]$Guard)
    $text = ConvertTo-SreLf $Current
    $block = [regex]::Match($text, '(?ms)^' + [regex]::Escape($Guard.marker) + '.*?(?=\n\n|\z)')
    if ($block.Success) { return $text.Substring(0, $block.Index) + $Guard.text + $text.Substring($block.Index + $block.Length) }
    if ($text.Trim()) { return $text.TrimEnd() + "`n`n" + $Guard.text }
    return $Guard.text
}

function Get-SreReleaseExtrasPlan {
    <#
    .SYNOPSIS
    Compares the desired T12 extras with what the agent holds and lists the writes a stage would make. Read-only.
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Desired, [Parameter(Mandatory)][Collections.IDictionary]$Observed,
        [Parameter(Mandatory)][ValidateSet('Before', 'After')][string]$Stage
    )
    $release = $Desired.release
    $operations = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $policyMissing = 0
    $merged = @{}
    foreach ($kind in 'allow', 'ask', 'deny') {
        $current = @($Observed.policy[$kind] | Where-Object { $null -ne $_ })
        $missing = @($release.policy[$kind] | Where-Object { $_ -and $_ -notin $current })
        $policyMissing += $missing.Count
        $merged[$kind] = @($current + $missing)
    }
    $guardText = Get-SreReleaseGuardInstruction -Current $Observed.instructions -Guard $release.guard
    $guardInPlace = $policyMissing -eq 0 -and $guardText -ceq (ConvertTo-SreLf $Observed.instructions)
    if ($Stage -eq 'Before') {
        if ($policyMissing) {
            $operations.Add(@{ name = 'tool-policy'; reason = "add $policyMissing GitHub rule(s); nothing is removed"; method = 'Put'; path = '/api/v2/agent/settings/global'
                body = @{ permissions = $merged }; before = $Observed.policy })
        }
        if ($guardText -cne (ConvertTo-SreLf $Observed.instructions)) {
            $operations.Add(@{ name = 'guard-instruction'; reason = 'add or refresh the repository-only paragraph'; method = 'Put'; path = '/api/v2/agent/customInstructions'
                body = @{ instructions = $guardText }; before = @{ instructions = $Observed.instructions } })
        }
        foreach ($skill in $release.skills) {
            $found = $Observed.skills[$skill.name]
            $properties = if ($found -and $found['properties']) { $found['properties'] } else { @{} }
            $same = $found -and [string]$properties['description'] -ceq $skill.description -and (ConvertTo-SreLf $properties['skillContent']) -ceq $skill.content -and @($properties['tools'] | Where-Object { $null -ne $_ }).Count -eq 0
            if (-not $same) {
                $operations.Add(@{ name = "skill:$($skill.name)"; reason = $(if ($found) { 'update' } else { 'create' }); method = 'Put'; path = "/api/v2/extendedAgent/skills/$([uri]::EscapeDataString($skill.name))"
                    body = @{ name = $skill.name; type = 'Skill'; tags = @(); properties = @{ name = $skill.name; description = $skill.description; tools = @(); skillContent = $skill.content; additionalFiles = @() } }
                    before = $found })
            }
        }
        $hook = $release.hook
        $hookProperties = if ($Observed.hook -and $Observed.hook['properties']) { $Observed.hook['properties'] } else { @{} }
        $hookBody = if ($hookProperties['hook']) { $hookProperties['hook'] } else { @{} }
        # A live agent stores the hook but never returns properties.enabled, so only an explicit false counts as drift.
        $hookSame = $Observed.hook -and [string]$hookProperties['eventType'] -ceq $hook.eventType -and [string]$hookProperties['activationMode'] -ceq $hook.activationMode -and
            [string]$hookProperties['description'] -ceq $hook.description -and ($null -eq $hookProperties['enabled'] -or $hookProperties['enabled'] -eq $true) -and [string]$hookBody['type'] -ceq 'prompt' -and
            (ConvertTo-SreLf $hookBody['prompt']) -ceq $hook.prompt -and $hookBody['timeout'] -eq $hook.timeout -and $hookBody['maxRejections'] -eq $hook.maxRejections
        if (-not $hookSame) {
            $operations.Add(@{ name = "hook:$($hook.name)"; reason = $(if ($Observed.hook) { 'update' } else { 'create' }); method = 'Put'; path = "/api/v2/extendedAgent/hooks/$([uri]::EscapeDataString($hook.name))"
                body = @{ name = $hook.name; type = 'GlobalHook'; tags = @(); properties = @{
                    eventType = $hook.eventType; activationMode = $hook.activationMode; description = $hook.description; enabled = $true
                    hook = @{ type = 'prompt'; prompt = $hook.prompt; timeout = $hook.timeout; maxRejections = $hook.maxRejections } } }
                before = $Observed.hook })
        }
    } else {
        $repository = $release.repository
        $found = $Observed.repository
        $properties = if ($found -and $found['properties']) { $found['properties'] } else { @{} }
        if (-not $guardInPlace) {
            $notes.Add('Blocked: the GitHub tool policy and the repository-only instruction are not both in place. Run stage Before first; the repository is never connected without them.')
        } elseif (@($Observed.domains).Count -eq 0) {
            $unread = if ($Observed.Contains('domainsStatus') -and ($Observed['domainsStatus'] -lt 200 -or $Observed['domainsStatus'] -ge 300)) { " Reading the sign-in state returned HTTP $($Observed['domainsStatus'])." } else { '' }
            $notes.Add("GitHub is not signed in. That is the one step a person does (once per agent build): run Initialize-SreConfiguration.ps1 -Apply -GitHubSignIn and follow the link.$unread")
        } elseif (-not ($found -and [string]$properties['url'] -ceq $repository.url -and [string]$properties['branch'] -ceq $repository.branch)) {
            $operations.Add(@{ name = "repository:$($repository.name)"; reason = $(if ($found) { 'update' } else { 'connect' }); method = 'Put'; path = "/api/v2/repos/$([uri]::EscapeDataString($repository.name))"
                body = @{ name = $repository.name; type = 'CodeRepo'; properties = @{ url = $repository.url; type = 'GitHub'; branch = $repository.branch; description = $repository.description } }
                before = $found })
        }
    }
    @{ stage = $Stage; operations = @($operations.ToArray()); notes = @($notes.ToArray()); guardInPlace = $guardInPlace }
}

function Wait-SreGitHubSignIn {
    <#
    .SYNOPSIS
    Prints the one-time GitHub sign-in link and waits for the agent to list a signed-in domain. The only step here a person does.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [ValidateRange(30, 1800)][int]$TimeoutSeconds = 300)
    $config = Invoke-SreData -Context $Context -Method GET -Path '/api/v2/github/oauth/config'
    Assert-SreDataSuccess -Response $config -What 'Read the GitHub sign-in link'
    $url = [string](Get-SreProperty $config.Body 'oAuthUrl')
    if (-not $url) { $url = [string](Get-SreProperty $config.Body 'OAuthUrl') }
    if ($url -notmatch '^https://github\.com/') { throw 'The agent returned no GitHub sign-in link. Use the portal fallback in docs/t12-friday-release.md.' }
    Write-Host ''
    Write-Host 'GitHub sign-in (once per agent build):'
    Write-Host '  1. Open this link in a browser where you are signed in to the GitHub account that owns the demo repository:'
    Write-Host "     $url"
    Write-Host '  2. Approve the SRE Agent app. It asks for the repo scope, so the grant reaches every repository that account can reach.'
    Write-Host '     The ask policy and the repository-only instruction are already in place, and every GitHub write still waits for a person.'
    Write-Host "Waiting up to $TimeoutSeconds s for the sign-in to appear..."
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $domains = Invoke-SreData -Context $Context -Method GET -Path '/api/v2/github/domains'
        if ($domains.Status -eq 200 -and @(Get-SreProperty $domains.Body 'values' | Where-Object { $null -ne $_ }).Count -gt 0) { Write-Host 'GitHub sign-in is in place.'; return $true }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    Write-Warning 'No GitHub sign-in appeared in time. Run the apply again with -GitHubSignIn when you are ready.'
    return $false
}

function Invoke-SreReleaseExtras {
    <#
    .SYNOPSIS
    Applies one stage of the T12 extras. Stage Before: GitHub tool policy, repository-only instruction, skills, Stop hook. Stage After: the code repository.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired,
        [Parameter(Mandatory)][ValidateSet('Before', 'After')][string]$Stage, [Parameter(Mandatory)][string]$BackupPath,
        [switch]$GitHubSignIn, [ValidateRange(30, 1800)][int]$SignInTimeoutSeconds = 300, [ValidateRange(1, 600)][int]$ReadBackSeconds = 90
    )
    if ($Stage -eq 'After' -and $GitHubSignIn) {
        $guardCheck = Get-SreReleaseExtrasPlan -Desired $Desired -Observed (Get-SreReleaseObserved -Context $Context -Desired $Desired) -Stage After
        if (-not $guardCheck.guardInPlace) {
            # A preview never applied stage Before, so on a fresh agent it reports what is held back instead of failing.
            if ($WhatIfPreference) {
                foreach ($note in $guardCheck.notes) { Write-Host $note }
                return @{ changed = $false; verified = $false; stage = $Stage; preview = $guardCheck; notes = $guardCheck.notes }
            }
            throw $guardCheck.notes[0]
        }
        if (@((Get-SreReleaseObserved -Context $Context -Desired $Desired).domains).Count -eq 0) {
            if ($PSCmdlet.ShouldProcess('GitHub sign-in link', 'fetch the one-time sign-in link and wait for the sign-in')) { $null = Wait-SreGitHubSignIn -Context $Context -TimeoutSeconds $SignInTimeoutSeconds }
        }
    }
    $observed = Get-SreReleaseObserved -Context $Context -Desired $Desired
    $plan = Get-SreReleaseExtrasPlan -Desired $Desired -Observed $observed -Stage $Stage
    foreach ($note in $plan.notes) { Write-Host $note }
    if (-not $plan.operations.Count) { return @{ changed = $false; verified = $true; stage = $Stage; operations = @(); notes = $plan.notes } }
    if (-not $PSCmdlet.ShouldProcess($Context.resourceId, "Back up and apply $($plan.operations.Count) T12 setting(s): $(@($plan.operations | ForEach-Object { $_.name }) -join ', ') (Review mode stays; nothing is deleted)")) {
        return @{ changed = $false; verified = $false; stage = $Stage; preview = $plan; notes = $plan.notes }
    }
    $fullPath = [IO.Path]::GetFullPath("$BackupPath.release-$($Stage.ToLowerInvariant()).json")
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backups contain runtime configuration; choose a path outside the repository.' }
    if (-not (Test-Path -LiteralPath (Split-Path $fullPath -Parent) -PathType Container)) { throw 'Backup parent directory must already exist.' }
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($observed | ConvertTo-Json -Depth 30))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    foreach ($operation in $plan.operations) {
        $headers = @{}
        if ($operation.name -eq 'tool-policy') { $headers['If-Match'] = $(if ($observed.policy.etag) { $observed.policy.etag } else { '*' }) }
        $response = Invoke-SreData -Context $Context -Method PUT -Path $operation.path -Body $operation.body -Headers $headers
        if ($response.Status -ge 400 -and $response.Status -lt 500 -and $operation.name -eq 'tool-policy' -and $headers['If-Match'] -ne '*') {
            $response = Invoke-SreData -Context $Context -Method PUT -Path $operation.path -Body $operation.body -Headers @{ 'If-Match' = '*' }
        }
        Assert-SreDataSuccess -Response $response -What "Apply $($operation.name)"
        Write-Host "  applied $($operation.name) (HTTP $($response.Status), $($response.Ms) ms)"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadBackSeconds)
    do {
        $after = Get-SreReleaseExtrasPlan -Desired $Desired -Observed (Get-SreReleaseObserved -Context $Context -Desired $Desired) -Stage $Stage
        if (-not $after.operations.Count) { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Read-back does not show $(@($after.operations | ForEach-Object { $_.name }) -join ', ') after $ReadBackSeconds s. Nothing was replayed; inspect with Initialize-SreConfiguration.ps1 -Inspect and the backup before you apply again."
        }
        Start-Sleep -Seconds $(if ($ReadBackSeconds -lt 10) { 1 } else { 5 })
    } while ($true)
    $result = @{ changed = $true; verified = $true; stage = $Stage; backupPath = $fullPath; operations = @($plan.operations | ForEach-Object { $_.name }); notes = $plan.notes }
    if ($Stage -eq 'After') {
        $repositoryName = $Desired.release.repository.name
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $commit = ''
        do {
            $repoResponse = Invoke-SreData -Context $Context -Method GET -Path "/api/v2/repos/$([uri]::EscapeDataString($repositoryName))"
            $repoProperties = Get-SreProperty $repoResponse.Body 'properties'
            $commit = [string](Get-SreProperty $repoProperties 'latestCommit')
            if (-not $commit) { Start-Sleep -Seconds 5 }
        } while (-not $commit -and $clock.Elapsed.TotalSeconds -lt 180)
        if (-not $commit) { throw 'The repository was connected but no clone appeared within 180 s. Check the sign-in with GET /api/v2/github/domains and the repository state; the PUT was not replayed.' }
        $test = Invoke-SreData -Context $Context -Method POST -Path "/api/v2/repos/$([uri]::EscapeDataString($repositoryName))/test" -Body @{}
        $result.latestCommit = $commit.Substring(0, [Math]::Min(7, $commit.Length))
        $result.connectivity = "HTTP $($test.Status)"
    }
    return $result
}

function Get-SreReleaseDataChecks {
    <#
    .SYNOPSIS
    Readiness rows for the T12 extras, from reads only: guard, skills, hook (required), GitHub sign-in and repository (optional).
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired)
    $observed = Get-SreReleaseObserved -Context $Context -Desired $Desired
    $before = Get-SreReleaseExtrasPlan -Desired $Desired -Observed $observed -Stage Before
    $row = {
        param($id, $ok, $expected, $observedValue, $message, $required)
        @{ id = $id; resourceId = $Context.resourceId; required = $required; status = $(if ($ok) { 'pass' } else { 'fail' }); expected = $expected; observed = $observedValue; message = $message }
    }
    $guardPending = @($before.operations | Where-Object { $_.name -in @('tool-policy', 'guard-instruction') } | ForEach-Object { $_.name })
    $skillsPending = @($before.operations | Where-Object { $_.name -like 'skill:*' } | ForEach-Object { $_.name })
    $hookPending = @($before.operations | Where-Object { $_.name -like 'hook:*' } | ForEach-Object { $_.name })
    $domainCount = @($observed.domains).Count
    $signedIn = $domainCount -gt 0
    $repositoryReady = $observed.repository -and $observed.repository['properties'] -and [string]$observed.repository['properties']['latestCommit']
    @(
        (& $row 'T12-github-guard' $before.guardInPlace 'GitHub ask rules and the repository-only instruction present' $guardPending 'Review mode gates Azure writes only. GitHub writes stop for approval because of these ask rules; they must be in place before any GitHub connection.' $true)
        (& $row 'T12-skills' ($skillsPending.Count -eq 0) 'Both T12 skills present and current' $skillsPending 'Compares each skill file with the agent.' $true)
        (& $row 'T12-hook' ($hookPending.Count -eq 0) 'The Stop hook present, not disabled and current' $hookPending 'Compares the closing-check hook with the agent.' $true)
        @{ id = 'T12-github-signin'; resourceId = $Context.resourceId; required = $false; status = $(if ($signedIn) { 'pass' } else { 'pending' }); expected = 'GitHub sign-in present'; observed = $domainCount; message = 'The one human step per agent build. Without it the agent cannot read the repository or open the follow-up issue; the rollback still works.' }
        @{ id = 'T12-repository'; resourceId = $Context.resourceId; required = $false; status = $(if ($repositoryReady) { 'pass' } else { 'pending' }); expected = 'Repository connected and cloned'; observed = [bool]$repositoryReady; message = 'Needs the GitHub sign-in. Optional for the rollback; needed for code-level findings.' }
    )
}

Export-ModuleMember -Function ConvertTo-SreLf, ConvertTo-SreHashtable, Read-SreItem, Get-SreReleaseObserved, Get-SreReleaseGuardInstruction, Get-SreReleaseExtrasPlan, Wait-SreGitHubSignIn, Invoke-SreReleaseExtras, Get-SreReleaseDataChecks
