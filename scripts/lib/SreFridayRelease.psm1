Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRelease.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreDataPlane.psm1')

# Helpers for Invoke-FridayRelease.ps1, the scenario runner for T12 (Start a bad release, Status, Reset).
# Pure helpers take data in and return data out so the offline tests can feed them recorded shapes; the few Azure calls are small and named.

$script:EventOrder = @('releaseApplied', 'badServing', 'firstFailure', 'alertFired', 'threadCreated', 'firstAgentMessage', 'cardPending', 'cardCompleted', 'healthyAgain', 'alertResolved')
$script:EventLabels = @{
    releaseApplied = 'bad release applied'; badServing = 'bad release serving'; firstFailure = 'first failed checkout'; alertFired = 'alert fired'
    threadCreated = 'investigation thread created'; firstAgentMessage = 'first agent message'; cardPending = 'Approve card pending'
    cardCompleted = 'card completed (first seen)'; healthyAgain = 'checkout healthy again'; alertResolved = 'alert resolved'
}

function Get-FridayDirectory {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $directory = Join-Path $RepoRoot '.local\friday-release'
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    return $directory
}

function Read-FridayRun {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path (Get-FridayDirectory -RepoRoot $RepoRoot) 'current.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $run = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    # ConvertFrom-Json turns ISO strings into local DateTime values. Put every time back to a UTC ISO string, so each parse downstream is culture- and zone-proof.
    foreach ($key in 'startedUtc', 'trafficStartedUtc', 'resetUtc') { if ($run.ContainsKey($key)) { $run[$key] = ConvertTo-FridayUtc $run[$key] } }
    foreach ($name in @($run.events.Keys)) { $run.events[$name] = ConvertTo-FridayUtc $run.events[$name] }
    foreach ($card in @($run.cards.Values)) { foreach ($key in 'pendingUtc', 'finalUtc') { if ($card.ContainsKey($key)) { $card[$key] = ConvertTo-FridayUtc $card[$key] } } }
    return $run
}

function Save-FridayRun {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][Collections.IDictionary]$Run)
    $path = Join-Path (Get-FridayDirectory -RepoRoot $RepoRoot) 'current.json'
    # Write beside the record and rename over it, so a crash mid-write cannot leave a truncated current.json that blocks Start, Status and Reset.
    $temporary = "$path.tmp"
    [IO.File]::WriteAllText($temporary, ($Run | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    # The run record is local bookkeeping, written whatever -WhatIf says (the direct write above always was), so the rename must not be skipped either.
    Move-Item -LiteralPath $temporary -Destination $path -Force -WhatIf:$false -Confirm:$false
}

function New-FridayRun {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$HostName)
    $started = [DateTimeOffset]::UtcNow
    $runId = $started.ToString('yyyyMMddTHHmmssZ')
    @{
        runId = $runId; state = 'running'; startedUtc = $started.ToString('o'); host = $HostName
        goodVersion = $Settings.goodVersion; badVersion = $Settings.badVersion
        trafficLog = Join-Path (Get-FridayDirectory -RepoRoot $RepoRoot) "traffic-$runId.csv"
        trafficPid = $null; trafficStartedUtc = $null
        events = @{}; cards = @{}; threadId = $null
    }
}

function Set-FridayEvent {
    # Records the first time an event is seen. Returns $true when it is new.
    param([Parameter(Mandatory)][Collections.IDictionary]$Run, [Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Utc)
    if ($Name -notin $script:EventOrder) { throw "Unknown run event '$Name'." }
    if ([string]::IsNullOrWhiteSpace($Utc) -or $Run.events.ContainsKey($Name)) { return $false }
    $Run.events[$Name] = ([DateTimeOffset]::Parse($Utc, [Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime().ToString('o')
    return $true
}

function Read-FridayTraffic {
    <#
    .SYNOPSIS
    Summarises the traffic log: counts, the first failure after Since, and when the trailing run of successes began.
    #>
    param([Parameter(Mandatory)][string]$LogPath, [AllowNull()][string]$Since = $null, [ValidateRange(1, 100)][int]$HealthyRun = 5)
    $empty = [pscustomobject]@{ total = 0; failed = 0; firstFailureUtc = $null; lastStatus = $null; lastUtc = $null; healthySinceUtc = $null }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $empty }
    # The generator appends to this file while it is read. Retry a read that collides with a write instead of failing the run.
    $csv = $null
    for ($attempt = 1; $attempt -le 3 -and $null -eq $csv; $attempt++) {
        try { $csv = @(Import-Csv -LiteralPath $LogPath -ErrorAction Stop) } catch { if ($attempt -eq 3) { throw }; Start-Sleep -Milliseconds 150 }
    }
    $rows = @($csv | ForEach-Object { [pscustomobject]@{ utc = [DateTimeOffset]::Parse($_.utc, [Globalization.CultureInfo]::InvariantCulture); status = [int]$_.status } })
    if ($Since) { $floor = [DateTimeOffset]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture); $rows = @($rows | Where-Object { $_.utc -ge $floor }) }
    if (-not $rows.Count) { return $empty }
    $failures = @($rows | Where-Object { $_.status -ne 200 })
    $trailing = 0
    for ($i = $rows.Count - 1; $i -ge 0 -and $rows[$i].status -eq 200; $i--) { $trailing++ }
    $healthySince = if ($failures.Count -and $trailing -ge $HealthyRun) { $rows[$rows.Count - $trailing].utc.ToString('o') } else { $null }
    [pscustomobject]@{
        total = $rows.Count; failed = $failures.Count
        firstFailureUtc = $(if ($failures.Count) { $failures[0].utc.ToString('o') } else { $null })
        lastStatus = $rows[-1].status; lastUtc = $rows[-1].utc.ToString('o'); healthySinceUtc = $healthySince
    }
}

function Start-FridayTraffic {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$AppUrl, [Parameter(Mandatory)][string]$LogPath, [int]$IntervalSeconds = 3, [int]$DurationSeconds = 7200)
    $script = Join-Path $RepoRoot 'scripts\Send-ReleaseTraffic.ps1'
    # Start-Process joins an argument array with spaces and does not quote it, so both paths are quoted: a repo path with a space would otherwise split.
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', "`"$script`"", '-AppUrl', $AppUrl, '-LogPath', "`"$LogPath`"", '-IntervalSeconds', $IntervalSeconds, '-DurationSeconds', $DurationSeconds)
    [pscustomobject]@{ pid = $process.Id; startedUtc = $process.StartTime.ToUniversalTime().ToString('o') }
}

function Get-FridayTrafficProcess {
    # The process recorded for this run, or $null when there is none. isGenerator is false when that PID now belongs to something else:
    # it must have the recorded start time and still be a PowerShell host.
    param([Parameter(Mandatory)][Collections.IDictionary]$Run)
    if (-not $Run['trafficPid']) { return $null }
    $process = Get-Process -Id ([int]$Run['trafficPid']) -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    $ours = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Run['trafficStartedUtc'])) {
        $started = [DateTimeOffset]::Parse([string]$Run['trafficStartedUtc'], [Globalization.CultureInfo]::InvariantCulture)
        $ours = [Math]::Abs(($process.StartTime.ToUniversalTime() - $started.UtcDateTime).TotalSeconds) -le 5 -and $process.ProcessName -match '^(pwsh|powershell)'
    }
    [pscustomobject]@{ process = $process; isGenerator = [bool]$ours }
}

function Stop-FridayTraffic {
    # Stops only the process this run started: same PID, same start time, still a PowerShell host.
    param([Parameter(Mandatory)][Collections.IDictionary]$Run)
    $found = Get-FridayTrafficProcess -Run $Run
    if (-not $found) { return $false }
    if (-not $found.isGenerator) {
        Write-Warning "Process $($Run['trafficPid']) is not the traffic generator this run started; leaving it alone."
        return $false
    }
    Stop-Process -Id $found.process.Id -Force
    return $true
}

function Get-FridayTrafficHealth {
    # Reads only: is this run's generator alive, and what has it logged so far (calls, failures, seconds since the last call)?
    param([Parameter(Mandatory)][Collections.IDictionary]$Run, [string]$NowUtc = ([DateTimeOffset]::UtcNow.ToString('o')))
    $found = Get-FridayTrafficProcess -Run $Run
    $log = Read-FridayTraffic -LogPath ([string]$Run['trafficLog'])
    $age = $null
    if ($log.lastUtc) { $age = [int][Math]::Max(0, ([DateTimeOffset]::Parse($NowUtc, [Globalization.CultureInfo]::InvariantCulture) - [DateTimeOffset]::Parse($log.lastUtc, [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds) }
    [pscustomobject]@{ alive = [bool]($found -and $found.isGenerator); total = $log.total; failed = $log.failed; lastAgeSeconds = $age }
}

function Wait-FridayTraffic {
    # Waits for the generator to log its first call. Returns at once when it has died, because nothing will ever arrive.
    param([Parameter(Mandatory)][Collections.IDictionary]$Run, [ValidateRange(1, 300)][int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $health = Get-FridayTrafficHealth -Run $Run
        if (-not $health.alive -or $health.total -ge 1) { return $health }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $health
}

function Get-FridayBaselineProblem {
    <#
    .SYNOPSIS
    Why the run must not release the bad version yet, or $null. The app reports a failed checkout only when it receives one, so a generator that is
    not running, has logged nothing or has gone quiet means a bad release would raise no failure, no alert and no thread.
    #>
    param([Parameter(Mandatory)]$Health, [ValidateRange(10, 600)][int]$MaxAgeSeconds = 60)
    if (-not $Health.alive) { return 'the traffic generator is not running' }
    if ($Health.total -lt 1) { return 'the traffic generator has logged no checkouts' }
    if ($Health.lastAgeSeconds -gt $MaxAgeSeconds) { return "the traffic generator's last checkout was $($Health.lastAgeSeconds) s ago" }
    if ($Health.failed -gt 0) { return "$($Health.failed) of $($Health.total) checkouts were not 200 before the release" }
    return $null
}

function Set-FridayPackage {
    <#
    .SYNOPSIS
    Points the web app at a release package (WEBSITE_RUN_FROM_PACKAGE) with your own credentials. The app restarts.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Version)
    $url = Get-SreReleasePackageUrl -Settings $Settings -Version $Version
    # -o none: the command would otherwise print every app setting, including the telemetry connection string.
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'config', 'appsettings', 'set', '--resource-group', $Settings.resourceGroup, '--name', $Settings.appName, '--settings', "WEBSITE_RUN_FROM_PACKAGE=$url", '-o', 'none') | Out-Null
}

function Get-FridayPackageVersion {
    # The version the app is configured to run from, read from its WEBSITE_RUN_FROM_PACKAGE setting.
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $json = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'config', 'appsettings', 'list', '--resource-group', $Settings.resourceGroup, '--name', $Settings.appName, '-o', 'json')
    $setting = @($json | ConvertFrom-Json | Where-Object { $_.name -eq 'WEBSITE_RUN_FROM_PACKAGE' })
    if (-not $setting.Count) { return $null }
    $match = [regex]::Match([string]$setting[0].value, '/releases/download/(v\d+\.\d+\.\d+)/')
    if ($match.Success) { return $match.Groups[1].Value } else { return $null }
}

function Get-FridayAlerts {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&targetResourceGroup=$($Settings.resourceGroup)&timeRange=1d&sortBy=startDateTime&sortOrder=desc"
    @((Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json).value)
}

function ConvertTo-FridayUtc {
    # Service JSON arrives as strings or, after ConvertFrom-Json, as local DateTime values. Either way the run record keeps one UTC ISO form.
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o') }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString('o')
}

function Get-FridayAlertObservation {
    param([AllowNull()][object[]]$Alerts, [Parameter(Mandatory)][string]$Since, [Parameter(Mandatory)][string]$AlertTitle)
    $floor = [DateTimeOffset]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture)
    $mine = @(foreach ($alert in @($Alerts)) {
        $essentials = Get-SreProperty (Get-SreProperty $alert 'properties') 'essentials'
        if (-not $essentials) { continue }
        $rule = [string](Get-SreProperty $essentials 'alertRule')
        $started = ConvertTo-FridayUtc (Get-SreProperty $essentials 'startDateTime')
        if ($rule -notlike "*$AlertTitle*" -or -not $started -or [DateTimeOffset]::Parse($started, [Globalization.CultureInfo]::InvariantCulture) -lt $floor) { continue }
        [pscustomobject]@{
            rule = ($rule -split '/')[-1]; startedUtc = $started; condition = [string](Get-SreProperty $essentials 'monitorCondition')
            state = [string](Get-SreProperty $essentials 'alertState'); resolvedUtc = (ConvertTo-FridayUtc (Get-SreProperty $essentials 'monitorConditionResolvedDateTime'))
        }
    })
    $first = $mine | Sort-Object { [DateTimeOffset]::Parse($_.startedUtc, [Globalization.CultureInfo]::InvariantCulture) } | Select-Object -First 1
    $allResolved = $mine.Count -gt 0 -and @($mine | Where-Object { $_.condition -ne 'Resolved' }).Count -eq 0
    $resolved = if ($allResolved) { ($mine | ForEach-Object { $_.resolvedUtc } | Where-Object { $_ } | Sort-Object { [DateTimeOffset]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) } | Select-Object -Last 1) } else { $null }
    [pscustomobject]@{ count = $mine.Count; firedUtc = $(if ($first) { $first.startedUtc } else { $null }); rule = $(if ($first) { $first.rule } else { $null }); states = @($mine | ForEach-Object { "$($_.condition)/$($_.state)" }); resolvedUtc = $resolved }
}

function Get-FridayThreadObservation {
    param([AllowNull()][object[]]$Threads, [Parameter(Mandatory)][string]$Since, [Parameter(Mandatory)][string]$AlertTitle)
    $floor = [DateTimeOffset]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture)
    $mine = @(foreach ($thread in @($Threads)) {
        $created = ConvertTo-FridayUtc (Get-SreProperty $thread 'createdTimestamp')
        $title = [string](Get-SreProperty $thread 'title')
        if (-not $created -or $title -notlike "*$AlertTitle*" -or [DateTimeOffset]::Parse($created, [Globalization.CultureInfo]::InvariantCulture) -lt $floor) { continue }
        [pscustomobject]@{ id = [string](Get-SreProperty $thread 'id'); createdUtc = $created; title = $title }
    })
    $first = $mine | Sort-Object { [DateTimeOffset]::Parse($_.createdUtc, [Globalization.CultureInfo]::InvariantCulture) } | Select-Object -First 1
    [pscustomobject]@{ count = $mine.Count; id = $(if ($first) { $first.id } else { $null }); createdUtc = $(if ($first) { $first.createdUtc } else { $null }); all = @($mine) }
}

function Get-FridayClip {
    param([AllowNull()]$Value, [int]$Length = 300)
    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [string]) { $Value } else { $Value | ConvertTo-Json -Compress -Depth 5 }
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt $Length) { return $text.Substring(0, $Length) + '...' }
    return $text
}

function Get-FridayCards {
    <#
    .SYNOPSIS
    Every approval card in a thread's messages (Azure CLI write cards and permission-rule cards), with status and what it would run. Reads only.
    #>
    param([AllowNull()][object[]]$Messages)
    foreach ($message in @($Messages)) {
        $cli = Get-SreProperty $message 'azCliExecution'
        if ($cli) {
            [pscustomobject]@{ id = [string](Get-SreProperty $cli 'id'); kind = 'azure-write'; status = [string](Get-SreProperty $cli 'status')
                createdUtc = (ConvertTo-FridayUtc (Get-SreProperty $cli 'createdTimestamp')); summary = [string](Get-SreProperty $cli 'description'); command = (Get-FridayClip (Get-SreProperty $cli 'originalFunctionCall')) }
        }
        $approval = Get-SreProperty $message 'approval'
        if ($approval) {
            $display = Get-SreProperty $approval 'display'
            $parameters = @(Get-SreProperty $display 'parameters' | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.name)=$(Get-FridayClip $_.value 80)" }) -join '; '
            [pscustomobject]@{ id = [string](Get-SreProperty $approval 'id'); kind = 'permission-rule'; status = [string](Get-SreProperty $approval 'status')
                createdUtc = (ConvertTo-FridayUtc (Get-SreProperty $approval 'createdTimestamp')); summary = [string](Get-SreProperty $display 'toolName'); command = $parameters }
        }
    }
}

function Update-FridayRun {
    <#
    .SYNOPSIS
    Folds what the sources show into the run record: the first time each event is seen, and each card's first-pending and final status.
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Run, [AllowNull()]$Traffic, [AllowNull()]$Alerts, [AllowNull()]$Thread,
        [AllowNull()][object[]]$Messages, [AllowNull()][string]$ServingVersion, [string]$ObservedUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
    )
    $new = [Collections.Generic.List[string]]::new()
    $note = { param($name, $utc) if (Set-FridayEvent -Run $Run -Name $name -Utc $utc) { $new.Add($name) } }
    if ($Run.events.ContainsKey('releaseApplied') -and $ServingVersion -and $ServingVersion -eq $Run.badVersion) { & $note 'badServing' $ObservedUtc }
    if ($Traffic -and $Traffic.firstFailureUtc -and $Run.events.ContainsKey('releaseApplied') -and [DateTimeOffset]::Parse($Traffic.firstFailureUtc, [Globalization.CultureInfo]::InvariantCulture) -ge [DateTimeOffset]::Parse($Run.events.releaseApplied, [Globalization.CultureInfo]::InvariantCulture)) { & $note 'firstFailure' $Traffic.firstFailureUtc }
    if ($Traffic -and $Traffic.healthySinceUtc -and $Run.events.ContainsKey('firstFailure') -and $Run.events.ContainsKey('badServing')) { & $note 'healthyAgain' $Traffic.healthySinceUtc }
    if ($Alerts -and $Alerts.firedUtc) { & $note 'alertFired' $Alerts.firedUtc }
    if ($Alerts -and $Alerts.resolvedUtc -and $Run.events.ContainsKey('alertFired')) { & $note 'alertResolved' $Alerts.resolvedUtc }
    if ($Thread -and $Thread.id) {
        $Run.threadId = $Thread.id
        & $note 'threadCreated' $Thread.createdUtc
        $agentMessages = @(@($Messages) | Where-Object { [string](Get-SreProperty (Get-SreProperty $_ 'author') 'role') -eq 'SREAgent' })
        if ($agentMessages.Count) { & $note 'firstAgentMessage' (ConvertTo-FridayUtc (Get-SreProperty $agentMessages[0] 'timeStamp')) }
        foreach ($card in @(Get-FridayCards -Messages $Messages)) {
            if (-not $card.id) { continue }
            if (-not $Run.cards.ContainsKey($card.id)) {
                # The agent's read-only commands appear as messages too, and nobody decides on those. Track a card that waited, a permission-rule card, or a write.
                $isWrite = $card.kind -eq 'permission-rule' -or $card.command -match 'RunAzCliWriteCommands|appsettings\s+set'
                if ($card.status -ne 'Pending' -and -not $isWrite) { continue }
                $Run.cards[$card.id] = @{ kind = $card.kind; summary = $card.summary; command = $card.command; pendingUtc = $null; finalStatus = $null; finalUtc = $null }
            }
            $record = $Run.cards[$card.id]
            if ($card.status -eq 'Pending') {
                if (-not $record.pendingUtc) { $record.pendingUtc = $(if ($card.createdUtc) { $card.createdUtc } else { $ObservedUtc }) }
                $record.command = $card.command
                & $note 'cardPending' $record.pendingUtc
                continue
            }
            # Decided. A card first seen this way began to wait when it was created, so that is its pending time; with no creation time there is none to claim.
            if (-not $record.pendingUtc -and $card.createdUtc) { $record.pendingUtc = $card.createdUtc; & $note 'cardPending' $record.pendingUtc }
            if ($record.finalUtc) { continue }
            $record.finalStatus = $(if ($card.status) { $card.status } else { 'Unknown' })
            # Running means a person approved it and it is executing; keep reading until it finishes.
            if ($card.status -eq 'Running') { continue }
            $record.finalUtc = $ObservedUtc
            if ($card.status -eq 'Completed') { & $note 'cardCompleted' $ObservedUtc }
        }
    }
    return @($new.ToArray())
}

function Format-FridayRun {
    param([Parameter(Mandatory)][Collections.IDictionary]$Run, [AllowNull()]$Traffic, [AllowNull()][string]$ServingVersion, [AllowNull()][string]$ServingRelease)
    $lines = [Collections.Generic.List[string]]::new()
    $started = [DateTimeOffset]::Parse($Run.startedUtc, [Globalization.CultureInfo]::InvariantCulture)
    $zero = if ($Run.events.ContainsKey('releaseApplied')) { [DateTimeOffset]::Parse($Run.events.releaseApplied, [Globalization.CultureInfo]::InvariantCulture) } else { $null }
    $serving = if ($ServingVersion) { "serves v$ServingVersion$(if ($ServingRelease) { " (release $ServingRelease)" })" } else { 'is not answering' }
    $lines.Add("Run $($Run.runId) ($($Run.state)) since $($started.ToString('HH:mm:ss'))Z; the app $serving; good $($Run.goodVersion), bad $($Run.badVersion).")
    if ($Traffic) { $lines.Add("Traffic: $($Traffic.total) checkouts, $($Traffic.failed) not 200; last status $($Traffic.lastStatus).") }
    foreach ($name in $script:EventOrder) {
        if ($Run.events.ContainsKey($name)) {
            $at = [DateTimeOffset]::Parse($Run.events[$name], [Globalization.CultureInfo]::InvariantCulture)
            $delta = if ($zero) { $d = $at - $zero; $abs = $d.Duration(); ' ({0}{1}m{2:00}s)' -f $(if ($d.TotalSeconds -lt 0) { '-' } else { '+' }), [int][Math]::Floor($abs.TotalMinutes), $abs.Seconds } else { '' }
            $lines.Add(('  {0,-30} {1}Z{2}' -f $script:EventLabels[$name], $at.ToString('HH:mm:ss'), $delta))
        } else {
            $lines.Add(('  {0,-30} -' -f $script:EventLabels[$name]))
        }
    }
    foreach ($id in $Run.cards.Keys) {
        $card = $Run.cards[$id]
        $state = if ($card.finalStatus) { $card.finalStatus } else { 'Pending' }
        $lines.Add("  card [$state] $($card.kind): $($card.summary) $($card.command)".TrimEnd())
    }
    return @($lines.ToArray())
}

function Get-FridayRuleStates {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $states = [ordered]@{}
    foreach ($name in @($Settings.alertName, $Settings.spareAlertName)) {
        $id = "$($Settings.groupId)/providers/Microsoft.Insights/scheduledQueryRules/$name"
        $states[$name] = [bool]((Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'show', '--ids', $id, '-o', 'json') | ConvertFrom-Json).properties.enabled)
    }
    return $states
}

function Set-FridayRuleEnabled {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$RuleName, [Parameter(Mandatory)][bool]$Enabled)
    if ($RuleName -notin @($Settings.alertName, $Settings.spareAlertName)) { throw "Refusing to change '$RuleName': it is not one of this scenario's two alert rules." }
    $url = "https://management.azure.com$($Settings.groupId)/providers/Microsoft.Insights/scheduledQueryRules/${RuleName}?api-version=2023-03-15-preview"
    $file = Join-Path ([IO.Path]::GetTempPath()) "friday-rule-$(Get-Random).json"
    try {
        [IO.File]::WriteAllText($file, (@{ properties = @{ enabled = $Enabled } } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'patch', '--url', $url, '--body', "@$file", '-o', 'none') | Out-Null
    } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Get-FridayDirectory, Read-FridayRun, Save-FridayRun, New-FridayRun, Set-FridayEvent, Read-FridayTraffic, Start-FridayTraffic, Stop-FridayTraffic,
    Get-FridayTrafficProcess, Get-FridayTrafficHealth, Wait-FridayTraffic, Get-FridayBaselineProblem, Set-FridayPackage, Get-FridayPackageVersion, Get-FridayAlerts, ConvertTo-FridayUtc, Get-FridayAlertObservation, Get-FridayThreadObservation, Get-FridayCards, Update-FridayRun, Format-FridayRun,
    Get-FridayRuleStates, Set-FridayRuleEnabled
