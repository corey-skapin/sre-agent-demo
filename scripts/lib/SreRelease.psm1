Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')

# T12, "the Friday release": a ticketing web app on App Service that an app release breaks. This module holds the names,
# URLs and grants every script shares, so Deploy, readiness, Hibernate and the scenario runner agree on them.
# The Bicep in infra/ticketing builds the same names; tests/Test-TicketingTemplate.ps1 checks that they match.
$script:WebsiteContributorRoleId = 'de139f84-1756-47ae-9be6-808fbbe84772'
$script:GitHubHost = 'github.com'

function Test-SreReleaseScenario {
    param([Parameter(Mandatory)][object]$Skin)
    return 'T12' -in @(Get-DemoSkinValue -Skin $Skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
}

function Get-SreReleaseSiteSuffix {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$ResourceGroupName)
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$ResourceGroupName".ToLowerInvariant()))
    return -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
}

function Get-SreReleaseSettings {
    <#
    .SYNOPSIS
    Derives every T12 name from the skin. Nothing here calls Azure.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $release = Get-DemoSkinValue -Skin $Skin -Path 'release' -Default $null
    if ($null -eq $release) { throw 'T12 needs a release section in the skin: location, appRepository, goodVersion and badVersion.' }
    $prefix = $Skin.azure.namePrefix
    $group = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.resourceGroup' -Default "rg-$prefix-ticketing")
    $repository = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.appRepository' -Default '')
    $good = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.goodVersion' -Default '')
    $bad = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.badVersion' -Default '')
    $location = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.location' -Default '')
    Assert-SreName -Value $group -Description 'ticketing resource group'
    # Remove-TicketingWorkload.ps1 deletes this group, so it can never be one the Arc estate or the SRE layer uses.
    if ($group -in @("rg-$prefix", "rg-$prefix-infra", "rg-$prefix-sre")) {
        throw "release.resourceGroup '$group' is a group the Arc estate or the SRE layer uses. Leave it out to get the dedicated rg-$prefix-ticketing, or pick another name."
    }
    Assert-SreName -Value $location -Description 'ticketing location' -Pattern '^[a-z][a-z0-9]+$'
    Assert-SreName -Value $repository -Description 'app repository (owner/name)' -Pattern '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
    foreach ($version in @($good, $bad)) { Assert-SreName -Value $version -Description 'release version (vMAJOR.MINOR.PATCH)' -Pattern '^v\d+\.\d+\.\d+$' }
    if ($good -eq $bad) { throw 'release.goodVersion and release.badVersion must differ.' }
    $suffix = Get-SreReleaseSiteSuffix -SubscriptionId $SubscriptionId -ResourceGroupName $group
    $groupId = "/subscriptions/$SubscriptionId/resourceGroups/$group"
    $alertName = "alert-$prefix-ticketing-checkout-failures"
    $appName = "app-$prefix-ticketing-$suffix"
    $workspaceName = "law-$prefix-ticketing"
    [ordered]@{
        resourceGroup = $group; groupId = $groupId; location = $location
        repository = $repository; goodVersion = $good; badVersion = $bad
        sku = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.appServiceSku' -Default 'B1')
        namePrefix = $prefix; siteSuffix = $suffix
        planName = "plan-$prefix-ticketing"; workspaceName = $workspaceName; appInsightsName = "appi-$prefix-ticketing"
        actionGroupName = "ag-$prefix-ticketing"; alertName = $alertName; spareAlertName = "$alertName-b"
        alertTitle = 'ticketing-checkout-failures'
        appName = $appName; appId = "$groupId/providers/Microsoft.Web/sites/$appName"
        workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
        handlerName = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.handlerName' -Default 'ticketing-release-investigator')
        responsePlan = [string](Get-DemoSkinValue -Skin $Skin -Path 'release.responsePlan' -Default 'ticketing-release-review-v1')
    }
}

function Assert-SreReleaseGroupOwnership {
    <#
    .SYNOPSIS
    Refuses to deploy into a resource group this scenario did not create.
    .DESCRIPTION
    The workload Bicep tags its group sreScenario=T12, and Remove-TicketingWorkload.ps1 deletes the group on that tag. Deploying into a group that
    already holds something else would stamp the tag on it and make a later Remove delete work that is not ours.
    #>
    param([Parameter(Mandatory)][string]$GroupName, [Parameter(Mandatory)][bool]$Exists, [AllowNull()]$Tags)
    if (-not $Exists) { return }
    $owner = $null
    if ($Tags -is [Collections.IDictionary]) { if ($Tags.Contains('sreScenario')) { $owner = $Tags['sreScenario'] } }
    elseif ($null -ne $Tags -and $Tags.PSObject.Properties['sreScenario']) { $owner = $Tags.sreScenario }
    if ([string]$owner -cne 'T12') {
        throw ("Resource group '$GroupName' already exists and was not created by this scenario (it has no sreScenario=T12 tag). " +
            'Deploying into it would take it over, and Remove-TicketingWorkload.ps1 would later delete everything in it. ' +
            'Set release.resourceGroup in your private skin to a new name, or delete the group yourself first if it is empty and yours.')
    }
}

function Get-SreReleasePackageUrl {
    # Release assets are published by the app repository's release workflow, one zip per tag.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Version)
    if ($Version -notmatch '^v\d+\.\d+\.\d+$') { throw "Release version must look like v1.2.3, not '$Version'." }
    return "https://$script:GitHubHost/$($Settings.repository)/releases/download/$Version/ticketing-app-$Version.zip"
}

function Get-SreReleaseKnownGrants {
    # The one grant the workload Bicep gives the SRE identity. Everything that inspects grants treats it as owned.
    # Reading the group needs no grant of its own: the subscription Monitoring Contributor grant that alert access requires carries */read.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    @(
        [pscustomobject]@{ scope = $Settings.appId; roleId = $script:WebsiteContributorRoleId; purpose = 'Change only the ticketing web app' }
    )
}

function Get-SreReleaseGrantsForSkin {
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    if (-not (Test-SreReleaseScenario -Skin $Skin)) { return @() }
    return @(Get-SreReleaseKnownGrants -Settings (Get-SreReleaseSettings -Skin $Skin -SubscriptionId $SubscriptionId))
}

function Assert-SreReleaseQuota {
    <#
    .SYNOPSIS
    Asks App Service, without creating anything, whether this subscription has quota for the plan in the region.
    .DESCRIPTION
    Runs az deployment group validate on infra/ticketing/quota-probe.bicep against a group that already exists. Validation in an existing
    group reaches App Service's quota check; validation at subscription scope, or against a group that does not exist yet, passes with zero quota.
    list-locations is no help either: it lists regions that offer the SKU, not regions where this subscription may use it.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$CarrierGroup,
        [Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string]$Sku, [Parameter(Mandatory)][string]$ProbeTemplate
    )
    try {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @(
            'deployment', 'group', 'validate', '--resource-group', $CarrierGroup, '--template-file', $ProbeTemplate,
            '--parameters', "location=$Location", "skuName=$Sku", '-o', 'none') | Out-Null
    } catch {
        $text = $_.Exception.Message
        if ($text -notmatch 'SubscriptionIsOverQuotaForSku|without additional quota') { throw }
        $limit = [regex]::Match($text, 'Current Limit \(([^)]+)\): (\d+)')
        $seen = if ($limit.Success) { "the limit for $($limit.Groups[1].Value) is $($limit.Groups[2].Value)" } else { 'the limit is 0' }
        throw ("App Service has no quota for $Sku in '$Location' on this subscription ($seen). Nothing was created. Pick one:`n" +
            "  1. Set release.location in your private skin to a region that passes this same check, then run this script again. australiasoutheast passed when this was built; list-locations does not show quota.`n" +
            "  2. Ask for quota: Azure portal > Quotas > App Service (Public Preview), filter this subscription and region, select $Sku and request a new limit of at least 1. " +
            "Steps and the support-request fallback: https://learn.microsoft.com/troubleshoot/azure/app-service/troubleshoot-non-zone-redundant-quota-requests`n" +
            "No quota request has been filed for you.")
    }
}

function Test-SreReleasePackage {
    <#
    .SYNOPSIS
    Checks that a release package can be downloaded (HEAD, following the GitHub redirect). Read-only.
    #>
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSeconds = 30)
    if ($Url -notmatch '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/v\d+\.\d+\.\d+/ticketing-app-v\d+\.\d+\.\d+\.zip$') { throw "Unexpected release package URL: $Url" }
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -ErrorAction Stop
        return [pscustomobject]@{ url = $Url; ok = ([int]$response.StatusCode -eq 200); status = [int]$response.StatusCode }
    } catch {
        return [pscustomobject]@{ url = $Url; ok = $false; status = 0 }
    }
}

function Wait-SreReleaseHealthy {
    <#
    .SYNOPSIS
    Polls /healthz until the web app serves the expected release; throws with the last observation after the timeout.
    #>
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Version, [int]$TimeoutSeconds = 600, [int]$PollSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $last = Get-SreReleaseSummary -HostName $HostName
        if ($last.reachable -and $last.status -eq 200 -and $last.version -and "v$($last.version)" -eq $Version) { return $last }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
    $seen = if ($last.reachable) { "HTTP $($last.status), version '$($last.version)'" } else { "unreachable ($($last.detail))" }
    throw "The web app did not serve $Version within $TimeoutSeconds s; last observation: $seen."
}

function Get-SreReleaseAppHost {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $hostName = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'show', '--ids', $Settings.appId, '--query', 'properties.defaultHostName', '-o', 'tsv')
    if ($hostName -notmatch '^[a-z0-9][a-z0-9.-]*\.azurewebsites\.net$') { throw "The web app returned an unexpected host name '$hostName'." }
    return $hostName
}

function Get-SreReleaseSummary {
    # One read of /healthz: which release is the app running right now?
    param([Parameter(Mandatory)][string]$HostName, [int]$TimeoutSeconds = 15)
    try {
        $response = Invoke-WebRequest -Uri "https://$HostName/healthz" -Method Get -SkipHttpErrorCheck -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ reachable = $false; status = 0; version = $null; release = $null; detail = $_.Exception.Message }
    }
    $body = $null
    try { $body = [string]$response.Content | ConvertFrom-Json -ErrorAction Stop } catch { $body = $null }
    $version = if ($body -and $body.PSObject.Properties['version']) { [string]$body.version } else { $null }
    $sha = if ($body -and $body.PSObject.Properties['release']) { [string]$body.release } else { $null }
    [pscustomobject]@{ reachable = $true; status = [int]$response.StatusCode; version = $version; release = $sha; detail = '' }
}

function Get-SreReleaseReadinessChecks {
    <#
    .SYNOPSIS
    Read-only T12 workload checks for Test-SreReadiness: the group and web app, the running release, and the alert rules.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $checks = [Collections.Generic.List[object]]::new()
    function New-Check([string]$Id, [string]$ResourceId, [string]$Status, $Expected, $Observed, [string]$Message) {
        $checks.Add([ordered]@{ id = $Id; resourceId = $ResourceId; required = $true; expected = $Expected; observed = $Observed; status = $Status; message = $Message })
    }
    $appId = $Settings.appId
    $site = $null
    try {
        $site = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'show', '--ids', $appId, '-o', 'json') | ConvertFrom-Json -Depth 50
        $state = [string]$site.properties.state
        $tags = $site.PSObject.Properties['tags']
        $tagged = $tags -and $tags.Value -and $tags.Value.PSObject.Properties['sreScenario'] -and $tags.Value.sreScenario -eq 'T12'
        New-Check 'T12-web-app' $appId $(if ($state -eq 'Running' -and $tagged) { 'pass' } else { 'fail' }) 'Running web app tagged sreScenario=T12' $state 'Deploy-TicketingWorkload.ps1 creates the web app; a stopped or untagged app is not the workload this repo owns.'
    } catch {
        New-Check 'T12-web-app' $appId 'fail' 'Readable T12 web app' $null "$($_.Exception.Message) Run Deploy-TicketingWorkload.ps1 first."
    }
    if ($site) {
        $summary = Get-SreReleaseSummary -HostName ([string]$site.properties.defaultHostName)
        $running = if ($summary.version) { "v$($summary.version)" } else { '' }
        $status = if (-not $summary.reachable -or $summary.status -ne 200) { 'pending' } elseif ($running -eq $Settings.goodVersion) { 'pass' } else { 'fail' }
        New-Check 'T12-release' $appId $status "/healthz reports $($Settings.goodVersion)" $(if ($summary.reachable) { "HTTP $($summary.status) $running" } else { 'unreachable' }) 'The app must serve the last good release before a run. After a bad release, run Invoke-FridayRelease.ps1 -Action Reset; a cold start can take minutes.'
    }
    $rules = @{}
    foreach ($name in @($Settings.alertName, $Settings.spareAlertName)) {
        $id = "$($Settings.groupId)/providers/Microsoft.Insights/scheduledQueryRules/$name"
        try {
            $rules[$name] = (Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'show', '--ids', $id, '-o', 'json') | ConvertFrom-Json -Depth 50).properties
        } catch {
            $rules[$name] = $null
        }
    }
    $primary = $rules[$Settings.alertName]
    $spare = $rules[$Settings.spareAlertName]
    $shape = { param($p) $p -and $p.severity -eq 2 -and ([string]$p.displayName).Contains($Settings.alertTitle) -and @($p.scopes) -contains $Settings.workspaceId }
    $enabledCount = @(@($primary, $spare) | Where-Object { $_ -and $_.enabled }).Count
    $valid = (& $shape $primary) -and (& $shape $spare) -and $enabledCount -eq 1
    New-Check 'T12-alert' "$($Settings.groupId)/providers/Microsoft.Insights/scheduledQueryRules/$($Settings.alertName)" $(if ($valid) { 'pass' } else { 'fail' }) 'Two Sev2 rules on the ticketing workspace whose names contain the plan keyword, exactly one enabled' @{ primaryEnabled = [bool]($primary -and $primary.enabled); spareEnabled = [bool]($spare -and $spare.enabled) } 'Signal configuration only, not firing state. Exactly one rule must be on, or one failure opens two threads.'
    return @($checks.ToArray())
}

function Get-SreReleaseDeploymentParameters {
    <#
    .SYNOPSIS
    The parameter file body for infra/ticketing/main.bicep. Every name comes from the skin, so Deploy, readiness and the runner agree.
    #>
    param(
        [Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$Version, [AllowEmptyString()][string]$SiteWriterAssignmentName = '', [Parameter(Mandatory)][System.Collections.IDictionary]$Tags
    )
    $prefix = $Skin.azure.namePrefix
    $parameters = [ordered]@{
        sreLocation = @{ value = [string]$Skin.azure.location }
        workloadLocation = @{ value = $Settings.location }
        namePrefix = @{ value = $prefix }
        sreResourceGroupName = @{ value = "rg-$prefix-sre" }
        agentName = @{ value = [string]$Skin.labels.agentName }
        workloadResourceGroupName = @{ value = $Settings.resourceGroup }
        siteSuffix = @{ value = $Settings.siteSuffix }
        packageUrl = @{ value = (Get-SreReleasePackageUrl -Settings $Settings -Version $Version) }
        appServiceSkuName = @{ value = $Settings.sku }
        siteWriterAssignmentName = @{ value = $SiteWriterAssignmentName }
        tags = @{ value = $Tags }
    }
    [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    }
}

function ConvertFrom-SreMarkdownConfig {
    <#
    .SYNOPSIS
    Reads a config file made of optional leading HTML comment lines, a front matter block (key: value lines between two --- lines) and a body.
    #>
    param([Parameter(Mandatory)][string]$Text)
    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    $index = 0
    while ($index -lt $lines.Count -and ($lines[$index].Trim() -eq '' -or $lines[$index].TrimStart().StartsWith('<!--'))) { $index++ }
    if ($index -ge $lines.Count -or $lines[$index].Trim() -ne '---') { throw 'Config file has no front matter block.' }
    $meta = [ordered]@{}
    $index++
    while ($index -lt $lines.Count -and $lines[$index].Trim() -ne '---') {
        if ($lines[$index] -match '^([A-Za-z][A-Za-z0-9]*):\s*(.*)$') { $meta[$Matches[1]] = $Matches[2].Trim() }
        $index++
    }
    if ($index -ge $lines.Count) { throw 'Config file front matter is not closed.' }
    $body = if ($index + 1 -lt $lines.Count) { ($lines[($index + 1)..($lines.Count - 1)] -join "`n").Trim() } else { '' }
    [pscustomobject]@{ meta = $meta; body = $body }
}

function Read-SreReleaseConfigText {
    # Config text is stored with LF line endings on the agent, whatever the checkout uses, so a CRLF checkout does not show false drift.
    param([Parameter(Mandatory)][string]$RelativePath, [hashtable]$Tokens = @{})
    $path = Join-Path (Join-Path $PSScriptRoot '..\..\config\t12') $RelativePath
    $text = (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
    foreach ($key in $Tokens.Keys) { $text = $text.Replace("{$key}", [string]$Tokens[$key]) }
    $left = [regex]::Matches($text, '\{[A-Za-z][A-Za-z0-9]*\}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (@($left).Count) { throw "Config file $RelativePath still has unfilled tokens: $(@($left) -join ', ')." }
    return $text
}

function Get-SreReleaseDesired {
    <#
    .SYNOPSIS
    Renders everything the T12 scenario puts on the SRE agent from the skin and the files in config/t12. Nothing here calls Azure.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $settings = Get-SreReleaseSettings -Skin $Skin -SubscriptionId $SubscriptionId
    $repositoryName = ($settings.repository -split '/')[1]
    $tokens = @{
        appName = $settings.appName; appGroup = $settings.resourceGroup; workspaceId = $settings.workspaceId; alertName = $settings.alertName
        repository = $settings.repository; releaseUrlPrefix = "https://$script:GitHubHost/$($settings.repository)/releases/download/"
        repoClonePath = "/root/sreagent/terminalRoot/codeRefs/$repositoryName"
    }
    $skills = foreach ($name in @('azure-monitor-rca', 'github-issue-followup')) {
        $parsed = ConvertFrom-SreMarkdownConfig -Text (Read-SreReleaseConfigText -RelativePath "skills\$name.md" -Tokens $tokens)
        if ($parsed.meta['name'] -ne $name -or -not $parsed.meta['description'] -or -not $parsed.body) { throw "Skill file $name.md needs a matching name, a description and a body." }
        [ordered]@{ name = $name; description = [string]$parsed.meta['description']; content = $parsed.body }
    }
    $hook = ConvertFrom-SreMarkdownConfig -Text (Read-SreReleaseConfigText -RelativePath 'hooks\release-closing-check.md' -Tokens $tokens)
    if ($hook.meta['eventType'] -ne 'Stop' -or -not $hook.meta['name'] -or -not $hook.body) { throw 'The closing-check hook needs a name, eventType Stop and a prompt body.' }
    $policy = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\config\t12\tool-policy.json') -Raw | ConvertFrom-Json -AsHashtable
    [ordered]@{
        settings = $settings
        handler = @{
            name = $settings.handlerName; type = 'ExtendedAgent'; tags = @()
            properties = @{
                instructions = (Read-SreReleaseConfigText -RelativePath 'handler.instructions.txt' -Tokens $tokens).TrimEnd()
                handoffDescription = 'Review-mode investigation of ticketing checkout failures: finds the release behind them and proposes one redeploy of the last good version.'
                handoffs = @()
                tools = @('RunAzCliReadCommands', 'RunAzCliWriteCommands', 'QueryLogAnalyticsByWorkspaceId', 'SearchMemory', 'ReadFile', 'GrepSearch',
                    'FindConnectedGitHubRepo', 'FetchGithubIssue', 'FetchGithubIssuesLimited', 'CreateGithubIssue')
                enableSkills = $true
            }
        }
        plan = @{
            scenario = 'T12'; name = $settings.responsePlan; type = 'IncidentFilter'; tags = @()
            properties = @{
                incidentPlatform = 'AzMonitor'; priorities = @('Sev2'); titleContains = $settings.alertTitle
                impactedService = 'Azure App Service'; handlingAgent = $settings.handlerName
                agentMode = 'Review'; isEnabled = $true
                # Off, so a repeat failure opens a new thread instead of merging into a resolved one for hours. A live rehearsal confirms it.
                mergeEnabled = $false; mergeWindowHours = 3
            }
        }
        skills = @($skills)
        hook = [ordered]@{
            name = [string]$hook.meta['name']; description = [string]$hook.meta['description']; eventType = 'Stop'
            activationMode = [string]$hook.meta['activationMode']; timeout = [int]$hook.meta['timeout']; maxRejections = [int]$hook.meta['maxRejections']
            prompt = $hook.body
        }
        policy = @{ allow = @($policy.allow); ask = @($policy.ask); deny = @($policy.deny) }
        guard = [ordered]@{ marker = '[github-guard]'; text = (Read-SreReleaseConfigText -RelativePath 'github-guard.txt' -Tokens $tokens).Trim() }
        repository = [ordered]@{
            name = $repositoryName; url = "https://$script:GitHubHost/$($settings.repository)"; branch = 'main'
            description = 'Ticketing app source for the Friday release scenario'
        }
    }
}

Export-ModuleMember -Function Test-SreReleaseScenario, Get-SreReleaseSiteSuffix, Get-SreReleaseSettings, Assert-SreReleaseGroupOwnership, Get-SreReleasePackageUrl, Get-SreReleaseKnownGrants, Get-SreReleaseGrantsForSkin, Get-SreReleaseAppHost, Get-SreReleaseSummary, Get-SreReleaseReadinessChecks, Assert-SreReleaseQuota, Test-SreReleasePackage, Wait-SreReleaseHealthy, Get-SreReleaseDeploymentParameters, ConvertFrom-SreMarkdownConfig, Get-SreReleaseDesired
