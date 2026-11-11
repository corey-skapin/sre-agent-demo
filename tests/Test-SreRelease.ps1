#Requires -Version 7.4
# Offline checks for the T12 "Friday release" settings, names, grants, desired configuration and App Service quota message.
# Every Azure and web call is mocked; nothing is deployed and no network is used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRelease.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreConfiguration.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreLifecycle.psm1') -Force
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$githubHost = 'github.com'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "T12 assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}

$previousResponder = $global:AzResponder
$previousExit = $global:AzExitCode
$skinPaths = [Collections.Generic.List[string]]::new()
try {
    # --- Skin and schema --------------------------------------------------------------------------------------------------------------
    $skinPath = New-TestT12SkinFile -Root $root
    $skinPaths.Add($skinPath)
    $skin = Get-DemoSkin -Path $skinPath -RepoRoot $root
    Check (Test-SreReleaseScenario -Skin $skin) 'A skin that lists T12 requires the release scenario'
    Check (-not (Test-SreReleaseScenario -Skin (Get-DemoSkin -RepoRoot $root))) 'The default skin (T09 and T11) does not'
    Throws { Get-SreReleaseSettings -Skin (Get-DemoSkin -RepoRoot $root) -SubscriptionId $subscription } 'release section'
    $broken = Get-Content -LiteralPath $skinPath -Raw | ConvertFrom-Json -AsHashtable
    $write = { param($data) $path = Join-Path ([IO.Path]::GetTempPath()) "t12-bad-$([guid]::NewGuid()).json"; [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20)); $skinPaths.Add($path); $path }
    $copy = { Get-Content -LiteralPath $skinPath -Raw | ConvertFrom-Json -AsHashtable }
    $data = & $copy; $data.Remove('release')
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|required'
    $data = & $copy; $data.release.goodVersion = '1.2.0'
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|pattern'
    $data = & $copy; $data.release.appServiceSku = 'P1v3'
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|enum'
    $data = & $copy; $data.release.appRepository = 'not a repository'
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|pattern'
    $data = & $copy; $data.release.surprise = 'x'
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|additional'
    $data = & $copy; $data.sre.requiredScenarios = @('T09', 'T11'); $data.release.goodVersion = 'whatever'
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|pattern'
    $data = & $copy; $data.sre.requiredScenarios = @('T13')
    Throws { Get-DemoSkin -Path (& $write $data) -RepoRoot $root } 'valid|schema|enum'
    $data = & $copy; $data.sre.requiredScenarios = @('T09', 'T11')
    Check ((Get-DemoSkin -Path (& $write $data) -RepoRoot $root).release.goodVersion -eq 'v1.2.0') 'A release section is allowed, and ignored, when T12 is not required'

    # --- Names and settings -----------------------------------------------------------------------------------------------------------
    $suffix = Get-SreReleaseSiteSuffix -SubscriptionId $subscription -ResourceGroupName 'rg-arc-demo-ticketing'
    Check ($suffix -cmatch '^[0-9a-f]{8}$') 'The web app suffix is 8 lowercase hex characters'
    Check ($suffix -ceq (Get-SreReleaseSiteSuffix -SubscriptionId $subscription.ToUpperInvariant() -ResourceGroupName 'RG-ARC-DEMO-TICKETING')) 'The suffix ignores case, so it never depends on how a name was typed'
    Check ($suffix -cne (Get-SreReleaseSiteSuffix -SubscriptionId $subscription -ResourceGroupName 'rg-other-ticketing')) 'A different group gets a different suffix'
    $settings = Get-SreReleaseSettings -Skin $skin -SubscriptionId $subscription
    Check ($settings.resourceGroup -ceq 'rg-arc-demo-ticketing' -and $settings.location -ceq 'australiasoutheast' -and $settings.sku -ceq 'B1') 'Defaults: group rg-<prefix>-ticketing, the skin location, B1'
    Check ($settings.appName -ceq "app-arc-demo-ticketing-$suffix" -and $settings.siteSuffix -ceq $suffix) 'The web app name is app-<prefix>-ticketing-<suffix>'
    Check ($settings.appId -ceq "/subscriptions/$subscription/resourceGroups/rg-arc-demo-ticketing/providers/Microsoft.Web/sites/$($settings.appName)") 'The web app ID is computable without Azure'
    Check ($settings.workspaceId -ceq "/subscriptions/$subscription/resourceGroups/rg-arc-demo-ticketing/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo-ticketing") 'The workspace ID is computable without Azure'
    Check ($settings.alertName -ceq 'alert-arc-demo-ticketing-checkout-failures' -and $settings.spareAlertName -ceq "$($settings.alertName)-b" -and $settings.alertTitle -ceq 'ticketing-checkout-failures') 'Alert rule names and the plan keyword'
    Check ($settings.handlerName -ceq 'ticketing-release-investigator' -and $settings.responsePlan -ceq 'ticketing-release-review-v1') 'Handler and response plan names default'
    $custom = Get-TestT12Skin -Root $root -Release @{ resourceGroup = 'rg-custom'; appServiceSku = 'B2'; handlerName = 'my-handler'; responsePlan = 'my-plan-v1' }
    $customSettings = Get-SreReleaseSettings -Skin $custom -SubscriptionId $subscription
    Check ($customSettings.resourceGroup -ceq 'rg-custom' -and $customSettings.sku -ceq 'B2' -and $customSettings.handlerName -ceq 'my-handler' -and $customSettings.responsePlan -ceq 'my-plan-v1') 'The release section overrides group, SKU, handler and plan'
    Check ($customSettings.siteSuffix -cne $suffix) 'The suffix follows the group'
    Throws { Get-SreReleaseSettings -Skin (Get-TestT12Skin -Root $root -Release @{ goodVersion = 'v1.2.0'; badVersion = 'v1.2.0' }) -SubscriptionId $subscription } 'must differ'
    foreach ($shared in 'rg-arc-demo', 'rg-arc-demo-infra', 'rg-arc-demo-sre', 'RG-Arc-Demo-SRE') {
        Throws { Get-SreReleaseSettings -Skin (Get-TestT12Skin -Root $root -Release @{ resourceGroup = $shared }) -SubscriptionId $subscription } 'Arc estate or the SRE layer'
    }
    Check ((Get-SreReleaseSettings -Skin (Get-TestT12Skin -Root $root -Release @{ resourceGroup = 'rg-arc-demo-ticketing' }) -SubscriptionId $subscription).resourceGroup -ceq 'rg-arc-demo-ticketing') 'The dedicated group name is allowed; the Arc and SRE groups are refused as the ticketing group, so a Remove can never reach them'
    Check ($null -eq (Assert-SreReleaseGroupOwnership -GroupName 'rg-new' -Exists $false -Tags $null)) 'A group that does not exist yet is ours to create'
    Check ($null -eq (Assert-SreReleaseGroupOwnership -GroupName 'rg-ours' -Exists $true -Tags ('{"owner":"demo","sreScenario":"T12"}' | ConvertFrom-Json)) -and $null -eq (Assert-SreReleaseGroupOwnership -GroupName 'rg-ours' -Exists $true -Tags @{ sreScenario = 'T12' })) 'A group already tagged sreScenario=T12 is ours, as parsed JSON or as a table'
    foreach ($tags in @($null, @{}, @{ owner = 'someone' }, @{ sreScenario = 'T09' }, @{ sreScenario = 't12' }, ('{"owner":"someone"}' | ConvertFrom-Json))) {
        Throws { Assert-SreReleaseGroupOwnership -GroupName 'rg-someone-elses' -Exists $true -Tags $tags } "'rg-someone-elses' already exists and was not created by this scenario"
    }
    Check ((Get-SreReleasePackageUrl -Settings $settings -Version 'v1.2.0') -ceq "https://$githubHost/example-owner/ticketing-app/releases/download/v1.2.0/ticketing-app-v1.2.0.zip") 'Package URL is the release asset for the tag'
    foreach ($bad in @('1.2.0', 'v1.2', 'v1.2.0/../x', 'v1.2.0 ', 'latest')) {
        Throws { Get-SreReleasePackageUrl -Settings $settings -Version $bad } 'Release version must look like'
    }

    # --- Grants -----------------------------------------------------------------------------------------------------------------------
    $grants = @(Get-SreReleaseKnownGrants -Settings $settings)
    Check ($grants.Count -eq 1 -and $grants[0].scope -ceq $settings.appId -and $grants[0].roleId -ceq 'de139f84-1756-47ae-9be6-808fbbe84772') 'The only standing grant is Website Contributor on the web app'
    Check (@(Get-SreReleaseGrantsForSkin -Skin (Get-DemoSkin -RepoRoot $root) -SubscriptionId $subscription).Count -eq 0) 'No grants are known for a skin without T12'
    Check (@(Get-SreReleaseGrantsForSkin -Skin $skin -SubscriptionId $subscription).Count -eq 1) 'One grant is known for a T12 skin'
    $assignment = [pscustomobject]@{ scope = $settings.appId.ToUpperInvariant(); roleDefinitionId = '/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/DE139F84-1756-47AE-9BE6-808FBBE84772' }
    Check (Test-SreKnownGrant -Assignment $assignment -KnownGrants $grants) 'A known grant matches by exact scope and role, ignoring case'
    Check (-not (Test-SreKnownGrant -Assignment ([pscustomobject]@{ scope = $settings.groupId; roleDefinitionId = '/roles/de139f84-1756-47ae-9be6-808fbbe84772' }) -KnownGrants $grants)) 'The same role one level up (the group) is not known'
    Check (-not (Test-SreKnownGrant -Assignment ([pscustomobject]@{ scope = $settings.appId; roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c' }) -KnownGrants $grants)) 'A different role on the web app is not known'
    Check (-not (Test-SreKnownGrant -Assignment $assignment -KnownGrants @())) 'With no known grants nothing matches'

    # --- Deployment parameters --------------------------------------------------------------------------------------------------------
    $body = Get-SreReleaseDeploymentParameters -Skin $skin -Settings $settings -Version 'v1.2.0' -SiteWriterAssignmentName '' -Tags @{ owner = 'demo' }
    Check ($body.parameters.packageUrl.value -ceq (Get-SreReleasePackageUrl -Settings $settings -Version 'v1.2.0') -and $body.parameters.siteSuffix.value -ceq $suffix) 'Parameter file carries the first release and the suffix'
    Check ($body.parameters.workloadLocation.value -ceq 'australiasoutheast' -and $body.parameters.sreLocation.value -ceq 'australiaeast') 'The workload and the SRE layer keep their own regions'
    Check ($body.parameters.sreResourceGroupName.value -ceq 'rg-arc-demo-sre' -and $body.parameters.workloadResourceGroupName.value -ceq 'rg-arc-demo-ticketing' -and $body.parameters.agentName.value -ceq 'sre-arc-demo') 'Group and agent names come from the skin'
    Check ((Get-SreReleaseDeploymentParameters -Skin $skin -Settings $settings -Version 'v1.2.0' -SiteWriterAssignmentName 'adopted' -Tags @{}).parameters.siteWriterAssignmentName.value -ceq 'adopted') 'An existing grant name is adopted instead of creating a second grant'

    # --- Markdown config files --------------------------------------------------------------------------------------------------------
    $parsed = ConvertFrom-SreMarkdownConfig -Text "<!-- notice -->`r`n<!-- more -->`r`n---`r`nname: x`r`ndescription: A: B`r`n---`r`n`r`nBody line 1`r`nBody line 2`r`n"
    Check ($parsed.meta['name'] -eq 'x' -and $parsed.meta['description'] -eq 'A: B') 'Front matter keys are read, and a colon in a value is kept'
    Check ($parsed.body -ceq "Body line 1`nBody line 2") 'The body is trimmed and uses LF'
    Throws { ConvertFrom-SreMarkdownConfig -Text "no front matter here" } 'no front matter'
    Throws { ConvertFrom-SreMarkdownConfig -Text "---`nname: x`n" } 'not closed'

    # --- Rendered configuration -------------------------------------------------------------------------------------------------------
    $desired = Get-SreReleaseDesired -Skin $skin -SubscriptionId $subscription
    $all = @($desired.handler.properties.instructions) + @($desired.skills | ForEach-Object { $_.content }) + @($desired.hook.prompt, $desired.guard.text)
    Check (@($all | Where-Object { $_ -match '\{[A-Za-z][A-Za-z0-9]*\}' }).Count -eq 0) 'No token is left unfilled in any rendered text'
    Check (@($all | Where-Object { $_ -match "`r" }).Count -eq 0) 'Rendered text uses LF, so a CRLF checkout cannot show false drift'
    Check ($desired.handler.name -ceq 'ticketing-release-investigator' -and $desired.handler.type -ceq 'ExtendedAgent') 'The handler is its own custom agent'
    Check ($desired.handler.properties.instructions.Contains($settings.appName) -and $desired.handler.properties.instructions.Contains($settings.workspaceId) -and $desired.handler.properties.instructions.Contains($settings.alertName)) 'Instructions name the app, workspace and alert from the skin'
    Check ($desired.handler.properties.instructions.Contains("https://$githubHost/example-owner/ticketing-app/releases/download/") -and $desired.handler.properties.instructions.Contains('WEBSITE_RUN_FROM_PACKAGE')) 'Instructions carry the redeploy mechanism and the release URL prefix'
    Check ($desired.handler.properties.instructions -match 'approved by a person|a person approved') 'The closing-summary fix: a completed card means a person approved it'
    Check ($desired.plan.properties.agentMode -ceq 'Review' -and $desired.plan.properties.mergeEnabled -eq $false -and $desired.plan.properties.titleContains -ceq 'ticketing-checkout-failures') 'Plan: Review mode, cooldown (merge) off, one keyword'
    Check ($desired.plan.properties.priorities.Count -eq 1 -and $desired.plan.properties.priorities[0] -ceq 'Sev2' -and $desired.plan.properties.handlingAgent -ceq $desired.handler.name) 'Plan: Sev2 only, handled by the T12 handler'
    Check (@($desired.skills | ForEach-Object { $_.name }) -join ',' -ceq 'azure-monitor-rca,github-issue-followup') 'Two skills'
    Check (@($desired.skills | Where-Object { -not $_.description -or -not $_.content }).Count -eq 0) 'Every skill has a description and content'
    Check ($desired.hook.eventType -ceq 'Stop' -and $desired.hook.timeout -gt 0 -and $desired.hook.maxRejections -ge 0 -and $desired.hook.prompt) 'The closing hook is a Stop prompt hook with a timeout and a rejection cap'
    Check ($desired.guard.marker -ceq '[github-guard]' -and $desired.guard.text.StartsWith('[github-guard]') -and $desired.guard.text.Contains('example-owner/ticketing-app')) 'The guard paragraph starts with its marker and names only the demo repository'
    Check ($desired.repository.name -ceq 'ticketing-app' -and $desired.repository.url -ceq "https://$githubHost/example-owner/ticketing-app" -and $desired.repository.branch -ceq 'main') 'Repository connection from the skin'
    # Review mode gates Azure writes only. Every GitHub tool the handler can use must be an explicit read or sit behind an ask rule.
    $githubTools = @($desired.handler.properties.tools | Where-Object { $_ -match 'Github' })
    Check ($githubTools.Count -ge 3 -and 'CreateGithubIssue' -in $githubTools) 'The handler lists the GitHub tools it relies on'
    foreach ($tool in $githubTools) {
        $allowed = @($desired.policy.allow | Where-Object { $tool -like $_ }).Count -gt 0
        $asked = @($desired.policy.ask | Where-Object { $tool -like $_ }).Count -gt 0
        Check ($allowed -or $asked) "GitHub tool $tool is an explicit read or is covered by an ask rule"
        if ($tool -match 'Create|Update|Assign|Merge|Push|Delete|Comment') { Check ($asked -and -not $allowed) "GitHub write tool $tool asks and is never allowed without asking" }
    }
    Check (@($desired.policy.allow | Where-Object { $_ -match '[*?]|Create|Update|Assign|Merge|Push|Delete' }).Count -eq 0) 'The allow list holds exact read tool names only'
    Check (@($desired.policy.ask | Where-Object { 'bash(git push origin main)' -like $_ -or 'bash(gh pr create)' -like $_ -or 'CreatePullRequest' -like $_ }).Count -ge 3) 'Ask rules cover git push, the gh CLI and pull-request tools'
    Check (@($desired.policy.deny | Where-Object { $_ -match 'az group delete' }).Count -eq 1 -and @($desired.policy.deny | Where-Object { $_ -match 'az webapp delete' }).Count -eq 1) 'Deny rules cover deleting the group and the web app'
    Check ('RunAzCliWriteCommands' -in $desired.handler.properties.tools -and 'RunAzCliReadCommands' -in $desired.handler.properties.tools) 'The one Azure write goes through the Review-gated write tool'

    # --- Desired configuration: T12 alone and beside the Arc scenarios ---------------------------------------------------------------
    $only = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath
    Check ($null -eq $only.handler -and @($only.extraHandlers).Count -eq 1 -and $only.extraHandlers[0].name -ceq 'ticketing-release-investigator') 'T12 alone renders no Arc handler, only its own'
    Check (@($only.plans).Count -eq 1 -and $only.plans[0].properties.mergeEnabled -eq $false -and $only.plans[0].name -ceq 'ticketing-release-review-v1') 'T12 alone renders one plan with the cooldown off'
    Check ($only.release.settings.appName -ceq $settings.appName -and @($only.release.skills).Count -eq 2 -and $only.release.hook.eventType -ceq 'Stop') 'T12 alone carries skills, hook, policy, guard and repository'
    $mixedPath = New-TestT12SkinFile -Root $root -Scenarios @('T09', 'T11', 'T12')
    $skinPaths.Add($mixedPath)
    $mixed = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $mixedPath
    Check ($mixed.handler.name -ceq 'sre-arc-demo' -and @($mixed.extraHandlers).Count -eq 1) 'With the Arc scenarios the Arc handler stays and T12 adds its own'
    Check (@($mixed.plans).Count -eq 3 -and @($mixed.plans | ForEach-Object { $_.name } | Select-Object -Unique).Count -eq 3) 'Three plans, three distinct names'
    Check (@($mixed.plans | Where-Object { $_.properties.agentMode -ne 'Review' }).Count -eq 0) 'Every plan is Review'
    Check (@($mixed.plans | Where-Object { $_.scenario -ne 'T12' -and $_.properties.mergeEnabled -ne $true }).Count -eq 0) 'The Arc plans keep the cooldown on, as before'
    $default = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant
    Check ($null -eq $default.release -and @($default.extraHandlers).Count -eq 0 -and @($default.plans).Count -eq 2) 'The default skin renders exactly what it did before T12 existed'
    $rendered = & (Join-Path $root 'scripts\Initialize-SreConfiguration.ps1') -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath | ConvertFrom-Json
    Check ($rendered.release.settings.appName -eq $settings.appName -and $rendered.plans[0].properties.mergeEnabled -eq $false) 'Initialize-SreConfiguration.ps1 previews the T12 configuration without Azure'

    # --- App Service quota message ----------------------------------------------------------------------------------------------------
    $global:AzCalls.Clear()
    $global:AzExitCode = 0
    $global:AzResponder = { '' }
    Assert-SreReleaseQuota -SubscriptionId $subscription -CarrierGroup 'rg-arc-demo-sre' -Location 'australiasoutheast' -Sku 'B1' -ProbeTemplate 'quota-probe.bicep'
    Check ($global:AzCalls.Count -eq 1 -and $global:AzCalls[0] -like 'deployment group validate --resource-group rg-arc-demo-sre --template-file quota-probe.bicep --parameters location=australiasoutheast skuName=B1 -o none --subscription *') 'The quota check is one group-scope validate; it creates nothing'
    $global:AzExitCode = 1
    $global:AzResponder = { Write-Error 'ERROR: InternalSubscriptionIsOverQuotaForSku: This region has quota of 0 instances for your subscription. Current Limit (Basic VMs): 0' -ErrorAction Continue }
    $quota = $null
    try { Assert-SreReleaseQuota -SubscriptionId $subscription -CarrierGroup 'rg-arc-demo-sre' -Location 'australiaeast' -Sku 'B1' -ProbeTemplate 'quota-probe.bicep' } catch { $quota = $_.Exception.Message }
    Check ($quota -and $quota -match "no quota for B1 in 'australiaeast'" -and $quota -match 'limit for Basic VMs is 0' -and $quota -match 'Nothing was created') 'No quota gives a clear message with the region, SKU and limit'
    Check ($quota -match 'release\.location' -and $quota -match 'Quotas > App Service' -and $quota -match 'learn\.microsoft\.com/troubleshoot/azure/app-service' -and $quota -match 'No quota request has been filed') 'It names both ways out and says nothing was requested for you'
    $global:AzResponder = { Write-Error 'ERROR: AuthorizationFailed: you cannot validate here' -ErrorAction Continue }
    Throws { Assert-SreReleaseQuota -SubscriptionId $subscription -CarrierGroup 'rg-arc-demo-sre' -Location 'australiasoutheast' -Sku 'B1' -ProbeTemplate 'quota-probe.bicep' } 'AuthorizationFailed'
    $global:AzExitCode = 0

    # --- Web calls (mocked) and the readiness rows ------------------------------------------------------------------------------------
    $global:WebCalls = [Collections.Generic.List[string]]::new()
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok","version":"1.2.0","release":"abcdef1"}' } }
    function global:Invoke-WebRequest { $global:WebCalls.Add(($args -join ' ')); & $global:WebResponder @args }
    Throws { Test-SreReleasePackage -Url 'https://example.com/ticketing-app-v1.2.0.zip' } 'Unexpected release package URL'
    Throws { Test-SreReleasePackage -Url 'http://github.com/example-owner/ticketing-app/releases/download/v1.2.0/ticketing-app-v1.2.0.zip' } 'Unexpected release package URL'
    Check ($global:WebCalls.Count -eq 0) 'A URL that is not a release asset is rejected before any request'
    $package = Test-SreReleasePackage -Url (Get-SreReleasePackageUrl -Settings $settings -Version 'v1.2.0')
    Check ($package.ok -and $package.status -eq 200 -and $global:WebCalls[0] -match '-Method Head') 'A downloadable package is checked with HEAD'
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 404; Content = '' } }
    Check (-not (Test-SreReleasePackage -Url (Get-SreReleasePackageUrl -Settings $settings -Version 'v1.3.0')).ok) 'A missing package is reported, not thrown'
    $global:WebResponder = { throw 'connection refused' }
    Check ((Test-SreReleasePackage -Url (Get-SreReleasePackageUrl -Settings $settings -Version 'v1.3.0')).status -eq 0) 'A network failure is reported as status 0'
    $summary = Get-SreReleaseSummary -HostName 'app.azurewebsites.net'
    Check (-not $summary.reachable -and $summary.detail -match 'connection refused') 'An unreachable app is reported with the reason'
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok","version":"1.2.0","release":"abcdef1"}' } }
    $summary = Get-SreReleaseSummary -HostName 'app.azurewebsites.net'
    Check ($summary.reachable -and $summary.status -eq 200 -and $summary.version -ceq '1.2.0' -and $summary.release -ceq 'abcdef1') '/healthz reports the running version and release'
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 503; Content = 'not json' } }
    $summary = Get-SreReleaseSummary -HostName 'app.azurewebsites.net'
    Check ($summary.reachable -and $summary.status -eq 503 -and $null -eq $summary.version) 'A non-JSON error page yields no version'
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok","version":"1.2.0","release":"abcdef1"}' } }
    Check ((Wait-SreReleaseHealthy -HostName 'app.azurewebsites.net' -Version 'v1.2.0' -TimeoutSeconds 5 -PollSeconds 1).release -ceq 'abcdef1') 'Waiting returns as soon as /healthz serves the expected release'
    Throws { Wait-SreReleaseHealthy -HostName 'app.azurewebsites.net' -Version 'v1.3.0' -TimeoutSeconds 1 -PollSeconds 1 } "did not serve v1\.3\.0 within 1 s; last observation: HTTP 200, version '1\.2\.0'"

    $state = @{
        site = @{ properties = @{ state = 'Running'; defaultHostName = 'app.azurewebsites.net' }; tags = @{ sreScenario = 'T12' } }
        rules = @{}
        failSite = $false
    }
    $state.rules[$settings.alertName] = @{ properties = @{ severity = 2; displayName = $settings.alertName; scopes = @($settings.workspaceId); enabled = $true } }
    $state.rules[$settings.spareAlertName] = @{ properties = @{ severity = 2; displayName = $settings.spareAlertName; scopes = @($settings.workspaceId); enabled = $false } }
    $global:T12State = $state
    $global:AzResponder = {
        $command = $args -join ' '
        $state = $global:T12State
        if ($command -like '*--query properties.defaultHostName*') { return $state.site.properties.defaultHostName }
        if ($command -like 'resource show --ids */providers/Microsoft.Web/sites/*') {
            if ($state.failSite) { throw 'ResourceNotFound: the web app could not be found' }
            return $state.site | ConvertTo-Json -Depth 10
        }
        if ($command -like 'resource show --ids */scheduledQueryRules/*') { return $state.rules[($args[3] -split '/')[-1]] | ConvertTo-Json -Depth 10 }
        throw "Unexpected mocked call: $command"
    }
    $hostName = Get-SreReleaseAppHost -SubscriptionId $subscription -Settings $settings
    Check ($hostName -ceq 'app.azurewebsites.net') 'The host name comes from ARM'
    $state.site.properties.defaultHostName = 'evil.example.com'
    Throws { Get-SreReleaseAppHost -SubscriptionId $subscription -Settings $settings } 'unexpected host name'
    $state.site.properties.defaultHostName = 'app.azurewebsites.net'
    $rows = @(Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)
    Check (@($rows | ForEach-Object { $_.id }) -join ',' -ceq 'T12-web-app,T12-release,T12-alert') 'Three readiness rows'
    Check (@($rows | Where-Object { $_.status -ne 'pass' }).Count -eq 0 -and @($rows | Where-Object { -not $_.required }).Count -eq 0) 'A healthy workload passes all three required rows'
    $state.site.tags = @{}
    Check ((Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[0].status -eq 'fail') 'A web app without the sreScenario tag is not the workload this repo owns'
    $state.site.tags = @{ sreScenario = 'T12' }
    $state.site.properties.state = 'Stopped'
    Check ((Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[0].status -eq 'fail') 'A stopped web app fails'
    $state.site.properties.state = 'Running'
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok","version":"1.3.0","release":"badbad1"}' } }
    $release = (Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[1]
    Check ($release.status -eq 'fail' -and $release.observed -match 'v1\.3\.0') 'A run left on the bad release fails readiness and says which version is serving'
    $global:WebResponder = { throw 'connection refused' }
    Check ((Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[1].status -eq 'pending') 'A cold or unreachable app is pending, not a failure of the build'
    $state.rules[$settings.spareAlertName].properties.enabled = $true
    Check ((Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[2].status -eq 'fail') 'Both alert rules on would open two threads, so readiness fails'
    $state.rules[$settings.spareAlertName].properties.enabled = $false
    $state.rules[$settings.alertName].properties.severity = 3
    Check ((Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)[2].status -eq 'fail') 'A rule that is not Sev2 never matches the response plan'
    $state.rules[$settings.alertName].properties.severity = 2
    $state.failSite = $true
    $failed = @(Get-SreReleaseReadinessChecks -SubscriptionId $subscription -Settings $settings)
    Check ($failed[0].status -eq 'fail' -and $failed[0].message -match 'Deploy-TicketingWorkload' -and @($failed | Where-Object id -EQ 'T12-release').Count -eq 0) 'A missing web app fails with the next step and skips the release check'

    Write-Host "$count T12 settings, grants, configuration and quota assertions passed. Azure and web calls were mocked."
} finally {
    Remove-Item Function:\global:Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name WebCalls, WebResponder, T12State -ErrorAction SilentlyContinue
    $global:AzResponder = $previousResponder
    $global:AzExitCode = $previousExit
    foreach ($path in $skinPaths) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
