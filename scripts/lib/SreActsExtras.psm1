Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreDataPlane.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreReleaseExtras.psm1')

# What the ASK, MEMORY and PROACTIVE modules (SreActs.psm1) put on a running SRE agent besides its two read-only agents, which go through the
# core reconcile in SreConfiguration.psm1 like the T12 handler: the skills, the three scheduled tasks and the seeded notes.
# Writes are idempotent: read first, change only what differs, back up what was read, verify by reading again, never replay, never delete.
# Tasks are created by REST in Review mode and Off. Once a task exists the apply never changes whether it is on: that is yours to set.
# Notes are seeded only into an empty notes folder: the route's effect on files that are already there is not known.

function Get-SreActsTaskView {
    # One flat view of a task, whether the agent answers with the bare task or with the name/type/properties envelope.
    param([AllowNull()]$Item)
    if ($null -eq $Item) { return $null }
    $source = if ((Get-SreProperty $Item 'properties') -is [Collections.IDictionary]) { Get-SreProperty $Item 'properties' } else { $Item }
    $get = { param($key) $value = Get-SreProperty $source $key; if ($null -eq $value) { $value = Get-SreProperty $Item $key }; $value }
    $status = [string](& $get 'status')
    $flag = & $get 'isEnabled'
    [pscustomobject]@{
        id = [string](& $get 'id'); status = $status
        enabled = $(if ($status) { $status -eq 'Active' } elseif ($null -ne $flag) { [bool]$flag } else { $false })
        description = [string](& $get 'description'); cronExpression = [string](& $get 'cronExpression'); agentPrompt = ConvertTo-SreLf ([string](& $get 'agentPrompt'))
        agent = [string](& $get 'agent'); agentMode = [string](& $get 'agentMode')
        lastRun = [string](& $get 'lastExecutionTime'); nextRun = [string](& $get 'nextExecutionTime'); runs = [string](& $get 'executionCount'); threadId = [string](& $get 'threadId')
    }
}

function Get-SreActsObserved {
    <#
    .SYNOPSIS
    Reads the current state of the skills, tasks and notes the modules own. Read-only. A notes folder that cannot be read is reported, not assumed empty.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired)
    $acts = $Desired.acts
    $skills = @{}
    foreach ($skill in $acts.skills) {
        $item = Read-SreItem -Context $Context -Path "/api/v2/extendedAgent/skills/$([uri]::EscapeDataString($skill.name))" -What "Read skill $($skill.name)"
        $skills[$skill.name] = if ($item) { ConvertTo-SreHashtable $item.Body } else { $null }
    }
    $tasks = @{}
    foreach ($task in $acts.tasks) {
        $item = Read-SreItem -Context $Context -Path "/api/v2/extendedAgent/scheduledtasks/$([uri]::EscapeDataString($task.name))" -What "Read task $($task.name)"
        $tasks[$task.name] = if ($item) { ConvertTo-SreHashtable $item.Body } else { $null }
    }
    $notes = $null
    if ($acts.seed) {
        try { $notes = Get-SreNotesState -Context $Context } catch { $notes = [pscustomobject]@{ error = $_.Exception.Message; exists = $false; files = @() } }
    }
    [ordered]@{ skills = $skills; tasks = $tasks; notes = $notes }
}

function Get-SreActsPlan {
    <#
    .SYNOPSIS
    Compares the modules' skills, tasks and seed with what the agent holds and lists the writes an apply would make. Read-only.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Desired, [Parameter(Mandatory)][Collections.IDictionary]$Observed)
    $acts = $Desired.acts
    $operations = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    foreach ($skill in $acts.skills) {
        $found = $Observed.skills[$skill.name]
        $properties = if ($found -and $found['properties']) { $found['properties'] } else { @{} }
        $same = $found -and [string]$properties['description'] -ceq $skill.description -and (ConvertTo-SreLf $properties['skillContent']) -ceq $skill.content -and @($properties['tools'] | Where-Object { $null -ne $_ }).Count -eq 0
        if (-not $same) {
            $operations.Add(@{ name = "skill:$($skill.name)"; reason = $(if ($found) { 'update' } else { 'create' }); method = 'Put'; path = "/api/v2/extendedAgent/skills/$([uri]::EscapeDataString($skill.name))"
                body = @{ name = $skill.name; type = 'Skill'; tags = @(); properties = @{ name = $skill.name; description = $skill.description; tools = @(); skillContent = $skill.content; additionalFiles = @() } }
                before = $found })
        }
    }
    foreach ($task in $acts.tasks) {
        $view = Get-SreActsTaskView $Observed.tasks[$task.name]
        $same = $view -and $view.cronExpression -ceq $task.cronExpression -and $view.agentPrompt -ceq (ConvertTo-SreLf $task.agentPrompt) -and $view.agent -ceq $task.agent -and
            $view.agentMode -ieq 'Review' -and $view.description -ceq $task.description
        if (-not $same) {
            $enabled = if ($view) { [bool]$view.enabled } else { [bool]$task.enabled }
            $operations.Add(@{ name = "task:$($task.name)"; reason = $(if ($view) { 'update (on or off stays as it is)' } else { 'create (Off)' }); method = 'Put'; path = "/api/v2/extendedAgent/scheduledtasks/$([uri]::EscapeDataString($task.name))"
                body = @{ name = $task.name; type = 'ScheduledTask'; tags = @(); properties = @{
                    name = $task.name; description = $task.description; cronExpression = $task.cronExpression; agentPrompt = $task.agentPrompt
                    agent = $task.agent; agentMode = 'Review'; isEnabled = $enabled } }
                before = $Observed.tasks[$task.name] })
        }
    }
    if ($acts.seed) {
        $state = $Observed.notes
        if ($state -and (Get-SreProperty $state 'error')) {
            $notes.Add("The notes folder could not be read ($($state.error)), so the seed was not applied. Nothing was written to it.")
        } elseif ($state -and @($state.files).Count) {
            $notes.Add("The agent already has $(@($state.files).Count) notes file(s); the seed is only put into an empty notes folder, so they are left as they are.")
        } else {
            $operations.Add(@{ name = 'seed:notes'; reason = "put $(@($acts.seed.files.Keys).Count) file(s) from the $($acts.seed.source) seed into the empty notes folder"; method = 'Post'; kind = 'notes'
                files = $acts.seed.files; before = $state })
        }
    }
    @{ operations = @($operations.ToArray()); notes = @($notes.ToArray()) }
}

function Invoke-SreActs {
    <#
    .SYNOPSIS
    Applies the skills, tasks and seed of the ASK, MEMORY and PROACTIVE modules. Run it after the core reconcile has created the two read-only agents.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired,
        [Parameter(Mandatory)][string]$BackupPath, [ValidateRange(1, 600)][int]$ReadBackSeconds = 90
    )
    $observed = Get-SreActsObserved -Context $Context -Desired $Desired
    $plan = Get-SreActsPlan -Desired $Desired -Observed $observed
    foreach ($note in $plan.notes) { Write-Host $note }
    if (-not $plan.operations.Count) { return @{ changed = $false; verified = $true; operations = @(); notes = $plan.notes } }
    if (-not $PSCmdlet.ShouldProcess($Context.resourceId, "Back up and apply $($plan.operations.Count) setting(s) for $($Desired.acts.modules -join ', '): $(@($plan.operations | ForEach-Object { $_.name }) -join ', ') (Review mode, tasks Off, nothing is deleted)")) {
        return @{ changed = $false; verified = $false; preview = $plan; notes = $plan.notes }
    }
    $fullPath = [IO.Path]::GetFullPath("$BackupPath.acts.json")
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backups contain runtime configuration; choose a path outside the repository.' }
    if (-not (Test-Path -LiteralPath (Split-Path $fullPath -Parent) -PathType Container)) { throw 'Backup parent directory must already exist.' }
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($observed | ConvertTo-Json -Depth 30))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    $seedState = 'not needed'
    foreach ($operation in $plan.operations) {
        if ($operation.name -eq 'seed:notes') {
            $response = Send-SreNotes -Context $Context -Files $operation.files
            Assert-SreDataSuccess -Response $response -What 'Seed the notes'
            Write-Host "  applied $($operation.name) (HTTP $($response.Status), $($response.Ms) ms)"
            $seedState = 'accepted'
            continue
        }
        $response = Invoke-SreData -Context $Context -Method PUT -Path $operation.path -Body $operation.body
        Assert-SreDataSuccess -Response $response -What "Apply $($operation.name)"
        Write-Host "  applied $($operation.name) (HTTP $($response.Status), $($response.Ms) ms)"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadBackSeconds)
    do {
        $after = Get-SreActsPlan -Desired $Desired -Observed (Get-SreActsObserved -Context $Context -Desired $Desired)
        # The seed is checked last and softly: its route is not proven live, so a seed that does not show up is reported, never a reason to fail the rest.
        $pending = @($after.operations | Where-Object { $_.name -ne 'seed:notes' })
        $seedPending = @($after.operations | Where-Object { $_.name -eq 'seed:notes' }).Count -gt 0
        if (-not $pending.Count -and (-not $seedPending -or $seedState -ne 'accepted')) { if ($seedState -eq 'accepted') { $seedState = 'verified' }; break }
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($pending.Count) {
                throw "Read-back does not show $(@($pending | ForEach-Object { $_.name }) -join ', ') after $ReadBackSeconds s. Nothing was replayed; inspect with Initialize-SreConfiguration.ps1 -Inspect and the backup before you apply again."
            }
            $seedState = 'unverified'
            Write-Warning "The notes upload was accepted but no notes file appeared within $ReadBackSeconds s. Check with Export-SreAgentFiles.ps1 -Source Notes -List; the upload was not repeated."
            break
        }
        Start-Sleep -Seconds $(if ($ReadBackSeconds -lt 10) { 1 } else { 5 })
    } while ($true)
    @{ changed = $true; verified = $true; seed = $seedState; backupPath = $fullPath; operations = @($plan.operations | ForEach-Object { $_.name }); notes = $plan.notes }
}

function Find-SreThreadId {
    # The thread a run-now call started: a threadId anywhere in the answer. The answer's shape is read from a live call, not from a contract.
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType] -or $Depth -gt 4) { return '' }
    $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) {
        $child = Get-SreProperty $Value ([string]$name)
        if ($name -ieq 'threadId' -and $child -is [string] -and $child) { return $child }
    }
    foreach ($name in $names) {
        $found = Find-SreThreadId -Value (Get-SreProperty $Value ([string]$name)) -Depth ($Depth + 1)
        if ($found) { return $found }
    }
    return ''
}

function Wait-SreThreadIdle {
    <#
    .SYNOPSIS
    Polls a thread until the agent is idle and no new message has arrived for one more poll, or the timeout passes. Returns idle, messages, state and seconds.
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$ThreadId,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 900, [ValidateRange(1, 60)][int]$PollSeconds = 10
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $count = 0
    $state = ''
    $last = -1
    do {
        try {
            $read = Get-SreThreadMessages -Context $Context -ThreadId $ThreadId
            $state = [string]$read.State
            $count = @($read.Messages).Count
            if ($state -eq 'Idle' -and $count -gt 0 -and $count -eq $last) { return [pscustomobject]@{ idle = $true; messages = $count; state = $state; seconds = [int]$clock.Elapsed.TotalSeconds } }
            $last = if ($state -eq 'Idle') { $count } else { -1 }
        } catch {
            # The thread can take a moment to appear after a run-now call.
            $last = -1
        }
        Start-Sleep -Seconds $PollSeconds
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    [pscustomobject]@{ idle = $false; messages = $count; state = $state; seconds = [int]$clock.Elapsed.TotalSeconds }
}

function Invoke-SreActsTask {
    <#
    .SYNOPSIS
    Status, Run, Enable or Disable for the PROACTIVE scheduled tasks. Behind Invoke-ScheduledTask.ps1.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string[]]$TaskNames,
        [Parameter(Mandatory)][ValidateSet('Status', 'Run', 'Enable', 'Disable')][string]$Action,
        [string]$Name, [switch]$Wait, [ValidateRange(1, 60)][int]$TimeoutMinutes = 15, [ValidateRange(1, 60)][int]$PollSeconds = 10, [ValidateRange(1, 300)][int]$ReadBackSeconds = 60
    )
    if ($Action -ne 'Status' -and -not $Name) { throw "Say which task with -Name: $($TaskNames -join ', ')." }
    if ($Name -and $Name -notin $TaskNames) { throw "Unknown task '$Name'. The tasks are: $($TaskNames -join ', ')." }
    $readTask = {
        param([string]$TaskName)
        $item = Read-SreItem -Context $Context -Path "/api/v2/extendedAgent/scheduledtasks/$([uri]::EscapeDataString($TaskName))" -What "Read task $TaskName"
        if (-not $item) { return $null }
        return Get-SreActsTaskView (ConvertTo-SreHashtable $item.Body)
    }
    if ($Action -eq 'Status') {
        foreach ($taskName in $TaskNames) {
            $view = & $readTask $taskName
            if (-not $view) { Write-Host ("{0,-22} not on the agent. Run Initialize-SreConfiguration.ps1 -Apply." -f $taskName); continue }
            Write-Host ("{0,-22} {1,-4} schedule '{2}' (UTC, not proven)  runs {3}  last {4}  next {5}  mode {6}" -f $taskName, $(if ($view.enabled) { 'On' } else { 'Off' }), $view.cronExpression,
                $(if ($view.runs) { $view.runs } else { 0 }), $(if ($view.lastRun) { $view.lastRun } else { 'never' }), $(if ($view.nextRun -and $view.enabled) { $view.nextRun } else { 'not scheduled' }), $view.agentMode)
        }
        return
    }
    $view = & $readTask $Name
    if (-not $view) { throw "Task '$Name' is not on the agent. Run Initialize-SreConfiguration.ps1 -Apply first." }
    if ($Action -eq 'Run') {
        $id = $view.id
        if (-not $id) {
            $list = Invoke-SreData -Context $Context -Method GET -Path '/api/v1/scheduledtasks'
            Assert-SreDataSuccess -Response $list -What 'List scheduled tasks'
            $match = @(Get-SreProperty $list.Body 'value' | Where-Object { [string](Get-SreProperty $_ 'name') -ceq $Name }) | Select-Object -First 1
            $id = if ($match) { [string](Get-SreProperty $match 'id') } else { '' }
        }
        if (-not $id -or $id -notmatch '^[A-Za-z0-9_.:-]+$') { throw "The agent returned no usable ID for task '$Name'." }
        if (-not $PSCmdlet.ShouldProcess($Name, 'run the scheduled task now (it starts one agent thread, which spends AAUs)')) { return }
        $response = Invoke-SreData -Context $Context -Method POST -Path "/api/v1/scheduledtasks/$id/execute" -Body @{}
        if ($response.Status -lt 200 -or $response.Status -ge 300) {
            $hint = if (-not $view.enabled) { ' The task is Off. If the agent will not run an Off task, use -Action Enable, then -Action Run, then -Action Disable.' } else { '' }
            throw "Run-now for '$Name' failed: HTTP $($response.Status).$hint"
        }
        $threadId = Find-SreThreadId -Value $response.Body
        Write-Host "Started '$Name' (HTTP $($response.Status), $($response.Ms) ms). Thread: $(if ($threadId) { $threadId } else { 'not named in the answer; look in the portal under Threads' })."
        $waited = $null
        if ($Wait -and $threadId) {
            $waited = Wait-SreThreadIdle -Context $Context -ThreadId $threadId -TimeoutSeconds ($TimeoutMinutes * 60) -PollSeconds $PollSeconds
            if ($waited.idle) { Write-Host "The agent is idle after $($waited.seconds) s with $($waited.messages) messages." }
            else { Write-Warning "The thread was not idle after $TimeoutMinutes min (state '$($waited.state)', $($waited.messages) messages). It is still running; nothing was cancelled." }
            if ($Name -eq 'governance-deck') { Write-Host "If it built the deck: Export-SreAgentFiles.ps1 -Source Thread -ThreadId $threadId -OutputPath <a folder outside the repository>" }
        }
        return [pscustomobject]@{ task = $Name; threadId = $threadId; status = [int]$response.Status; waited = $waited }
    }
    $want = $Action -eq 'Enable'
    $label = if ($want) { 'On' } else { 'Off' }
    if ($view.enabled -eq $want) { Write-Host "'$Name' is already $label."; return }
    if (-not $PSCmdlet.ShouldProcess($Name, "turn the schedule $label$(if ($want) { ' (it will start agent threads by itself)' })")) { return }
    # The task's own schedule and prompt are sent back as they are on the agent, so a change made in the portal is kept.
    $body = @{ name = $Name; type = 'ScheduledTask'; tags = @(); properties = @{
        name = $Name; description = $view.description; cronExpression = $view.cronExpression; agentPrompt = $view.agentPrompt
        agent = $view.agent; agentMode = 'Review'; isEnabled = $want } }
    $response = Invoke-SreData -Context $Context -Method PUT -Path "/api/v2/extendedAgent/scheduledtasks/$([uri]::EscapeDataString($Name))" -Body $body
    Assert-SreDataSuccess -Response $response -What "Turn '$Name' $label"
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadBackSeconds)
    do {
        $after = & $readTask $Name
        if ($after -and $after.enabled -eq $want) { Write-Host "'$Name' is now $label."; return }
        Start-Sleep -Seconds $(if ($PollSeconds -lt 3) { 1 } else { 3 })
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The agent does not show '$Name' as $label after $ReadBackSeconds s. The PUT was not repeated; check Invoke-ScheduledTask.ps1 -Action Status."
}

function Resolve-SreExportPath {
    # The full path of an export folder. Files from the agent name your resources, so only a full path outside the repository is accepted.
    param([Parameter(Mandatory)][string]$OutputPath)
    if (-not [IO.Path]::IsPathFullyQualified($OutputPath)) { throw '-OutputPath must be a full path.' }
    $output = [IO.Path]::GetFullPath($OutputPath).TrimEnd('\', '/')
    $repoFull = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (($output + [IO.Path]::DirectorySeparatorChar).StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The files can name your resources: choose an -OutputPath outside the repository.'
    }
    return $output
}

function Export-SreAgentFolder {
    <#
    .SYNOPSIS
    Lists (-List) or downloads every file under one folder of the agent's workspace into a local folder. It never overwrites a file and never writes outside
    that folder. Returns exists, files, written, skipped and bytes; a folder that is not there is exists = $false, and a failed read throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Folder, [string]$OutputPath, [switch]$List)
    $output = $null
    if (-not $List) {
        if (-not $OutputPath) { throw 'Give an output folder outside the repository, or list only.' }
        $output = Resolve-SreExportPath -OutputPath $OutputPath
    }
    if (-not (Test-SreWorkspaceFolder -Context $Context -Path $Folder)) { return [pscustomobject]@{ exists = $false; files = @(); written = 0; skipped = 0; bytes = 0L } }
    $files = @(Get-SreWorkspaceFiles -Context $Context -Path $Folder)
    $written = 0
    $skipped = 0
    $total = 0L
    if (-not $List -and $files.Count) {
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        foreach ($file in $files) {
            $target = [IO.Path]::GetFullPath((Join-Path $output ($file.relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
            if (-not $target.StartsWith($output + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to write outside the output folder: '$($file.relativePath)'." }
            if (Test-Path -LiteralPath $target) { Write-Warning "Exists, not overwritten: $($file.relativePath)"; $skipped++; continue }
            $bytes = Get-SreWorkspaceFile -Context $Context -Path $file.path
            if ($file.relativePath -like '*.pptx' -and -not ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)) {
                Write-Warning "$($file.relativePath) does not start like a PowerPoint (zip) file: the file API may have returned text. Check the saved file before you use it."
            }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            $written++
            $total += $bytes.Length
        }
    }
    [pscustomobject]@{ exists = $true; files = $files; written = $written; skipped = $skipped; bytes = $total }
}

function Get-SreActsDataChecks {
    <#
    .SYNOPSIS
    Readiness rows for the modules, from reads only: skills and tasks (required), the Off or On state and the seeded notes (informational).
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Desired)
    $acts = $Desired.acts
    $observed = Get-SreActsObserved -Context $Context -Desired $Desired
    $plan = Get-SreActsPlan -Desired $Desired -Observed $observed
    $row = { param($id, $status, $required, $expected, $observedValue, $message) @{ id = $id; resourceId = $Context.resourceId; required = $required; status = $status; expected = $expected; observed = $observedValue; message = $message } }
    $rows = [Collections.Generic.List[object]]::new()
    if (@($acts.skills).Count) {
        $pending = @($plan.operations | Where-Object { $_.name -like 'skill:*' } | ForEach-Object { $_.name })
        $rows.Add((& $row 'ACTS-skills' $(if ($pending.Count) { 'fail' } else { 'pass' }) $true 'Every skill of the turned-on modules present and current' $pending 'Compares each skill file with the agent.'))
    }
    if (@($acts.tasks).Count) {
        $pending = @($plan.operations | Where-Object { $_.name -like 'task:*' } | ForEach-Object { $_.name })
        $rows.Add((& $row 'ACTS-tasks' $(if ($pending.Count) { 'fail' } else { 'pass' }) $true 'Three scheduled tasks present, current and in Review mode' $pending 'Compares each task with its file. A task that is not in Review mode counts as different.'))
        $states = [ordered]@{}
        foreach ($task in $acts.tasks) { $view = Get-SreActsTaskView $observed.tasks[$task.name]; $states[$task.name] = if ($view) { if ($view.enabled) { 'On' } else { 'Off' } } else { 'absent' } }
        $rows.Add((& $row 'ACTS-schedules' 'pass' $false 'Tasks Off unless you turned a schedule on' $states 'Informational. An On task starts agent threads by itself, and each one spends AAUs. Turn one on or off with Invoke-ScheduledTask.ps1.'))
    }
    if ($acts.seed) {
        $state = $observed.notes
        $names = if ($state) { @($state.files | ForEach-Object { $_.relativePath }) } else { @() }
        $ok = 'overview.md' -in $names
        $rows.Add((& $row 'ACTS-notes' $(if ($ok) { 'pass' } else { 'pending' }) $false 'overview.md in the notes folder' $names 'Informational. A hand-written overview is loaded into every conversation; the agent may rewrite it as it learns. Run the apply to seed an empty folder.'))
    }
    return @($rows.ToArray())
}

Export-ModuleMember -Function Get-SreActsTaskView, Get-SreActsObserved, Get-SreActsPlan, Invoke-SreActs, Find-SreThreadId, Wait-SreThreadIdle, Invoke-SreActsTask, Resolve-SreExportPath, Export-SreAgentFolder, Get-SreActsDataChecks
