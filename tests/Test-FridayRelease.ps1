#Requires -Version 7.4
# Offline checks for the T12 scenario runner (Invoke-FridayRelease.ps1 and its helpers): the run record, traffic log, alert and thread
# observation, event folding, the status report, the az calls the runner makes, and the real script against a copy of the repo scripts.
# Every Azure and web call is mocked; the traffic generator is never started against a real host.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
foreach ($module in 'DemoSkin', 'SreRuntime', 'SreRelease', 'SreDataPlane', 'SreFridayRelease') { Import-Module (Join-Path $root "scripts\lib\$module.psm1") -Force }
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$githubHost = 'github.com'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Friday runner assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}

$previousResponder = $global:AzResponder
$previousExit = $global:AzExitCode
$temps = [Collections.Generic.List[string]]::new()
$child = $null
$fixture = $null
function New-TempDirectory {
    param([string]$Prefix = 'friday-')
    $path = Join-Path ([IO.Path]::GetTempPath()) "$Prefix$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $path | Out-Null
    $temps.Add($path)
    $path
}
function global:Read-SharedLines([string]$Path) {
    # The traffic generator keeps appending to its log, so read it the way it allows. Global, because the az mock calls it.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return @(([IO.StreamReader]::new($stream)).ReadToEnd() -split "`r?`n" | Where-Object { $_ }) } finally { $stream.Dispose() }
}
try {
    $skinPath = New-TestT12SkinFile -Root $root
    $temps.Add($skinPath)
    $skin = Get-DemoSkin -Path $skinPath -RepoRoot $root
    $settings = Get-SreReleaseSettings -Skin $skin -SubscriptionId $subscription
    $primary = $settings.alertName
    $spare = $settings.spareAlertName
    $t0 = [DateTimeOffset]::Parse('2026-11-12T00:00:00Z')
    $at = { param([int]$seconds) $t0.AddSeconds($seconds).ToString('o') }

    # --- Run record -------------------------------------------------------------------------------------------------------------------
    $repo = New-TempDirectory
    Check ($null -eq (Read-FridayRun -RepoRoot $repo)) 'No run is recorded at first'
    $run = New-FridayRun -RepoRoot $repo -Settings $settings -HostName 'app.azurewebsites.net'
    Check ($run.state -ceq 'running' -and $run.goodVersion -ceq 'v1.2.0' -and $run.badVersion -ceq 'v1.3.0' -and $run.host -ceq 'app.azurewebsites.net' -and $run.runId -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$') 'A new run records the versions, the host and an ID'
    Check ($run.trafficLog -ceq (Join-Path $repo ".local\friday-release\traffic-$($run.runId).csv") -and $null -eq $run.trafficPid) 'The traffic log lives in the ignored .local folder; no generator yet'
    # CI once failed because a Start in the same second as an earlier run reused that run's traffic log, and the old rows in it passed for fresh traffic.
    $burst = @(1..20 | ForEach-Object { New-FridayRun -RepoRoot $repo -Settings $settings -HostName 'app.azurewebsites.net' })
    Check (@($burst | ForEach-Object { $_.runId } | Select-Object -Unique).Count -eq 20 -and @($burst | ForEach-Object { $_.trafficLog } | Select-Object -Unique).Count -eq 20) 'Runs created in the same second get different IDs and different traffic logs'
    Save-FridayRun -RepoRoot $repo -Run $run
    $back = Read-FridayRun -RepoRoot $repo
    Check ($back.runId -ceq $run.runId -and $back.events -is [hashtable] -and $back.cards -is [hashtable]) 'A run round-trips through its JSON file with its tables intact'
    Save-FridayRun -RepoRoot $repo -Run $run
    Check (-not (Test-Path -LiteralPath (Join-Path $repo '.local\friday-release\current.json.tmp')) -and (Read-FridayRun -RepoRoot $repo).runId -ceq $run.runId) 'The record is written beside itself and renamed over, so no half-written file or temporary copy is left'
    $ignored = (Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -split "`r?`n"
    Check ('.local/' -in $ignored -or '.local' -in $ignored) 'The run record folder is git-ignored'

    # --- Events -----------------------------------------------------------------------------------------------------------------------
    $record = @{ events = @{} }
    Check (Set-FridayEvent -Run $record -Name alertFired -Utc (& $at 60)) 'The first sighting of an event is new'
    Check (-not (Set-FridayEvent -Run $record -Name alertFired -Utc (& $at 120)) -and $record.events.alertFired -ceq (& $at 60)) 'A later sighting never moves it'
    Check (-not (Set-FridayEvent -Run $record -Name threadCreated -Utc '') -and -not (Set-FridayEvent -Run $record -Name threadCreated -Utc $null) -and -not $record.events.ContainsKey('threadCreated')) 'A blank time records nothing'
    Throws { Set-FridayEvent -Run $record -Name nonsense -Utc (& $at 1) } 'Unknown run event'
    $zone = @{ events = @{} }
    $null = Set-FridayEvent -Run $zone -Name alertFired -Utc '2026-11-12T10:30:00+10:30'
    Check ($zone.events.alertFired -ceq (& $at 0)) 'Times are stored in UTC'
    Check ((ConvertTo-FridayUtc ([DateTime]::new(2026, 11, 12, 0, 8, 0, [DateTimeKind]::Utc))) -ceq (& $at 480) -and (ConvertTo-FridayUtc ([DateTime]::new(2026, 11, 12, 0, 8, 0, [DateTimeKind]::Utc).ToLocalTime())) -ceq (& $at 480)) 'A DateTime from parsed JSON is converted by its kind, in any time zone'
    Check ((ConvertTo-FridayUtc '2026-11-12T00:08:00') -ceq (& $at 480) -and (ConvertTo-FridayUtc '2026-11-12T00:08:00Z') -ceq (& $at 480) -and $null -eq (ConvertTo-FridayUtc '') -and $null -eq (ConvertTo-FridayUtc $null)) 'A time without an offset is taken as UTC; blank is nothing'

    # --- Traffic log ------------------------------------------------------------------------------------------------------------------
    $trafficScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Send-ReleaseTraffic.ps1') -Raw
    Check ($trafficScript.Contains("'utc,status,ms'")) 'The traffic script writes the header the runner reads'
    $csv = Join-Path $repo 'traffic.csv'
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('utc,status,ms')
    foreach ($second in 0, 3, 6, 9, 12, 15, 18, 21, 24, 27) { $lines.Add("$(& $at $second),200,95") }
    foreach ($second in 30, 33, 36, 39, 42) { $lines.Add("$(& $at $second),500,310") }
    $lines.Add("$(& $at 45),-1,20000")
    foreach ($second in 48, 51, 54, 57, 60, 63) { $lines.Add("$(& $at $second),200,101") }
    [IO.File]::WriteAllLines($csv, $lines)
    $traffic = Read-FridayTraffic -LogPath $csv
    Check ($traffic.total -eq 22 -and $traffic.failed -eq 6 -and $traffic.firstFailureUtc -ceq (& $at 30) -and $traffic.lastStatus -eq 200) 'The log is summarised: 22 calls, 6 not 200, the first failure, the last status'
    Check ($traffic.healthySinceUtc -ceq (& $at 48)) 'Healthy again is the start of the trailing run of 200s once it is five long'
    Check ($null -eq (Read-FridayTraffic -LogPath $csv -HealthyRun 7).healthySinceUtc) 'A shorter run of 200s is not recovery yet'
    $since = Read-FridayTraffic -LogPath $csv -Since (& $at 30)
    Check ($since.total -eq 12 -and $since.failed -eq 6) 'Rows before Since (the baseline) are left out'
    Check ((Read-FridayTraffic -LogPath $csv -Since (& $at 600)).total -eq 0 -and (Read-FridayTraffic -LogPath (Join-Path $repo 'missing.csv')).total -eq 0) 'No rows or no file is an empty summary'
    [IO.File]::WriteAllLines($csv, @('utc,status,ms', "$(& $at 0),200,90", "$(& $at 3),200,91"))
    Check ($null -eq (Read-FridayTraffic -LogPath $csv).healthySinceUtc -and (Read-FridayTraffic -LogPath $csv).failed -eq 0) 'A log with no failure has no recovery time'
    $command = Get-Command (Join-Path $root 'scripts\Send-ReleaseTraffic.ps1')
    $pattern = ($command.Parameters['AppUrl'].Attributes | Where-Object { $_ -is [Management.Automation.ValidatePatternAttribute] }).RegexPattern
    Check ('https://app-arc-demo-ticketing-1a2b3c4d.azurewebsites.net' -match $pattern -and 'https://example.com' -notmatch $pattern -and 'http://app.azurewebsites.net' -notmatch $pattern -and 'https://app.azurewebsites.net.evil.com' -notmatch $pattern) 'The traffic script can only be pointed at an azurewebsites.net host over HTTPS'
    Check (($command.Parameters['DurationSeconds'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateRangeAttribute] }).MaxRange -le 14400) 'The traffic script always stops by itself'
    Check (-not (Stop-FridayTraffic -Run @{ trafficPid = $null }) -and -not (Stop-FridayTraffic -Run @{ trafficPid = 2147483000; trafficStartedUtc = (& $at 0) })) 'With no generator, or a PID that does not exist, nothing is stopped'
    $output = @(Stop-FridayTraffic -Run @{ trafficPid = $PID; trafficStartedUtc = (& $at 0) } 3>&1)
    Check (-not ($output | Where-Object { $_ -is [bool] -and $_ }) -and (Get-Process -Id $PID) -and ($output | Where-Object { $_ -is [Management.Automation.WarningRecord] }).Message -match 'not the traffic generator') 'A process that has the recorded PID but another start time is left alone, with a warning'
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru -WindowStyle Hidden
    Check ([bool](Stop-FridayTraffic -Run @{ trafficPid = $child.Id; trafficStartedUtc = $child.StartTime.ToUniversalTime().ToString('o') }) -and $child.WaitForExit(10000)) 'The generator this run started is stopped'

    # --- Is the generator really sending? -----------------------------------------------------------------------------------------
    $healthLog = Join-Path $repo 'health.csv'
    [IO.File]::WriteAllLines($healthLog, @('utc,status,ms', "$(& $at 570),200,90", "$(& $at 573),200,90", "$(& $at 590),200,90"))
    # A log that is already there belongs to an earlier generator. Starting another on it would count the old rows as this one's calls.
    $noTraffic = New-TempDirectory
    New-Item -ItemType Directory -Path (Join-Path $noTraffic 'scripts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $noTraffic 'scripts\Send-ReleaseTraffic.ps1'), 'exit 0')
    Throws { Start-FridayTraffic -RepoRoot $noTraffic -AppUrl 'https://app.azurewebsites.net' -LogPath $healthLog } 'already exists'
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru -WindowStyle Hidden
    $live = @{ trafficPid = $child.Id; trafficStartedUtc = $child.StartTime.ToUniversalTime().ToString('o'); trafficLog = $healthLog }
    $health = Get-FridayTrafficHealth -Run $live -NowUtc (& $at 600)
    Check ($health.alive -and $health.total -eq 3 -and $health.failed -eq 0 -and $health.lastAgeSeconds -eq 10) 'Health reports the live generator, the calls it has logged and how long ago the last one was'
    Check ($null -eq (Get-FridayBaselineProblem -Health $health)) 'A live generator with recent calls that all returned 200 is a proven baseline'
    $waited = Wait-FridayTraffic -Run $live -TimeoutSeconds 5
    Check ($waited.alive -and $waited.total -eq 3) 'Waiting returns at once when the generator has already logged a call'
    $idle = @{ trafficPid = $child.Id; trafficStartedUtc = $live.trafficStartedUtc; trafficLog = (Join-Path $repo 'never-written.csv') }
    $clockStart = [DateTime]::UtcNow
    $silent = Wait-FridayTraffic -Run $idle -TimeoutSeconds 1
    Check ($silent.alive -and $silent.total -eq 0 -and ([DateTime]::UtcNow - $clockStart).TotalSeconds -lt 10 -and (Get-FridayBaselineProblem -Health $silent) -match 'logged no checkouts') 'A generator that logs nothing is given its time, then reported as silent'
    $dead = @{ trafficPid = 2147483000; trafficStartedUtc = (& $at 0); trafficLog = $healthLog }
    $clockStart = [DateTime]::UtcNow
    $gone = Wait-FridayTraffic -Run @{ trafficPid = 2147483000; trafficStartedUtc = (& $at 0); trafficLog = (Join-Path $repo 'never-written.csv') } -TimeoutSeconds 30
    Check (-not $gone.alive -and ([DateTime]::UtcNow - $clockStart).TotalSeconds -lt 10) 'A generator that is gone is reported at once, not after the timeout'
    Check (-not (Get-FridayTrafficHealth -Run $dead).alive -and -not (Get-FridayTrafficHealth -Run @{ trafficPid = $null; trafficLog = $healthLog }).alive -and -not (Get-FridayTrafficHealth -Run @{ trafficPid = $PID; trafficStartedUtc = (& $at 0); trafficLog = $healthLog }).alive) 'No generator, a PID that does not exist, or a PID that is some other process is not alive'
    $quiet = Get-FridayTrafficHealth -Run $live -NowUtc (& $at 700)
    Check ($quiet.lastAgeSeconds -eq 110 -and (Get-FridayBaselineProblem -Health $quiet) -ceq "the traffic generator's last checkout was 110 s ago") 'A generator that has gone quiet is not a proven baseline'
    Check ([bool](Stop-FridayTraffic -Run $live) -and $child.WaitForExit(10000)) 'The generator is stopped again'
    $problemFor = { param($alive, $total, $failed, $age) Get-FridayBaselineProblem -Health ([pscustomobject]@{ alive = $alive; total = $total; failed = $failed; lastAgeSeconds = $age }) }
    Check ((& $problemFor $false 5 0 1) -ceq 'the traffic generator is not running' -and (& $problemFor $true 0 0 $null) -ceq 'the traffic generator has logged no checkouts') 'Not running, and nothing logged, are each named'
    Check ((& $problemFor $true 10 2 1) -ceq '2 of 10 checkouts were not 200 before the release' -and $null -eq (& $problemFor $true 10 0 60) -and (& $problemFor $true 10 0 61) -match '61 s ago') 'Failures before the release stop it, and a call up to 60 s old still counts as recent'

    # --- Alert and thread observation -------------------------------------------------------------------------------------------------
    $ruleId = { param($name) "/subscriptions/$subscription/resourcegroups/rg-arc-demo-ticketing/providers/microsoft.insights/scheduledqueryrules/$name" }
    $alert = { param($name, [int]$start, $condition, $state, $resolved) @{ properties = @{ essentials = @{
        alertRule = (& $ruleId $name); startDateTime = (& $at $start); monitorCondition = $condition; alertState = $state
        monitorConditionResolvedDateTime = $(if ($null -ne $resolved) { & $at $resolved } else { $null }) } } } }
    $parsedAlerts = { param($items) ConvertTo-Json -InputObject @($items) -Depth 12 | ConvertFrom-Json }
    $alerts = & $parsedAlerts @(
        (& $alert $primary 480 'Fired' 'New' $null), (& $alert $spare 520 'Fired' 'New' $null),
        (& $alert 'some-other-rule' 400 'Fired' 'New' $null), (& $alert $primary -3600 'Resolved' 'Closed' -3000))
    $observed = Get-FridayAlertObservation -Alerts $alerts -Since (& $at 300) -AlertTitle $settings.alertTitle
    Check ($observed.count -eq 2 -and $observed.firedUtc -ceq (& $at 480) -and $observed.rule -ceq $primary -and ($observed.states -join ',') -ceq 'Fired/New,Fired/New' -and $null -eq $observed.resolvedUtc) 'Two alerts since the release: the first one fired at 00:08, neither resolved; other rules and old alerts are ignored'
    Check ((Get-FridayAlertObservation -Alerts $alerts -Since (& $at 500) -AlertTitle $settings.alertTitle).count -eq 1) 'Alerts that started before Since are ignored'
    $resolvedAlerts = & $parsedAlerts @((& $alert $primary 480 'Resolved' 'Closed' 2400), (& $alert $spare 520 'Resolved' 'Closed' 2500))
    Check ((Get-FridayAlertObservation -Alerts $resolvedAlerts -Since (& $at 300) -AlertTitle $settings.alertTitle).resolvedUtc -ceq (& $at 2500) -and $null -eq (Get-FridayAlertObservation -Alerts $alerts -Since (& $at 300) -AlertTitle $settings.alertTitle).resolvedUtc) 'Resolved means every alert resolved, at the time the last one did'
    $none = Get-FridayAlertObservation -Alerts $null -Since (& $at 0) -AlertTitle $settings.alertTitle
    Check ($none.count -eq 0 -and $null -eq $none.firedUtc -and (Get-FridayAlertObservation -Alerts $alerts -Since (& $at 0) -AlertTitle 'no-such-title').count -eq 0) 'No alerts, or none for this scenario, is an empty observation'
    $threads = ConvertTo-Json -InputObject @(
        @{ id = 't-late'; title = "Sev2 $($settings.alertName) fired"; createdTimestamp = (& $at 900) },
        @{ id = 't-first'; title = "Sev2 $($settings.alertName) fired"; createdTimestamp = (& $at 610) },
        @{ id = 't-other'; title = 'Some other incident'; createdTimestamp = (& $at 620) },
        @{ id = 't-old'; title = "Sev2 $($settings.alertName) fired"; createdTimestamp = (& $at -100) }) -Depth 5 | ConvertFrom-Json
    $threadObservation = Get-FridayThreadObservation -Threads $threads -Since (& $at 300) -AlertTitle $settings.alertTitle
    Check ($threadObservation.count -eq 2 -and $threadObservation.id -ceq 't-first' -and $threadObservation.createdUtc -ceq (& $at 610) -and @($threadObservation.all).Count -eq 2) 'The run''s thread is the first matching one since the release; a second thread is counted, not mistaken for the first'
    Check ((Get-FridayThreadObservation -Threads $null -Since (& $at 0) -AlertTitle $settings.alertTitle).count -eq 0) 'No threads is an empty observation'

    # --- Cards ------------------------------------------------------------------------------------------------------------------------
    $messages = ConvertTo-Json -InputObject @(
        @{ author = @{ role = 'User' }; timeStamp = (& $at 601); text = 'hello' },
        @{ author = @{ role = 'SREAgent' }; timeStamp = (& $at 615); text = 'Investigating' },
        @{ azCliExecution = @{ id = 'card-1'; status = 'Pending'; description = 'Redeploy v1.2.0'; createdTimestamp = (& $at 700); originalFunctionCall = @{ command = 'az webapp config appsettings set --name app' } } },
        @{ azCliExecution = @{ id = 'card-0'; status = 'Completed'; description = 'Earlier'; createdTimestamp = (& $at 650) } },
        @{ approval = @{ id = 'approval-1'; status = 'Pending'; createdTimestamp = (& $at 800); display = @{ toolName = 'CreateGithubIssue'; parameters = @(@{ name = 'title'; value = 'Fix checkout' }, @{ name = 'repo'; value = 'example-owner/ticketing-app' }) } } },
        @{ approval = @{ id = 'approval-0'; status = 'Approved' } }) -Depth 10 | ConvertFrom-Json
    $cards = @(Get-FridayCards -Messages $messages)
    Check ($cards.Count -eq 4 -and (@($cards | ForEach-Object { $_.id }) -join ',') -ceq 'card-1,card-0,approval-1,approval-0') 'Every card is listed, whatever its status'
    Check ($cards[0].kind -ceq 'azure-write' -and $cards[0].status -ceq 'Pending' -and $cards[0].createdUtc -ceq (& $at 700) -and $cards[0].summary -ceq 'Redeploy v1.2.0' -and $cards[0].command -match 'az webapp config appsettings set') 'An Azure write card carries its time, summary and command'
    Check ($cards[2].kind -ceq 'permission-rule' -and $cards[2].summary -ceq 'CreateGithubIssue' -and $cards[2].command -ceq 'title=Fix checkout; repo=example-owner/ticketing-app') 'A permission-rule card shows the tool and its parameters, so you can check it before a person approves'
    Check ($cards[3].command -ceq '' -and $cards[3].summary -ceq '') 'A card with no display still reads safely'
    $long = ConvertTo-Json -InputObject @(@{ azCliExecution = @{ id = 'c'; status = 'Pending'; originalFunctionCall = @{ command = ('x' * 900) } } }) -Depth 6 | ConvertFrom-Json
    Check (@(Get-FridayCards -Messages $long)[0].command.Length -le 304) 'A very long command is clipped for the report'
    Check (@(Get-FridayCards -Messages @()).Count -eq 0 -and @(Get-FridayCards -Messages $null).Count -eq 0) 'No messages, no cards'

    # --- Folding the sources into the run ---------------------------------------------------------------------------------------------
    $fresh = { @{ runId = 'r1'; state = 'running'; startedUtc = (& $at 0); host = 'app.azurewebsites.net'; goodVersion = 'v1.2.0'; badVersion = 'v1.3.0'; trafficLog = 'x'; events = @{}; cards = @{}; threadId = $null } }
    $trafficAt = { param($first, $healthy) [pscustomobject]@{ total = 40; failed = 5; firstFailureUtc = $first; lastStatus = 500; lastUtc = (& $at 900); healthySinceUtc = $healthy } }
    $alertAt = { param($fired, $resolved) [pscustomobject]@{ count = 1; firedUtc = $fired; rule = $primary; states = @('Fired/New'); resolvedUtc = $resolved } }
    $threadAt = [pscustomobject]@{ count = 1; id = 'thread-1'; createdUtc = (& $at 600); all = @() }
    $run = & $fresh
    $null = Set-FridayEvent -Run $run -Name releaseApplied -Utc (& $at 300)
    $new = @(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) $null) -Alerts $null -Thread $null -Messages @() -ServingVersion 'v1.3.0' -ObservedUtc (& $at 340))
    Check (($new -join ',') -ceq 'badServing,firstFailure' -and $run.events.badServing -ceq (& $at 340) -and $run.events.firstFailure -ceq (& $at 306)) 'The bad release serving and the first failed checkout are recorded, each at its own time'
    $new = @(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) $null) -Alerts (& $alertAt (& $at 480) $null) -Thread $null -Messages @() -ServingVersion 'v1.3.0' -ObservedUtc (& $at 500))
    Check (($new -join ',') -ceq 'alertFired' -and $run.events.alertFired -ceq (& $at 480)) 'The alert is recorded at the time it started, not when it was noticed'
    $thread = $threadAt
    $messageList = @($messages | Where-Object { $_.PSObject.Properties['author'] -or $_.PSObject.Properties['azCliExecution'] })[0..2]
    $new = @(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) $null) -Alerts (& $alertAt (& $at 480) $null) -Thread $thread -Messages $messageList -ServingVersion 'v1.3.0' -ObservedUtc (& $at 720))
    Check (($new -join ',') -ceq 'threadCreated,firstAgentMessage,cardPending' -and $run.threadId -ceq 'thread-1' -and $run.events.firstAgentMessage -ceq (& $at 615) -and $run.events.cardPending -ceq (& $at 700)) 'The thread, the first agent message and the pending Approve card are recorded'
    Check ($run.cards['card-1'].pendingUtc -ceq (& $at 700) -and $null -eq $run.cards['card-1'].finalStatus -and $run.cards['card-1'].kind -ceq 'azure-write') 'The card is tracked as pending'
    $completed = ConvertTo-Json -InputObject @(@{ azCliExecution = @{ id = 'card-1'; status = 'Completed'; description = 'Redeploy v1.2.0'; createdTimestamp = (& $at 700) } }) -Depth 6 | ConvertFrom-Json
    $new = @(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) $null) -Alerts (& $alertAt (& $at 480) $null) -Thread $thread -Messages @($completed) -ServingVersion 'v1.3.0' -ObservedUtc (& $at 1000))
    Check (($new -join ',') -ceq 'cardCompleted' -and $run.cards['card-1'].finalStatus -ceq 'Completed' -and $run.cards['card-1'].finalUtc -ceq (& $at 1000)) 'A completed card is recorded when first seen: it means a person approved it, not when the alert will clear'
    $new = @(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) (& $at 1100)) -Alerts (& $alertAt (& $at 480) (& $at 2400)) -Thread $thread -Messages @($completed) -ServingVersion 'v1.2.0' -ObservedUtc (& $at 2500))
    Check (($new -join ',') -ceq 'healthyAgain,alertResolved' -and $run.events.healthyAgain -ceq (& $at 1100) -and $run.events.alertResolved -ceq (& $at 2400)) 'Recovery and the alert resolving are recorded at their own times'
    Check (@(Update-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) (& $at 1100)) -Alerts (& $alertAt (& $at 480) (& $at 2400)) -Thread $thread -Messages @($completed) -ServingVersion 'v1.2.0' -ObservedUtc (& $at 2600)).Count -eq 0) 'Reading the same state again records nothing new'
    $early = & $fresh
    $null = Set-FridayEvent -Run $early -Name releaseApplied -Utc (& $at 300)
    Check (@(Update-FridayRun -Run $early -Traffic (& $trafficAt (& $at 100) $null) -Alerts $null -Thread $null -Messages @() -ServingVersion 'v1.2.0' -ObservedUtc (& $at 310)).Count -eq 0) 'A failure before the release is not the release failing'
    $partial = & $fresh
    $null = Set-FridayEvent -Run $partial -Name releaseApplied -Utc (& $at 300)
    Check (@(Update-FridayRun -Run $partial -Traffic (& $trafficAt $null (& $at 400)) -Alerts $null -Thread $null -Messages @() -ServingVersion 'v1.2.0' -ObservedUtc (& $at 410)).Count -eq 0) 'Healthy traffic alone is not recovery: the bad release must have served and failed first'
    $unreleased = & $fresh
    Check (@(Update-FridayRun -Run $unreleased -Traffic $null -Alerts $null -Thread $null -Messages @() -ServingVersion 'v1.3.0' -ObservedUtc (& $at 10)).Count -eq 0) 'Nothing is recorded as the bad release before the release was applied'
    $noFire = & $fresh
    Check (@(Update-FridayRun -Run $noFire -Traffic $null -Alerts (& $alertAt $null (& $at 900)) -Thread $null -Messages @() -ServingVersion $null -ObservedUtc (& $at 910)).Count -eq 0) 'An alert cannot resolve before it fired'

    # Cards the run only sees once they are decided, cards that are still running, and the agent's read-only commands.
    $decided = ConvertTo-Json -InputObject @(
        @{ azCliExecution = @{ id = 'read-1'; status = 'Completed'; description = 'List settings'; createdTimestamp = (& $at 650); originalFunctionCall = @{ name = 'RunAzCliReadCommands'; command = 'az webapp config appsettings list --name app' } } },
        @{ azCliExecution = @{ id = 'write-1'; status = 'Completed'; description = 'Redeploy v1.2.0'; createdTimestamp = (& $at 700); originalFunctionCall = @{ name = 'RunAzCliWriteCommands'; command = 'az webapp config appsettings set --name app' } } },
        @{ azCliExecution = @{ id = 'write-2'; status = ''; description = 'Unknown state'; originalFunctionCall = @{ name = 'RunAzCliWriteCommands'; command = 'az webapp restart --name app' } } },
        @{ approval = @{ id = 'approval-9'; status = 'Approved'; display = @{ toolName = 'CreateGithubIssue'; parameters = @() } } }) -Depth 10 | ConvertFrom-Json
    $late = & $fresh
    $null = Set-FridayEvent -Run $late -Name releaseApplied -Utc (& $at 300)
    $new = @(Update-FridayRun -Run $late -Traffic $null -Alerts $null -Thread $threadAt -Messages $decided -ServingVersion $null -ObservedUtc (& $at 1000))
    Check (-not $late.cards.ContainsKey('read-1') -and @($late.cards.Keys).Count -eq 3) 'A read-only command the agent ran is not a card: nobody decides on it'
    Check (($new -join ',') -ceq 'threadCreated,cardPending,cardCompleted' -and $late.events.cardPending -ceq (& $at 700) -and $late.events.cardCompleted -ceq (& $at 1000)) 'A write card first seen already decided is dated from its creation, then completed when seen'
    Check ($late.cards['write-1'].pendingUtc -ceq (& $at 700) -and $late.cards['write-1'].finalStatus -ceq 'Completed' -and $late.cards['write-1'].finalUtc -ceq (& $at 1000)) 'Its record is closed, not left pending'
    Check ($late.cards['write-2'].finalStatus -ceq 'Unknown' -and $null -eq $late.cards['write-2'].pendingUtc -and $late.cards['approval-9'].finalStatus -ceq 'Approved' -and $null -eq $late.cards['approval-9'].pendingUtc) 'A decided card with no creation time claims no pending time, and a card with no status says so'
    $lateText = @(Format-FridayRun -Run $late -Traffic $null -ServingVersion $null -ServingRelease $null) -join "`n"
    Check ($lateText -notmatch '\[Pending\]' -and $lateText -match 'card \[Completed\] azure-write: Redeploy v1\.2\.0' -and $lateText -match 'card \[Approved\] permission-rule: CreateGithubIssue') 'No decided card is shown as pending'
    $inFlight = ConvertTo-Json -InputObject @(@{ azCliExecution = @{ id = 'card-r'; status = 'Running'; description = 'Redeploy'; createdTimestamp = (& $at 700); originalFunctionCall = @{ command = 'az webapp config appsettings set' } } }) -Depth 8 | ConvertFrom-Json
    $finished = ConvertTo-Json -InputObject @(@{ azCliExecution = @{ id = 'card-r'; status = 'Completed'; description = 'Redeploy'; createdTimestamp = (& $at 700); originalFunctionCall = @{ command = 'az webapp config appsettings set' } } }) -Depth 8 | ConvertFrom-Json
    $going = & $fresh
    $new = @(Update-FridayRun -Run $going -Traffic $null -Alerts $null -Thread $threadAt -Messages $inFlight -ServingVersion $null -ObservedUtc (& $at 900))
    Check ('cardCompleted' -notin $new -and $going.cards['card-r'].finalStatus -ceq 'Running' -and $null -eq $going.cards['card-r'].finalUtc -and @($going.cards.Values | Where-Object { $_.pendingUtc -and -not $_.finalStatus }).Count -eq 0) 'A card that is running was approved but is not finished, and is no longer waiting for a person'
    $new = @(Update-FridayRun -Run $going -Traffic $null -Alerts $null -Thread $threadAt -Messages $finished -ServingVersion $null -ObservedUtc (& $at 960))
    Check ($new -contains 'cardCompleted' -and $going.cards['card-r'].finalStatus -ceq 'Completed' -and $going.cards['card-r'].finalUtc -ceq (& $at 960) -and $going.events.cardCompleted -ceq (& $at 960)) 'It is completed when it is next read'

    # --- The status report ------------------------------------------------------------------------------------------------------------
    $report = @(Format-FridayRun -Run $run -Traffic (& $trafficAt (& $at 306) (& $at 1100)) -ServingVersion '1.2.0' -ServingRelease 'abc1234')
    $reportText = $report -join "`n"
    Check ($report[0] -ceq 'Run r1 (running) since 00:00:00Z; the app serves v1.2.0 (release abc1234); good v1.2.0, bad v1.3.0.') 'The first line says which run, since when, and which release is serving'
    Check ($reportText -match 'bad release applied\s+00:05:00Z \(\+0m00s\)' -and $reportText -match 'first failed checkout\s+00:05:06Z \(\+0m06s\)' -and $reportText -match 'alert fired\s+00:08:00Z \(\+3m00s\)') 'Each event shows its time and the minutes and seconds since the release'
    Check ($reportText -match 'Approve card pending\s+00:11:40Z' -and $reportText -match 'card completed \(first seen\)\s+00:16:40Z' -and $reportText -match 'alert resolved\s+00:40:00Z \(\+35m00s\)') 'The card and the alert resolving are in the report'
    Check ($reportText -match '  card \[Completed\] azure-write: Redeploy v1\.2\.0') 'The card line shows its final status, its kind and what it does'
    $partialReport = @(Format-FridayRun -Run $partial -Traffic $null -ServingVersion $null -ServingRelease $null) -join "`n"
    Check ($partialReport -match 'the app is not answering' -and $partialReport -match 'bad release applied\s+00:05:00Z' -and $partialReport -match 'alert fired\s+-') 'An app that does not answer, and events that have not happened, are said plainly'
    $before = & $fresh
    $null = Set-FridayEvent -Run $before -Name releaseApplied -Utc (& $at 300)
    $null = Set-FridayEvent -Run $before -Name firstFailure -Utc (& $at 290)
    Check ((@(Format-FridayRun -Run $before -Traffic $null -ServingVersion '1.3.0' -ServingRelease $null) -join "`n") -match 'first failed checkout\s+00:04:50Z \(-0m10s\)') 'An event before the release shows a negative offset'

    # --- The az calls the runner makes ------------------------------------------------------------------------------------------------
    $global:FridayState = @{ configured = 'v1.2.0'; serving = '1.2.0'; rules = @{}; alerts = @(); patchBody = $null; bodyFile = $null; listOverride = $null; hostName = 'app.azurewebsites.net'
        packagePrefix = "https://$githubHost/example-owner/ticketing-app/releases/download"; agentReady = $false; markerDir = $null; badTag = $settings.badVersion; rowsAtRelease = $null }
    $global:FridayState.rules[$primary] = $true
    $global:FridayState.rules[$spare] = $false
    $global:AzExitCode = 0
    $global:AzResponder = {
        $command = $args -join ' '
        $s = $global:FridayState
        if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
        if ($s.agentReady -and $command -like 'resource show --ids */providers/Microsoft.App/agents/*') {
            return '{"properties":{"provisioningState":"Succeeded","runningState":"Running","actionConfiguration":{"mode":"Review"},"agentEndpoint":"https://example.azuresre.ai"}}'
        }
        if ($s.agentReady -and $command -like 'account get-access-token*') { return 'test-token' }
        if ($command -like 'webapp config appsettings list*') {
            if ($s.listOverride) { return $s.listOverride }
            return (ConvertTo-Json -InputObject @(
                @{ name = 'WEBSITE_RUN_FROM_PACKAGE'; value = "$($s.packagePrefix)/$($s.configured)/ticketing-app-$($s.configured).zip" },
                @{ name = 'NODE_OPTIONS'; value = '--enable-source-maps' }) -Depth 5)
        }
        if ($command -like 'webapp config appsettings set*') {
            $s.configured = [regex]::Match($command, 'releases/download/(v\d+\.\d+\.\d+)/').Groups[1].Value
            $s.serving = $s.configured.TrimStart('v')
            if ($s.markerDir) {
                # Stands in for the real app: once the bad release is set, the stub traffic generator logs failed checkouts.
                $marker = Join-Path $s.markerDir 'bad.marker'
                if ($s.configured -ceq $s.badTag) {
                    # The log of the run being released, as its record names it.
                    $log = [string](Get-Content -LiteralPath (Join-Path $s.markerDir 'current.json') -Raw | ConvertFrom-Json).trafficLog
                    $s.rowsAtRelease = if (Test-Path -LiteralPath $log) { @(Read-SharedLines $log).Count - 1 } else { 0 }
                    New-Item -ItemType File -Path $marker -Force | Out-Null
                } else { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
            }
            return ''
        }
        if ($command -like '*--query properties.defaultHostName*') { return $s.hostName }
        if ($command -like 'resource show --ids */scheduledQueryRules/*') { return (@{ properties = @{ enabled = [bool]$s.rules[($args[3] -split '/')[-1]] } } | ConvertTo-Json -Depth 5) }
        if ($command -like 'rest --method get --url *providers/Microsoft.AlertsManagement/alerts*') { return (@{ value = @($s.alerts) } | ConvertTo-Json -Depth 12) }
        if ($command -like 'rest --method patch --url *scheduledQueryRules/*') {
            $name = [regex]::Match($command, 'scheduledQueryRules/([^?]+)\?').Groups[1].Value
            $s.bodyFile = ([string]$args[[Array]::IndexOf($args, '--body') + 1]).TrimStart('@')
            $body = Get-Content -LiteralPath $s.bodyFile -Raw | ConvertFrom-Json
            $s.rules[$name] = [bool]$body.properties.enabled
            $s.patchBody = ($body | ConvertTo-Json -Compress)
            return ''
        }
        throw "Unexpected mocked call: $command"
    }
    $global:WebCalls = [Collections.Generic.List[string]]::new()
    $global:WebResponder = { [pscustomobject]@{ StatusCode = 200; Content = (@{ status = 'ok'; version = $global:FridayState.serving; release = 'abc1234' } | ConvertTo-Json -Compress) } }
    function global:Invoke-WebRequest { $global:WebCalls.Add(($args -join ' ')); & $global:WebResponder @args }
    $state = $global:FridayState

    $global:AzCalls.Clear()
    Set-FridayPackage -SubscriptionId $subscription -Settings $settings -Version 'v1.3.0'
    Check ($global:AzCalls.Count -eq 1 -and $global:AzCalls[0] -like "webapp config appsettings set --resource-group rg-arc-demo-ticketing --name $($settings.appName) --settings WEBSITE_RUN_FROM_PACKAGE=https://$githubHost/example-owner/ticketing-app/releases/download/v1.3.0/ticketing-app-v1.3.0.zip -o none --subscription *") 'Releasing a version is one az command that changes one setting and prints no settings'
    Throws { Set-FridayPackage -SubscriptionId $subscription -Settings $settings -Version 'latest' } 'Release version must look like'
    Check ($global:AzCalls.Count -eq 1) 'A bad version is refused before any az call'
    Check ((Get-FridayPackageVersion -SubscriptionId $subscription -Settings $settings) -ceq 'v1.3.0') 'The configured release is read from WEBSITE_RUN_FROM_PACKAGE'
    $state.listOverride = '[{"name":"NODE_OPTIONS","value":"x"}]'
    Check ($null -eq (Get-FridayPackageVersion -SubscriptionId $subscription -Settings $settings)) 'No package setting reads as unknown'
    $state.listOverride = '[{"name":"WEBSITE_RUN_FROM_PACKAGE","value":"1"}]'
    Check ($null -eq (Get-FridayPackageVersion -SubscriptionId $subscription -Settings $settings)) 'A package setting that is not a release URL reads as unknown'
    $state.listOverride = $null
    $state.alerts = @($alerts)
    $listed = @(Get-FridayAlerts -SubscriptionId $subscription -Settings $settings)
    Check ($listed.Count -eq 4 -and $global:AzCalls[-1] -like '*targetResourceGroup=rg-arc-demo-ticketing&timeRange=1d*') 'Alerts are read for the ticketing group only'
    $states = Get-FridayRuleStates -SubscriptionId $subscription -Settings $settings
    Check (@($states.Keys) -join ',' -ceq "$primary,$spare" -and $states[$primary] -eq $true -and $states[$spare] -eq $false) 'Rule states list the primary rule first'
    $global:AzCalls.Clear()
    Throws { Set-FridayRuleEnabled -SubscriptionId $subscription -Settings $settings -RuleName 'some-other-rule' -Enabled $true } 'Refusing to change'
    Check ($global:AzCalls.Count -eq 0) 'A rule that is not one of the two is never touched'
    Set-FridayRuleEnabled -SubscriptionId $subscription -Settings $settings -RuleName $spare -Enabled $true
    Check ($global:AzCalls.Count -eq 1 -and $global:AzCalls[0] -like "rest --method patch --url https://management.azure.com/subscriptions/$subscription/resourceGroups/rg-arc-demo-ticketing/providers/Microsoft.Insights/scheduledQueryRules/${spare}?api-version=2023-03-15-preview --body @* -o none --subscription *") 'Enabling a rule is one PATCH on that rule'
    Check ($state.patchBody -ceq '{"properties":{"enabled":true}}' -and $state.rules[$spare] -eq $true -and -not (Test-Path -LiteralPath $state.bodyFile)) 'The PATCH body changes only enabled, and its temporary file is removed'
    Set-FridayRuleEnabled -SubscriptionId $subscription -Settings $settings -RuleName $spare -Enabled $false
    Check ($state.rules[$spare] -eq $false) 'A rule can be switched off again'

    # --- The real script, against a copy of the scripts -------------------------------------------------------------------------------
    # From here the timeline is anchored 30 minutes ago, because the runner stamps some events with the real clock.
    $t0 = [DateTimeOffset]::FromUnixTimeSeconds([DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeSeconds())
    $clock = { param([int]$seconds) $t0.AddSeconds($seconds).ToString('HH:mm:ss') }
    $fixture = New-TempDirectory -Prefix 'friday fixture '
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination (Join-Path $fixture 'scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination (Join-Path $fixture 'config') -Recurse
    $runner = Join-Path $fixture 'scripts\Invoke-FridayRelease.ps1'
    $mutations = { @($global:AzCalls | Where-Object { $_ -match 'appsettings set|--method patch| delete' }).Count }
    $invoke = { param([hashtable]$Arguments) @(& $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath @Arguments 6>&1 3>&1) }
    $text = { param($records) (@($records | ForEach-Object { [string]$_ }) -join "`n") }
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Status } 'No run is recorded'

    $state.configured = 'v1.3.0'; $state.serving = '1.3.0'
    $rollout = New-FridayRun -RepoRoot $fixture -Settings $settings -HostName 'app.azurewebsites.net'
    $rollout.startedUtc = & $at 0
    $null = Set-FridayEvent -Run $rollout -Name releaseApplied -Utc (& $at 300)
    $rolloutCsv = @('utc,status,ms', "$(& $at 270),200,90", "$(& $at 303),200,90", "$(& $at 306),500,300", "$(& $at 309),500,310")
    [IO.File]::WriteAllLines($rollout.trafficLog, $rolloutCsv)
    Save-FridayRun -RepoRoot $fixture -Run $rollout
    $state.alerts = @(& $alert $primary 480 'Fired' 'New' $null)
    $global:AzCalls.Clear()
    $statusText = & $text (& $invoke @{ Action = 'Status' })
    $saved = Read-FridayRun -RepoRoot $fixture
    Check ($saved.events.ContainsKey('badServing') -and $saved.events['firstFailure'] -ceq (& $at 306) -and $saved.events['alertFired'] -ceq (& $at 480) -and -not $saved.events.ContainsKey('threadCreated')) 'Status records what it sees: the bad release serving, the first failure, the alert'
    Check ($statusText -match "first failed checkout\s+$(& $clock 306)Z \(\+0m06s\)" -and $statusText -match "alert fired\s+$(& $clock 480)Z \(\+3m00s\)" -and $statusText -match 'the app serves v1\.3\.0') 'Status prints the report'
    Check ($statusText -match 'data plane is not reachable') 'Without the SRE agent, Status still reports the app, the traffic and the alert, and says what it skipped'
    Check ((& $mutations) -eq 0) 'Status changes nothing in Azure'

    $stale = Read-FridayRun -RepoRoot $fixture
    $stale.cards['card-1'] = @{ kind = 'azure-write'; summary = 'Redeploy v1.2.0'; command = 'az webapp config appsettings set'; pendingUtc = (& $at 700); finalStatus = $null; finalUtc = $null }
    Save-FridayRun -RepoRoot $fixture -Run $stale
    $global:AzCalls.Clear()
    $whatIfText = & $text (& $invoke @{ Action = 'Reset'; WhatIf = $true })
    Check ($whatIfText -match 'app: configured release v1\.3\.0 -> v1\.2\.0' -and $whatIfText -match "alert rules: active $([regex]::Escape($primary)) -> $([regex]::Escape($primary))" -and $whatIfText -match 'threads: keep') 'Reset -WhatIf prints what it would do'
    Check ((& $mutations) -eq 0 -and $state.configured -ceq 'v1.3.0' -and (Test-Path -LiteralPath (Join-Path $fixture '.local\friday-release\current.json'))) 'Reset -WhatIf changes nothing and keeps the run record'
    $global:AzCalls.Clear()
    $resetText = & $text (& $invoke @{ Action = 'Reset' })
    Check ($state.configured -ceq 'v1.2.0' -and @($global:AzCalls | Where-Object { $_ -like 'webapp config appsettings set*' }).Count -eq 1) 'Reset puts the last good release back with one setting change'
    Check ($resetText -match 'Reset complete: app on v1\.2\.0, active alert rule' -and $resetText -match '0 thread\(s\) deleted' -and $resetText -match 'never approve it') 'Reset says it is done, and warns that a card still pending is stale'
    Check (@($global:AzCalls | Where-Object { $_ -like 'rest --method patch*' }).Count -eq 0) 'The right alert rule was already the only active one, so no rule is touched'
    $directory = Get-FridayDirectory -RepoRoot $fixture
    $archived = Get-Content -LiteralPath (Join-Path $directory "run-$($saved.runId).json") -Raw | ConvertFrom-Json
    Check (-not (Test-Path -LiteralPath (Join-Path $directory 'current.json')) -and $archived.state -ceq 'reset' -and $archived.resetUtc) 'Reset archives the run record, so the next run starts clean'
    $global:AzCalls.Clear()
    $null = & $invoke @{ Action = 'Reset'; SwapRules = $true }
    Check ($state.configured -ceq 'v1.2.0' -and @($global:AzCalls | Where-Object { $_ -like 'webapp config appsettings set*' }).Count -eq 0) 'Reset leaves the app alone when it already runs the good release'
    $patches = @($global:AzCalls | Where-Object { $_ -like 'rest --method patch*' })
    Check ($patches.Count -eq 2 -and $patches[0] -like "*scheduledQueryRules/${spare}?*" -and $patches[1] -like "*scheduledQueryRules/${primary}?*" -and $state.rules[$spare] -eq $true -and $state.rules[$primary] -eq $false) 'Reset -SwapRules turns the spare rule on before it turns the first one off, so one is always on'
    $null = & $invoke @{ Action = 'Reset'; SwapRules = $true }
    Check ($state.rules[$primary] -eq $true -and $state.rules[$spare] -eq $false) 'Swapping again returns to the first rule'

    $running = New-FridayRun -RepoRoot $fixture -Settings $settings -HostName 'app.azurewebsites.net'
    Save-FridayRun -RepoRoot $fixture -Run $running
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start } 'already in progress'
    Remove-Item -LiteralPath (Join-Path $directory 'current.json') -Force
    $state.serving = '1.3.0'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -BaselineMinutes 0 } "not serving the last good release v1\.2\.0 \(it reports '1\.3\.0'"
    $state.serving = '1.2.0'
    $state.rules[$spare] = $true
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -BaselineMinutes 0 } 'Exactly one alert rule must be enabled'
    $state.rules[$spare] = $false
    $global:AzCalls.Clear()
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -BaselineMinutes 0 } 'SRE agent is not ready'
    Check ((& $mutations) -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $directory 'current.json'))) 'Start refuses before it starts traffic, records a run or changes the app, when the agent is not ready'
    Check (@(Get-ChildItem -LiteralPath $directory -Filter 'traffic-*.csv').Count -eq 1) 'No traffic log was started by the refused Start'

    # --- Start proves the baseline before it releases ---------------------------------------------------------------------------------
    # The traffic generator in the fixture is swapped for stubs that send nothing over the network. The fixture path has a space in it,
    # as a real checkout's can, so this also proves the generator is started with its paths quoted.
    $generator = Join-Path $fixture 'scripts\Send-ReleaseTraffic.ps1'
    $stubHealthy = @'
param([string]$AppUrl, [string]$LogPath, [int]$IntervalSeconds, [int]$DurationSeconds)
if (-not (Test-Path -LiteralPath $LogPath)) { 'utc,status,ms' | Set-Content -LiteralPath $LogPath -Encoding utf8 }
$marker = Join-Path (Split-Path -Parent $LogPath) 'bad.marker'
$end = [DateTimeOffset]::UtcNow.AddSeconds(90)
while ([DateTimeOffset]::UtcNow -lt $end) {
    $status = if (Test-Path -LiteralPath $marker) { 500 } else { 200 }
    ('{0:o},{1},5' -f [DateTimeOffset]::UtcNow, $status) | Add-Content -LiteralPath $LogPath -Encoding utf8
    Start-Sleep -Milliseconds 50
}
'@
    $stubDead = @'
param([string]$AppUrl, [string]$LogPath, [int]$IntervalSeconds, [int]$DurationSeconds)
exit 3
'@
    $stubFailing = @'
param([string]$AppUrl, [string]$LogPath, [int]$IntervalSeconds, [int]$DurationSeconds)
if (-not (Test-Path -LiteralPath $LogPath)) { 'utc,status,ms' | Set-Content -LiteralPath $LogPath -Encoding utf8 }
$end = [DateTimeOffset]::UtcNow.AddSeconds(30)
while ([DateTimeOffset]::UtcNow -lt $end) {
    ('{0:o},500,5' -f [DateTimeOffset]::UtcNow) | Add-Content -LiteralPath $LogPath -Encoding utf8
    Start-Sleep -Milliseconds 50
}
'@
    $stubStale = @'
param([string]$AppUrl, [string]$LogPath, [int]$IntervalSeconds, [int]$DurationSeconds)
if (-not (Test-Path -LiteralPath $LogPath)) { 'utc,status,ms' | Set-Content -LiteralPath $LogPath -Encoding utf8 }
('{0:o},200,5' -f [DateTimeOffset]::UtcNow.AddMinutes(-10)) | Add-Content -LiteralPath $LogPath -Encoding utf8
Start-Sleep -Seconds 30
'@
    $useGenerator = { param([string]$Source) [IO.File]::WriteAllText($generator, $Source, [Text.UTF8Encoding]::new($false)) }
    # Only Start needs the agent to look ready; Reset must not try to reach a data plane that does not exist.
    $startRunner = { param([hashtable]$Arguments) $state.agentReady = $true; try { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath @Arguments 6>&1 3>&1 } finally { $state.agentReady = $false } }
    $state.markerDir = $directory

    # CI once failed here: Start reused the traffic log of an earlier run begun in the same second, and the 25 to 30 minute old rows in it passed for
    # fresh traffic. Leave such logs under every name a second-granularity run ID could have had from now on; a new run must not touch them.
    $seedFrom = [DateTimeOffset]::UtcNow
    $leftovers = @(-5..120 | ForEach-Object { Join-Path $directory ('traffic-{0}.csv' -f $seedFrom.AddSeconds($_).ToString('yyyyMMddTHHmmssZ')) })
    foreach ($leftover in $leftovers) { [IO.File]::WriteAllLines($leftover, $rolloutCsv) }

    & $useGenerator $stubHealthy
    $global:AzCalls.Clear()
    $startText = try { & $text @(& $startRunner @{ Action = 'Start'; BaselineMinutes = 0 }) } catch { "Start failed: $($_.Exception.Message)" }
    $started = Read-FridayRun -RepoRoot $fixture
    $releases = @($global:AzCalls | Where-Object { $_ -like 'webapp config appsettings set*' })
    Check ($startText -match 'Baseline proven: \d+ checkouts, all 200' -and $startText -match 'Released v1\.3\.0 at ' -and $releases.Count -eq 1 -and $releases[0] -like '*releases/download/v1.3.0/*') "Start proves the baseline from its own traffic, then releases the bad version once, even with older logs around. Output: $startText"
    Check ($state.rowsAtRelease -ge 1) 'Checkouts were already flowing when the bad version went out'
    Check ($started.state -ceq 'running' -and $started.trafficPid -and $started.events.ContainsKey('releaseApplied') -and $started.events.ContainsKey('badServing') -and $started.events.ContainsKey('firstFailure')) 'The run records the release, the bad release serving and the first failed checkout'
    $generatorPid = [int]$started.trafficPid
    $null = & $invoke @{ Action = 'Reset' }
    $stopped = $false
    for ($wait = 0; $wait -lt 25 -and -not $stopped; $wait++) { $stopped = -not (Get-Process -Id $generatorPid -ErrorAction SilentlyContinue); if (-not $stopped) { Start-Sleep -Milliseconds 200 } }
    Check ($stopped -and $state.configured -ceq 'v1.2.0' -and -not (Test-Path -LiteralPath (Join-Path $directory 'bad.marker'))) 'Reset stops the generator that Start began and puts the good release back'
    Remove-Item -LiteralPath $leftovers -Force

    $refusals = @(
        @{ stub = $stubDead; pattern = 'Nothing was released: the traffic generator is not running\. Run -Action Reset'; what = 'A generator that is not running' }
        @{ stub = $stubFailing; pattern = 'Nothing was released: \d+ of \d+ checkouts were not 200 before the release'; what = 'Checkouts that fail before the release' }
        @{ stub = $stubStale; pattern = "Nothing was released: the traffic generator's last checkout was \d+ s ago"; what = 'A generator whose last checkout is old' })
    foreach ($refusal in $refusals) {
        & $useGenerator $refusal.stub
        $global:AzCalls.Clear()
        Throws { & $startRunner @{ Action = 'Start'; BaselineMinutes = 0 } } $refusal.pattern
        $aborted = Read-FridayRun -RepoRoot $fixture
        Check ((& $mutations) -eq 0 -and $aborted.state -ceq 'aborted' -and -not $aborted.events.ContainsKey('releaseApplied')) "$($refusal.what) releases nothing, and the run is marked aborted"
    }

    $currentFile = Join-Path $directory 'current.json'
    [IO.File]::WriteAllText($currentFile, '{"runId": "half-written", "events": {')
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Status } 'current\.json cannot be read'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -BaselineMinutes 0 } 'current\.json cannot be read'
    $unreadableText = & $text (& $invoke @{ Action = 'Reset' })
    Check ($unreadableText -match 'could not be read' -and $unreadableText -match 'Reset complete' -and -not (Test-Path -LiteralPath $currentFile) -and @(Get-ChildItem -LiteralPath $directory -Filter 'unreadable-*.json').Count -eq 1) 'Reset moves a record it cannot read aside and carries on; Start and Status say what is wrong'

    Write-Host "$count T12 runner assertions passed. Azure and web calls were mocked; no traffic was sent."
} finally {
    if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    if ($fixture) {
        # A stub generator that outlived a failed test: found by the unique fixture path in its command line.
        try { Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($fixture) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch { $null = $_ }
    }
    Remove-Item Function:\Invoke-WebRequest, Function:\Read-SharedLines -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name WebCalls, WebResponder, FridayState -ErrorAction SilentlyContinue
    $global:AzResponder = $previousResponder
    $global:AzExitCode = $previousExit
    foreach ($path in $temps) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
}
