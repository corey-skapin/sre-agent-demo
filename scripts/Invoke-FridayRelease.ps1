#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the T12 "Friday release" scenario: release a bad version of the ticketing app, watch the alert, the investigation and the Approve card, and reset.

.DESCRIPTION
    Start     Checks the app serves the last good release and the SRE agent is Active, starts background checkout traffic, waits a baseline,
              then points the web app at the bad release (WEBSITE_RUN_FROM_PACKAGE) with your own credentials.
    Status    Reads the app, the traffic log, the alert and the agent's thread, and records when each milestone first happened in
              .local\friday-release\current.json. With -Wait it keeps polling until the Approve card is pending. It never approves anything:
              a person clicks Approve in the SRE portal, and the agent's fix runs under the agent's own identity.
    Reset     Stops the traffic, puts the last good release back (unless the approved fix already did), waits until the app is healthy, and
              restores the alert rules. -DeleteThreads removes this run's investigation threads, and any stale Approve card with them.
              -SwapRules makes the spare alert rule the active one: use it if a repeat failure merges into an old thread instead of opening a new one.

    Use -WhatIf on Start or Reset to see what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Status', 'Reset')]
    [string]$Action,

    [string]$SkinPath = '',

    [ValidateRange(0, 30)]
    [int]$BaselineMinutes = 5,

    [switch]$Wait,

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 30,

    [switch]$DeleteThreads,

    [switch]$SwapRules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRelease.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreFridayRelease.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not (Test-SreReleaseScenario -Skin $skin)) { throw 'This skin does not require T12. See docs/t12-friday-release.md.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $SubscriptionId
$agentGroup = "rg-$($skin.azure.namePrefix)-sre"
$agentName = [string]$skin.labels.agentName

function Get-OptionalContext {
    # The data plane is optional for Status and Reset: without it the app, traffic and alert are still reported.
    try { return New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $agentGroup -AgentName $agentName -TimeoutSeconds 30 }
    catch { Write-Warning "The SRE agent's data plane is not reachable ($($_.Exception.Message)); thread and card details are skipped."; return $null }
}

function Read-Sources {
    param([Collections.IDictionary]$Run, $Context)
    $summary = Get-SreReleaseSummary -HostName $Run.host
    $since = if ($Run.events.ContainsKey('releaseApplied')) { [string]$Run.events.releaseApplied } else { [string]$Run.startedUtc }
    $traffic = Read-FridayTraffic -LogPath $Run.trafficLog -Since $since
    $alerts = Get-FridayAlertObservation -Alerts (Get-FridayAlerts -SubscriptionId $SubscriptionId -Settings $release) -Since $since -AlertTitle $release.alertTitle
    $thread = $null
    $messages = @()
    if ($Context -and $Run.events.ContainsKey('releaseApplied')) {
        $thread = Get-FridayThreadObservation -Threads (Get-SreThreads -Context $Context -Top 30) -Since $since -AlertTitle $release.alertTitle
        if ($thread.id) { $messages = @((Get-SreThreadMessages -Context $Context -ThreadId $thread.id).Messages) }
    }
    $version = if ($summary.reachable -and $summary.status -eq 200 -and $summary.version) { [string]$summary.version } else { $null }
    [pscustomobject]@{ summary = $summary; version = $version; traffic = $traffic; alerts = $alerts; thread = $thread; messages = $messages }
}

function Update-Run {
    param([Collections.IDictionary]$Run, $Sources)
    $servingTag = if ($Sources.version) { "v$($Sources.version)" } else { $null }
    $new = Update-FridayRun -Run $Run -Traffic $Sources.traffic -Alerts $Sources.alerts -Thread $Sources.thread -Messages $Sources.messages -ServingVersion $servingTag
    Save-FridayRun -RepoRoot $repoRoot -Run $Run
    return $new
}

function Read-RunRecord {
    # A record that cannot be read (for example a half-written file) is named as such. Reset moves it aside and carries on.
    param([switch]$MoveAside)
    try { return Read-FridayRun -RepoRoot $repoRoot }
    catch {
        $reason = $_.Exception.Message
        if (-not $MoveAside) { throw "The run record .local\friday-release\current.json cannot be read ($reason). Run -Action Reset: it moves the record aside and carries on." }
        $directory = Get-FridayDirectory -RepoRoot $repoRoot
        $aside = Join-Path $directory "unreadable-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
        Move-Item -LiteralPath (Join-Path $directory 'current.json') -Destination $aside -Force
        Write-Warning "The run record could not be read ($reason), so it was moved to $aside and Reset carries on without it. A traffic generator it started stops by itself within 2 hours."
        return $null
    }
}

function Assert-HealthyBaseline {
    # The app reports a failed checkout only when it receives one. Release the bad version only while this run's generator is alive and
    # its log shows recent checkouts that all returned 200; otherwise stop, so a bad release can never go unnoticed because nothing was calling it.
    param([Collections.IDictionary]$Run, [switch]$WaitForFirstCall)
    $health = if ($WaitForFirstCall) { Wait-FridayTraffic -Run $Run -TimeoutSeconds 45 } else { Get-FridayTrafficHealth -Run $Run }
    $problem = Get-FridayBaselineProblem -Health $health
    if (-not $problem) { return $health }
    Stop-FridayTraffic -Run $Run | Out-Null
    $Run.state = 'aborted'
    Save-FridayRun -RepoRoot $repoRoot -Run $Run
    throw "Nothing was released: $problem. Run -Action Reset, then start again."
}

switch ($Action) {
    'Start' {
        $existing = Read-RunRecord
        if ($existing -and $existing.state -eq 'running') { throw "A run is already in progress ($($existing.runId)). Run -Action Status, then -Action Reset." }
        $hostName = Get-SreReleaseAppHost -SubscriptionId $SubscriptionId -Settings $release
        $summary = Get-SreReleaseSummary -HostName $hostName
        if (-not ($summary.reachable -and $summary.status -eq 200 -and $summary.version -and "v$($summary.version)" -eq $release.goodVersion)) {
            throw "The app is not serving the last good release $($release.goodVersion) (it reports '$($summary.version)', HTTP $($summary.status)). Run -Action Reset first."
        }
        $states = Get-FridayRuleStates -SubscriptionId $SubscriptionId -Settings $release
        if (@($states.Values | Where-Object { $_ }).Count -ne 1) { throw "Exactly one alert rule must be enabled, or one failure opens two threads. States: $(($states.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')." }
        try { $null = New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $agentGroup -AgentName $agentName }
        catch { throw "The SRE agent is not ready, so a bad release would go unnoticed: $($_.Exception.Message) Wake it with Deploy-SreAgent.ps1 and check Test-SreReadiness.ps1 -DesiredState Active first." }
        if (-not $PSCmdlet.ShouldProcess($release.appName, "Start traffic, wait $BaselineMinutes min, then release $($release.badVersion) (WEBSITE_RUN_FROM_PACKAGE)")) { return }
        $run = New-FridayRun -RepoRoot $repoRoot -Settings $release -HostName $hostName
        $traffic = Start-FridayTraffic -RepoRoot $repoRoot -AppUrl "https://$hostName" -LogPath $run.trafficLog
        $run.trafficPid = $traffic.pid
        $run.trafficStartedUtc = $traffic.startedUtc
        Save-FridayRun -RepoRoot $repoRoot -Run $run
        Write-Host "Run $($run.runId): checkout traffic started against https://$hostName. Baseline: $BaselineMinutes min on $($release.goodVersion)."
        $null = Assert-HealthyBaseline -Run $run -WaitForFirstCall
        $baselineEnd = [DateTime]::UtcNow.AddMinutes($BaselineMinutes)
        while ([DateTime]::UtcNow -lt $baselineEnd) {
            Start-Sleep -Seconds ([Math]::Min(30, [Math]::Max(1, [int]($baselineEnd - [DateTime]::UtcNow).TotalSeconds)))
            $seen = Assert-HealthyBaseline -Run $run
            Write-Host ("  baseline: {0} checkouts, {1} not 200" -f $seen.total, $seen.failed)
        }
        $seen = Assert-HealthyBaseline -Run $run
        Write-Host ("Baseline proven: {0} checkouts, all 200, the last {1} s ago. Releasing {2}." -f $seen.total, $seen.lastAgeSeconds, $release.badVersion)
        Set-FridayPackage -SubscriptionId $SubscriptionId -Settings $release -Version $release.badVersion
        Set-FridayEvent -Run $run -Name releaseApplied -Utc ([DateTimeOffset]::UtcNow.ToString('o')) | Out-Null
        Save-FridayRun -RepoRoot $repoRoot -Run $run
        Write-Host "Released $($release.badVersion) at $(([DateTimeOffset]::Parse($run.events.releaseApplied, [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss'))Z. Waiting for the app to restart on it..."
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while ($true) {
            $sources = Read-Sources -Run $run -Context $null
            $null = Update-Run -Run $run -Sources $sources
            if (($run.events.ContainsKey('badServing') -and $run.events.ContainsKey('firstFailure')) -or [DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Seconds 10
        }
        Format-FridayRun -Run $run -Traffic $sources.traffic -ServingVersion $sources.version -ServingRelease $sources.summary.release | ForEach-Object { Write-Host $_ }
        if (-not $run.events.ContainsKey('firstFailure')) { Write-Warning 'The bad release has not produced a failed checkout yet. Check the app with -Action Status before you wait for the alert.' }
        Write-Host 'Next: Invoke-FridayRelease.ps1 -Action Status -Wait (the alert takes a few minutes; the card needs a person to click Approve in the SRE portal).'
    }
    'Status' {
        $run = Read-RunRecord
        if (-not $run) { throw 'No run is recorded. Start one with -Action Start.' }
        $context = Get-OptionalContext
        $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        do {
            $sources = Read-Sources -Run $run -Context $context
            foreach ($name in (Update-Run -Run $run -Sources $sources)) {
                Write-Host ("{0}Z  {1}" -f ([DateTimeOffset]::Parse($run.events[$name], [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss'), $name)
            }
            $waiting = @($run.cards.Values | Where-Object { $_.pendingUtc -and -not $_.finalStatus }).Count
            if (-not $Wait -or $waiting -gt 0 -or [DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Seconds 10
        } while ($true)
        Format-FridayRun -Run $run -Traffic $sources.traffic -ServingVersion $sources.version -ServingRelease $sources.summary.release | ForEach-Object { Write-Host $_ }
        if ($waiting -gt 0) { Write-Host 'An Approve card is waiting. Check what it would run, then a person clicks Approve in the SRE portal. This script never approves.' }
        elseif ($Wait) { Write-Warning "No Approve card appeared within $TimeoutMinutes min." }
    }
    'Reset' {
        $run = Read-RunRecord -MoveAside
        $context = Get-OptionalContext
        $configured = Get-FridayPackageVersion -SubscriptionId $SubscriptionId -Settings $release
        $rules = Get-FridayRuleStates -SubscriptionId $SubscriptionId -Settings $release
        $primary = $release.alertName
        $spare = $release.spareAlertName
        $activeNow = @($rules.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
        $wantActive = if ($SwapRules) { $(if ($activeNow -contains $primary) { $spare } else { $primary }) } else { $primary }
        $runThreads = @()
        if ($run -and $context) {
            $since = if ($run.events.ContainsKey('releaseApplied')) { [string]$run.events.releaseApplied } else { [string]$run.startedUtc }
            $runThreads = @((Get-FridayThreadObservation -Threads (Get-SreThreads -Context $context -Top 50) -Since $since -AlertTitle $release.alertTitle).all)
        }
        $plan = @(
            "traffic: $(if ($run -and $run.trafficPid) { "stop the generator started by run $($run.runId)" } else { 'none recorded' })"
            "app: configured release $(if ($configured) { $configured } else { 'unknown' }) -> $($release.goodVersion)"
            "alert rules: active $($activeNow -join ',') -> $wantActive"
            "threads: $(if ($DeleteThreads) { "delete $($runThreads.Count) from this run" } else { "keep (use -DeleteThreads to remove $($runThreads.Count) and any stale Approve card)" })"
        )
        $plan | ForEach-Object { Write-Host "  $_" }
        if (-not $PSCmdlet.ShouldProcess($release.appName, 'Reset the Friday release scenario')) { return }
        if ($run -and (Stop-FridayTraffic -Run $run)) { Write-Host 'Traffic stopped.' }
        if ($configured -ne $release.goodVersion) {
            Set-FridayPackage -SubscriptionId $SubscriptionId -Settings $release -Version $release.goodVersion
            Write-Host "Set WEBSITE_RUN_FROM_PACKAGE to $($release.goodVersion)."
        } else {
            Write-Host "The app is already configured for $($release.goodVersion) (the approved fix, or an earlier reset)."
        }
        $hostName = Get-SreReleaseAppHost -SubscriptionId $SubscriptionId -Settings $release
        $null = Wait-SreReleaseHealthy -HostName $hostName -Version $release.goodVersion -TimeoutSeconds 600
        Write-Host "The app serves $($release.goodVersion) again."
        if ($wantActive -notin $activeNow) {
            Set-FridayRuleEnabled -SubscriptionId $SubscriptionId -Settings $release -RuleName $wantActive -Enabled $true
            Write-Host "Alert rule $wantActive enabled."
        }
        foreach ($name in $activeNow | Where-Object { $_ -ne $wantActive }) {
            Set-FridayRuleEnabled -SubscriptionId $SubscriptionId -Settings $release -RuleName $name -Enabled $false
            Write-Host "Alert rule $name disabled."
        }
        $deleted = 0
        if ($DeleteThreads -and $context) {
            foreach ($thread in $runThreads) {
                if ($PSCmdlet.ShouldProcess($thread.id, 'Delete the investigation thread (a pending Approve card goes with it)')) {
                    $response = Remove-SreThread -Context $context -ThreadId $thread.id -Confirm:$false
                    if ($response.Status -ge 200 -and $response.Status -lt 300) { $deleted++ } else { Write-Warning "Thread $($thread.id) was not deleted (HTTP $($response.Status))." }
                }
            }
        } elseif (-not $DeleteThreads -and $run) {
            $stale = @($run.cards.Values | Where-Object { $_.pendingUtc -and -not $_.finalStatus }).Count
            if ($stale) { Write-Warning "A run card was still pending when you reset. It is stale: never approve it. Delete its thread with -DeleteThreads." }
        }
        if ($run) {
            $run.state = 'reset'
            $run.resetUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-FridayRun -RepoRoot $repoRoot -Run $run
            $directory = Get-FridayDirectory -RepoRoot $repoRoot
            Move-Item -LiteralPath (Join-Path $directory 'current.json') -Destination (Join-Path $directory "run-$($run.runId).json") -Force
        }
        Write-Host "Reset complete: app on $($release.goodVersion), active alert rule $wantActive, $deleted thread(s) deleted. The next run starts clean."
    }
}
