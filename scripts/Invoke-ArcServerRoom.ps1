#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the ARC module's "server room" scenario (Act 6): install the repair script on the Arc server, check the estate, break the LOB app, watch the
    alert, the investigation and the Approve card, and reset.

.DESCRIPTION
    Prepare    Installs the repair script on the Arc server with a Run Command under your own credentials (once per estate, and again if its text changes).
               The agent later asks to run that one script; it never carries script text itself.
    Check      Reads the server, the repair script, leftover repair run commands, the LOB alert rule and the other Arc machines. Read-only.
    Start      Breaks the LOB app on the Arc server (the T11 fault, under your credentials) and records the run in .local\arc-server-room\current.json.
               Needs -ApproveFault: it fires a real alert and starts a real investigation. Run Check first.
    Status     Reads the alert, the agent's thread, its cards and the repair run command, and records when each milestone first happened. With -Wait it
               keeps polling until a card is pending. It says whether that card is the allowed repair, and it never approves anything: a person clicks
               Approve in the SRE portal, and the repair runs under the agent's own identity.
    Reset      Puts the app back to Healthy (the T11 reset, under your credentials) and deletes the repair run commands the agent created, never the
               install marker or the T11 ones. -DeleteThreads removes this run's investigation threads, and any stale Approve card with them.

    Use -WhatIf on Prepare, Start or Reset to see what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Check', 'Start', 'Status', 'Reset')]
    [string]$Action,

    [string]$SkinPath = '',

    [switch]$ApproveFault,

    [switch]$Wait,

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 15,

    [switch]$DeleteThreads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreActs.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreFridayRelease.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreArcServerRoom.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if ('ARC' -notin @(Get-SreActsModules -Skin $skin)) { throw 'This skin does not turn on ARC. Add ARC to sre.requiredScenarios (it needs T11 and the High access level). See docs/arc-server-room.md.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$arc = Get-SreArcConfig -Skin $skin -SubscriptionId $SubscriptionId
$repair = Get-SreArcRepairScript -Skin $skin -SubscriptionId $SubscriptionId
$agentGroup = "rg-$($skin.azure.namePrefix)-sre"
$agentName = [string]$skin.labels.agentName
$alertRuleId = "/subscriptions/$SubscriptionId/resourceGroups/$($arc.resourceGroup)/providers/Microsoft.Insights/scheduledQueryRules/alert-$($skin.azure.namePrefix)-lob-arc-app-fault"
$lobScript = Join-Path $PSScriptRoot 'Invoke-LobArcAppOnArc.ps1'

function Read-AzJson {
    param([string[]]$Arguments)
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments ($Arguments + @('-o', 'json')) | ConvertFrom-Json -Depth 100
}

function Get-ArcMachineOrNull {
    try { return Read-AzJson @('connectedmachine', 'show', '-g', $arc.resourceGroup, '-n', $arc.machineName) } catch { return $null }
}

function Get-OptionalContext {
    # The data plane is optional for Status and Reset: without it the alert and the repair run command are still reported.
    try { return New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $agentGroup -AgentName $agentName -TimeoutSeconds 30 }
    catch { Write-Warning "The SRE agent's data plane is not reachable ($($_.Exception.Message)); thread and card details are skipped."; return $null }
}

function Get-CheckRow {
    $alertRule = try { Read-AzJson @('resource', 'show', '--ids', $alertRuleId) } catch { $null }
    # The marker is read by name, because a list may leave out each run's result.
    $listed = @(Get-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc | Where-Object { $_.name -cne $arc.installName })
    $marker = Get-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc -Name $arc.installName
    Get-ArcCheckRow -Machine (Get-ArcMachineOrNull) -AllMachine @(Read-AzJson @('connectedmachine', 'list', '-g', $arc.resourceGroup)) `
        -RunCommand @(@($listed) + @($marker | Where-Object { $_ })) -Settings $arc -ExpectedSha256 $repair.sha256 -AlertRule $alertRule
}

function Invoke-GuestScript {
    # One Run Command under your credentials, the way Invoke-LobArcAppOnArc.ps1 does it: the script travels in a temporary file.
    param([string]$Name, [string]$Text)
    $path = Join-Path ([IO.Path]::GetTempPath()) "$Name-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('connectedmachine', 'run-command', 'create', '--name', $Name, '--machine-name', $arc.machineName,
            '--resource-group', $arc.resourceGroup, '--script', "@$path", '--async-execution', 'false', '--timeout-in-seconds', '300', '-o', 'none') | Out-Null
    } finally { Remove-Item -LiteralPath $path -Force -WhatIf:$false }
    ConvertTo-ArcRunView (Read-AzJson @('connectedmachine', 'run-command', 'show', '--name', $Name, '--machine-name', $arc.machineName, '-g', $arc.resourceGroup))
}

function Read-RunRecord {
    # A record that cannot be read (for example a half-written file) is named as such. Reset moves it aside and carries on.
    param([switch]$MoveAside)
    try { return Read-ArcRun -RepoRoot $repoRoot }
    catch {
        $reason = $_.Exception.Message
        if (-not $MoveAside) { throw "The run record .local\arc-server-room\current.json cannot be read ($reason). Run -Action Reset: it moves the record aside and carries on." }
        $directory = Get-ArcDirectory -RepoRoot $repoRoot
        $aside = Join-Path $directory "unreadable-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
        Move-Item -LiteralPath (Join-Path $directory 'current.json') -Destination $aside -Force
        Write-Warning "The run record could not be read ($reason), so it was moved to $aside and Reset carries on without it."
        return $null
    }
}

function Read-Source {
    param([Collections.IDictionary]$Run, $Context)
    $since = [string]$Run.startedUtc
    $alerts = Get-FridayAlertObservation -Alerts (Get-FridayAlerts -SubscriptionId $SubscriptionId -Settings @{ resourceGroup = $arc.resourceGroup }) -Since $since -AlertTitle $arc.alertTitle
    $thread = $null
    $messages = @()
    if ($Context) {
        $thread = Get-FridayThreadObservation -Threads (Get-SreThreads -Context $Context -Top 30) -Since $since -AlertTitle $arc.alertTitle
        if ($thread.id) { $messages = @((Get-SreThreadMessages -Context $Context -ThreadId $thread.id).Messages) }
    }
    $floor = [DateTimeOffset]::Parse($since, [Globalization.CultureInfo]::InvariantCulture)
    # Each repair run command is read by name for its result; the newest one that started in this run is the repair.
    $names = @(Get-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc | Where-Object { $_.name -clike "$($arc.runPrefix)*" } | ForEach-Object { $_.name })
    $repairRun = @($names | ForEach-Object { Get-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc -Name $_ } | Where-Object {
            $_ -and $_.startUtc -and [DateTimeOffset]::Parse($_.startUtc, [Globalization.CultureInfo]::InvariantCulture) -ge $floor
        } | Sort-Object startUtc | Select-Object -Last 1)
    [pscustomobject]@{ alerts = $alerts; thread = $thread; messages = $messages; repairRun = $(if ($repairRun.Count) { $repairRun[0] } else { $null }) }
}

switch ($Action) {
    'Prepare' {
        $shown = $repair.sha256.Substring(0, 12)
        Write-Output "  repair script: $shown, $($repair.text.Length) characters, to $($arc.repairPath) on $($arc.machineName) (run command $($arc.installName))"
        if (-not $PSCmdlet.ShouldProcess($arc.machineName, "install the repair script at $($arc.repairPath)")) { return }
        $view = Invoke-GuestScript -Name $arc.installName -Text (Get-ArcInstallScript -ScriptText $repair.text -Path $arc.repairPath)
        if ($view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0 -or $view.output -notmatch "sha256=$($repair.sha256)") {
            throw "The repair script was not confirmed on the server (state $($view.executionState), exit code $($view.exitCode)). Read the run command $($arc.installName) on $($arc.machineName); do not start the scenario."
        }
        Write-Output "Installed: the server reports the same SHA-256 ($shown...) as this repo. Next: -Action Check."
    }
    'Check' {
        $rows = @(Get-CheckRow)
        foreach ($row in $rows) { Write-Output ('{0,-8} {1,-22} {2}' -f $row.status.ToUpperInvariant(), $row.name, $row.detail) }
        $overall = if (@($rows | Where-Object { $_.status -eq 'fail' }).Count) { 'fail' } elseif (@($rows | Where-Object { $_.status -eq 'pending' }).Count) { 'pending' } else { 'pass' }
        Write-Output "Overall: $overall. Start needs the server Connected, the repair script installed and the alert rule enabled."
    }
    'Start' {
        $existing = Read-RunRecord
        if ($existing -and $existing.state -eq 'running') { throw "A run is already in progress ($($existing.runId)). Run -Action Status, then -Action Reset." }
        if (-not $ApproveFault -and -not $WhatIfPreference) {
            throw "Start breaks the LOB app on $($arc.machineName): it fires a real alert and starts a real investigation. Pass -ApproveFault to confirm, or -WhatIf to preview."
        }
        $rows = @(Get-CheckRow)
        $blocking = @($rows | Where-Object { $_.status -eq 'fail' -or ($_.name -eq 'repair-script' -and $_.status -ne 'pass') })
        if ($blocking.Count) { throw "Nothing was changed. Fix these first: $(@($blocking | ForEach-Object { "$($_.name): $($_.detail)" }) -join '; ')." }
        @($rows | Where-Object { $_.status -eq 'pending' }) | ForEach-Object { Write-Warning "$($_.name): $($_.detail)" }
        try { $null = New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $agentGroup -AgentName $agentName }
        catch { throw "The SRE agent is not ready, so the fault would go unnoticed: $($_.Exception.Message) Wake it with Deploy-SreAgent.ps1 and check Test-SreReadiness.ps1 -DesiredState Active first." }
        if (-not $PSCmdlet.ShouldProcess($arc.machineName, "set the LOB app to $($arc.faultMode) (T11 fault)")) { return }
        # The run starts when the request goes out. The Azure CLI returns about two minutes after the script has ended, and an alert or a thread in that gap must still count.
        $requestedUtc = [DateTimeOffset]::UtcNow
        $result = & $lobScript -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath -Action InduceFault -FaultMode $arc.faultMode -Confirm:$false
        if (-not $result -or $result.GuestExitCode -ne 0) { throw 'The fault was not confirmed by the server. Run -Action Reset before you try again.' }
        $run = Initialize-ArcRun -Settings $arc -Started $requestedUtc
        $guest = ConvertTo-ArcRunView (Get-SreProperty $result 'Result')
        $null = Add-ArcRunEvent -Run $run -Name faultInduced -Utc $(if ($guest -and $guest.startUtc) { $guest.startUtc } else { $requestedUtc.ToString('o') })
        Save-ArcRun -RepoRoot $repoRoot -Run $run
        Write-Output "Run $($run.runId): $($arc.machineName) is set to $($arc.faultMode) at $(([DateTimeOffset]::Parse($run.events.faultInduced, [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss'))Z."
        Write-Output 'Next: -Action Status -Wait. The alert fires within about 10 minutes, the thread follows within a minute, and the card a few minutes after. A person clicks Approve in the SRE portal.'
    }
    'Status' {
        $run = Read-RunRecord
        if (-not $run) { throw 'No run is recorded. Start one with -Action Start.' }
        $context = Get-OptionalContext
        $location = [string](Get-SreProperty (Get-ArcMachineOrNull) 'location')
        $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        do {
            $sources = Read-Source -Run $run -Context $context
            foreach ($name in (Sync-ArcRun -Run $run -Settings $arc -Alerts $sources.alerts -Thread $sources.thread -Messages $sources.messages -RepairRun $sources.repairRun -MachineLocation $location)) {
                Write-Output ('{0}Z  {1}' -f ([DateTimeOffset]::Parse($run.events[$name], [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss'), $name)
            }
            Save-ArcRun -RepoRoot $repoRoot -Run $run
            $waiting = @($run.cards.Values | Where-Object { $_.pendingUtc -and -not $_.finalStatus })
            if (-not $Wait -or $waiting.Count -gt 0 -or [DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Seconds 10
        } while ($true)
        Format-ArcRun -Run $run | ForEach-Object { Write-Output $_ }
        foreach ($card in $waiting) {
            if ($card.ContainsKey('authorization') -and $card.authorization) {
                Write-Warning 'The thread waits on an authorization card, which is NOT the Approve card. The platform held a read the agent made (in the run seen, a read of the run command seconds after it was created, which answered 404) until a person authorizes it, and that read then runs as whoever authorizes it, not as the agent. docs/arc-server-room.md says more.'
                continue
            }
            if ($card.ok) { Write-Output 'An Approve card is waiting and it is the allowed repair: one PUT of a run command on the server that runs the installed script. A person clicks Approve in the SRE portal. This script never approves.' }
            else { Write-Warning "An Approve card is waiting and it is NOT the allowed repair ($(@($card.reasons) -join '; ')). Do not relay an approval: tell the agent to stop, or reset and delete the thread." }
        }
        if ($Wait -and -not $waiting.Count) { Write-Warning "No Approve card appeared within $TimeoutMinutes min." }
    }
    'Reset' {
        $run = Read-RunRecord -MoveAside
        $context = Get-OptionalContext
        $leftover = @(Get-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc | Where-Object { $_.name -clike "$($arc.runPrefix)*" })
        $runThreads = @()
        if ($run -and $context) { $runThreads = @((Get-FridayThreadObservation -Threads (Get-SreThreads -Context $context -Top 50) -Since ([string]$run.startedUtc) -AlertTitle $arc.alertTitle).all) }
        Write-Output "  app: set $($arc.machineName) back to Healthy and restart $($skin.labels.lobTaskName)"
        Write-Output "  run commands: delete $($leftover.Count) created by the agent$(if ($leftover.Count) { " ($(@($leftover | ForEach-Object { $_.name }) -join ', '))" }); the install marker and the T11 commands stay"
        Write-Output "  threads: $(if ($DeleteThreads) { "delete $($runThreads.Count) from this run" } else { "keep (use -DeleteThreads to remove $($runThreads.Count) and any stale Approve card)" })"
        if (-not $PSCmdlet.ShouldProcess($arc.machineName, 'Reset the server room scenario')) { return }
        $result = & $lobScript -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath -Action ResetFault -Confirm:$false
        if (-not $result -or $result.GuestExitCode -ne 0) { throw 'The reset was not confirmed by the server. Read the app with Invoke-LobArcAppOnArc.ps1 -Action Status.' }
        Write-Output 'The app is Healthy again.'
        foreach ($item in $leftover) { Remove-ArcRunCommand -SubscriptionId $SubscriptionId -Settings $arc -Name $item.name -Confirm:$false }
        $deleted = 0
        if ($DeleteThreads -and $context) {
            foreach ($thread in $runThreads) {
                if ($PSCmdlet.ShouldProcess($thread.id, 'Delete the investigation thread (a pending Approve card goes with it)')) {
                    $response = Remove-SreThread -Context $context -ThreadId $thread.id -Confirm:$false
                    if ($response.Status -ge 200 -and $response.Status -lt 300) { $deleted++ } else { Write-Warning "Thread $($thread.id) was not deleted (HTTP $($response.Status))." }
                }
            }
        } elseif (-not $DeleteThreads -and $run) {
            if (@($run.cards.Values | Where-Object { $_.pendingUtc -and -not $_.finalStatus }).Count) { Write-Warning 'A run card was still pending when you reset. It is stale: never approve it. Delete its thread with -DeleteThreads.' }
        }
        if ($run) {
            $run.state = 'reset'
            $run.resetUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-ArcRun -RepoRoot $repoRoot -Run $run
            $directory = Get-ArcDirectory -RepoRoot $repoRoot
            Move-Item -LiteralPath (Join-Path $directory 'current.json') -Destination (Join-Path $directory "run-$($run.runId).json") -Force
        }
        Write-Output "Reset complete: the app is Healthy, $($leftover.Count) run command(s) removed, $deleted thread(s) deleted. The next run starts clean."
    }
}
