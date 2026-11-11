Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreDataPlane.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreFridayRelease.psm1')

# Helpers for Invoke-ArcServerRoom.ps1, the runner for the ARC module (Act 6, the server room): Prepare the repair script on the Arc server, Check, break
# the LOB app (Start), Status and Reset. Pure helpers take data in and return data out so the offline tests can feed them recorded shapes; the few Azure
# calls are small and named. Nothing here approves a card: a person clicks Approve in the SRE portal.

$script:EventOrder = @('faultInduced', 'alertFired', 'threadCreated', 'firstAgentMessage', 'cardPending', 'cardCompleted', 'repairStarted', 'repairEnded', 'alertResolved')
$script:EventLabels = @{
    faultInduced = 'fault induced on the server'; alertFired = 'alert fired'; threadCreated = 'investigation thread created'; firstAgentMessage = 'first agent message'
    cardPending = 'Approve card pending'; cardCompleted = 'card completed (first seen)'; repairStarted = 'repair run command started'; repairEnded = 'repair run command ended'
    alertResolved = 'alert resolved'
}

function Get-ArcClip {
    # One line with the whitespace collapsed, cut to a length: how a command or an output line appears in the record and the report.
    param([AllowNull()]$Value, [int]$Length = 300)
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value -replace '\s+', ' ').Trim()
    if ($text.Length -gt $Length) { return $text.Substring(0, $Length) + '...' }
    return $text
}

function Get-ArcDirectory {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $directory = Join-Path $RepoRoot '.local\arc-server-room'
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    return $directory
}

function Read-ArcRun {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path (Get-ArcDirectory -RepoRoot $RepoRoot) 'current.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $run = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    # ConvertFrom-Json turns ISO strings into local DateTime values. Put every time back to a UTC ISO string.
    foreach ($key in 'startedUtc', 'resetUtc') { if ($run.ContainsKey($key)) { $run[$key] = ConvertTo-FridayUtc $run[$key] } }
    foreach ($name in @($run.events.Keys)) { $run.events[$name] = ConvertTo-FridayUtc $run.events[$name] }
    foreach ($card in @($run.cards.Values)) { foreach ($key in 'pendingUtc', 'finalUtc') { if ($card.ContainsKey($key)) { $card[$key] = ConvertTo-FridayUtc $card[$key] } } }
    return $run
}

function Save-ArcRun {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][Collections.IDictionary]$Run)
    $path = Join-Path (Get-ArcDirectory -RepoRoot $RepoRoot) 'current.json'
    # Written beside the record and renamed over it, so a crash mid-write cannot leave a truncated file. Local bookkeeping, whatever -WhatIf says.
    $temporary = "$path.tmp"
    [IO.File]::WriteAllText($temporary, ($Run | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force -WhatIf:$false -Confirm:$false
}

function Initialize-ArcRun {
    # -Started is when the fault request went out. Status ignores alerts and threads from before it, so it must not be later than the fault itself.
    param([Parameter(Mandatory)][Collections.IDictionary]$Settings, [DateTimeOffset]$Started = [DateTimeOffset]::UtcNow)
    @{
        runId = '{0}-{1}' -f $Started.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
        state = 'running'; startedUtc = $Started.ToString('o'); machine = $Settings.machineName; faultMode = $Settings.faultMode
        events = @{}; cards = @{}; threadId = $null
    }
}

function Add-ArcRunEvent {
    # Records the first time an event is seen. Returns $true when it is new.
    param([Parameter(Mandatory)][Collections.IDictionary]$Run, [Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Utc)
    if ($Name -notin $script:EventOrder) { throw "Unknown run event '$Name'." }
    if ([string]::IsNullOrWhiteSpace($Utc) -or $Run.events.ContainsKey($Name)) { return $false }
    $Run.events[$Name] = ([DateTimeOffset]::Parse($Utc, [Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime().ToString('o')
    return $true
}

function Get-ArcCardCommand {
    <#
    .SYNOPSIS
    The az command a card would run, from the card's originalFunctionCall: the tool's arguments as JSON text, or already parsed. Anything else is returned as it is.
    #>
    param([AllowNull()]$Call)
    if ($null -eq $Call) { return '' }
    $parsed = $Call
    if ($Call -is [string]) {
        try { $parsed = $Call | ConvertFrom-Json } catch { return $Call }
    }
    $command = [string](Get-SreProperty (Get-SreProperty $parsed 'Arguments') 'command')
    if ($command) { return $command }
    return $(if ($Call -is [string]) { $Call } else { '' })
}

function Split-ArcShellWord {
    <#
    .SYNOPSIS
    Splits a command line into words the way bash would, without running or expanding anything. Single quotes keep every character; inside double quotes
    a backslash escapes a quote, a backslash, a dollar sign or a backtick. Anything a shell would expand or chain (variables, substitutions, pipes,
    redirects, semicolons, ampersands) sets 'unsafe': what such a command runs cannot be read from its text.
    #>
    param([AllowNull()][string]$Line)
    $words = [Collections.Generic.List[string]]::new()
    $word = [Text.StringBuilder]::new()
    $inWord = $false
    $quote = ''
    $unsafe = $false
    $text = [string]$Line
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($quote -eq "'") {
            if ($c -eq "'") { $quote = '' } else { $null = $word.Append($c) }
            continue
        }
        if ($quote -eq '"') {
            if ($c -eq '"') { $quote = '' }
            elseif ($c -eq '\' -and $i + 1 -lt $text.Length -and $text[$i + 1] -in @('"', '\', '$', '`')) { $i++; $null = $word.Append($text[$i]) }
            elseif ($c -in @('$', '`')) { $unsafe = $true; $null = $word.Append($c) }
            else { $null = $word.Append($c) }
            continue
        }
        if ($c -eq "'" -or $c -eq '"') { $quote = [string]$c; $inWord = $true; continue }
        if ($c -eq '\' -and $i + 1 -lt $text.Length) { $i++; $null = $word.Append($text[$i]); $inWord = $true; continue }
        if ([char]::IsWhiteSpace($c)) {
            if ($inWord) { $words.Add($word.ToString()); $null = $word.Clear(); $inWord = $false }
            if ($c -eq "`n") { $unsafe = $true }
            continue
        }
        if ($c -in @('$', '`', ';', '|', '&', '<', '>', '(', ')')) { $unsafe = $true }
        $null = $word.Append($c)
        $inWord = $true
    }
    if ($quote) { $unsafe = $true }
    if ($inWord) { $words.Add($word.ToString()) }
    [pscustomobject]@{ words = @($words.ToArray()); unsafe = $unsafe }
}

function Test-ArcRepairCommand {
    <#
    .SYNOPSIS
    Checks the az command on a pending card against what the ARC module allows: one PUT of one run command on the target machine, named with the repair
    prefix, whose body holds only the repair script's installed path. Reads text only; it never runs the command.
    #>
    param([AllowNull()][string]$Command, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [string]$MachineLocation = '')
    $reasons = [Collections.Generic.List[string]]::new()
    $name = ''
    $location = ''
    $split = Split-ArcShellWord -Line $Command
    $words = @($split.words)
    if (-not $words.Count) { $reasons.Add('there is no command text to read') }
    elseif ($split.unsafe) { $reasons.Add('it uses shell syntax (variables, substitutions, pipes or redirects), so what it runs cannot be read from its text') }
    elseif ($words.Count -lt 3 -or $words[0] -cne 'az' -or $words[1] -cne 'rest') { $reasons.Add('it is not an az rest command') }
    else {
        $options = @{}
        for ($i = 2; $i -lt $words.Count; $i++) {
            $word = $words[$i]
            $flag = $word
            $value = $null
            if ($word.StartsWith('--') -and $word.Contains('=')) { $flag = $word.Substring(0, $word.IndexOf('=')); $value = $word.Substring($word.IndexOf('=') + 1) }
            switch -Regex ($flag) {
                '^(--method|-m|--url|--uri|-u|--body|-b|--output|-o|--subscription)$' {
                    if ($null -eq $value) { if ($i + 1 -ge $words.Count) { $reasons.Add("$flag has no value"); break }; $i++; $value = $words[$i] }
                    $key = switch -Regex ($flag) { '^(--method|-m)$' { 'method' }; '^(--url|--uri|-u)$' { 'url' }; '^(--body|-b)$' { 'body' }; default { 'other' } }
                    if ($key -ne 'other' -and $options.ContainsKey($key)) { $reasons.Add("$flag is given twice") }
                    $options[$key] = $value
                }
                '^--headers$' {
                    # One or more values follow, up to the next option. Only a JSON content type or accept header passes: it changes nothing about what runs.
                    $headerValues = @(if ($null -ne $value) { $value })
                    while ($null -eq $value -and $i + 1 -lt $words.Count -and -not $words[$i + 1].StartsWith('-')) { $i++; $headerValues += $words[$i] }
                    if (-not $headerValues.Count) { $reasons.Add('--headers has no value') }
                    foreach ($header in $headerValues) { if ($header -notmatch '^(Content-Type|Accept)=application/json$') { $reasons.Add("the header '$header' is not one the check allows") } }
                }
                '^--only-show-errors$' { }
                default { $reasons.Add("unexpected argument '$word'") }
            }
        }
        if (-not $options.ContainsKey('method') -or $options['method'] -ine 'put') { $reasons.Add('the method is not PUT') }
        $prefix = "https://management.azure.com$($Settings.machineId)/runCommands/"
        $url = if ($options.ContainsKey('url')) { [string]$options['url'] } else { '' }
        if (-not $url.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $reasons.Add("the URL is not a run command on $($Settings.machineName)") }
        else {
            $rest = $url.Substring($prefix.Length)
            $name = ($rest -split '\?', 2)[0]
            $query = if ($rest.Contains('?')) { ($rest -split '\?', 2)[1] } else { '' }
            if ($name -cnotmatch ('^' + [regex]::Escape($Settings.runPrefix) + '[A-Za-z0-9._-]{1,40}$')) { $reasons.Add("the run command name must be $($Settings.runPrefix) plus a short time stamp") }
            if ($query -cne "api-version=$($Settings.apiVersion)") { $reasons.Add("the query must be exactly api-version=$($Settings.apiVersion)") }
        }
        $bodyText = if ($options.ContainsKey('body')) { [string]$options['body'] } else { '' }
        if (-not $bodyText) { $reasons.Add('there is no body') }
        elseif ($bodyText.StartsWith('@')) { $reasons.Add('the body is read from a file, so it cannot be checked here') }
        else {
            $body = $null
            try { $body = $bodyText | ConvertFrom-Json -AsHashtable -Depth 10 } catch { $reasons.Add('the body is not valid JSON') }
            if ($body -is [Collections.IDictionary]) {
                $extra = @($body.Keys | Where-Object { $_ -cnotin @('location', 'properties') })
                if ($extra.Count) { $reasons.Add("the body has keys it should not: $($extra -join ', ')") }
                $location = [string]$body['location']
                if (-not $location) { $reasons.Add('the body has no location') }
                elseif ($MachineLocation -and ($location -replace '\s', '').ToLowerInvariant() -ne ($MachineLocation -replace '\s', '').ToLowerInvariant()) { $reasons.Add("the location is $location, not the machine's $MachineLocation") }
                $properties = $body['properties']
                if ($properties -isnot [Collections.IDictionary]) { $reasons.Add('the body has no properties') }
                else {
                    $extra = @($properties.Keys | Where-Object { $_ -cnotin @('asyncExecution', 'timeoutInSeconds', 'source') })
                    if ($extra.Count) { $reasons.Add("properties has keys it should not: $($extra -join ', ')") }
                    if ($properties.Contains('asyncExecution') -and ($properties['asyncExecution'] -isnot [bool] -or $properties['asyncExecution'])) { $reasons.Add('asyncExecution must be false') }
                    if ($properties.Contains('timeoutInSeconds') -and ($properties['timeoutInSeconds'] -isnot [long] -or $properties['timeoutInSeconds'] -lt 1 -or $properties['timeoutInSeconds'] -gt $Settings.timeoutSeconds)) { $reasons.Add("timeoutInSeconds must be 1 to $($Settings.timeoutSeconds)") }
                    $source = $properties['source']
                    if ($source -isnot [Collections.IDictionary] -or @($source.Keys).Count -ne 1 -or -not $source.Contains('script')) { $reasons.Add('source must hold only a script') }
                    elseif ([string]$source['script'] -cne $Settings.repairPath) { $reasons.Add("the script is not exactly $($Settings.repairPath)") }
                }
            } elseif ($null -ne $body -or $reasons.Count -eq 0) { $reasons.Add('the body is not a JSON object') }
        }
    }
    [pscustomobject]@{ ok = ($reasons.Count -eq 0); reasons = @($reasons.ToArray()); runName = $name; location = $location }
}

function Get-ArcRepairCard {
    <#
    .SYNOPSIS
    Every Azure CLI write card in a thread that waits for a person or touches a run command, with its status, when it was created, and whether its
    command is the one the ARC module allows. A card for anything else is listed too, as not allowed. Reads only.
    #>
    param([AllowNull()][object[]]$Messages, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [string]$MachineLocation = '')
    foreach ($message in @($Messages)) {
        $cli = Get-SreProperty $message 'azCliExecution'
        if (-not $cli) { continue }
        $command = Get-ArcCardCommand (Get-SreProperty $cli 'originalFunctionCall')
        $status = [string](Get-SreProperty $cli 'status')
        # A read (no method, or GET) never waits for a person. Only a pending card, or a write on a run command, is a card to judge.
        $isRead = $command -notmatch '(?i)(^|\s)(--method|-m)[ =]' -or $command -match '(?i)(^|\s)(--method|-m)[ =]+get(\s|$)'
        if ($status -ne 'Pending' -and ($isRead -or $command -notmatch 'runCommands')) { continue }
        $verdict = Test-ArcRepairCommand -Command $command -Settings $Settings -MachineLocation $MachineLocation
        [pscustomobject]@{
            id = [string](Get-SreProperty $cli 'id'); status = $status
            createdUtc = (ConvertTo-FridayUtc (Get-SreProperty $cli 'createdTimestamp')); startedUtc = (ConvertTo-FridayUtc (Get-SreProperty $cli 'startedTimestamp'))
            command = (Get-ArcClip $command 400); ok = $verdict.ok; reasons = @($verdict.reasons); runName = $verdict.runName
        }
    }
}

function ConvertTo-ArcRunView {
    # One flat view of a run command resource: the state, exit code, times, output and error of its last execution. The REST list and the CLI differ a little
    # in shape (the CLI may leave out the properties wrapper), so both are read.
    param([AllowNull()]$RunCommand)
    if ($null -eq $RunCommand) { return $null }
    $properties = Get-SreProperty $RunCommand 'properties'
    if ($null -eq $properties) { $properties = $RunCommand }
    $view = Get-SreProperty $properties 'instanceView'
    [pscustomobject]@{
        name = [string](Get-SreProperty $RunCommand 'name'); provisioningState = [string](Get-SreProperty $properties 'provisioningState')
        executionState = [string](Get-SreProperty $view 'executionState'); exitCode = (Get-SreProperty $view 'exitCode')
        startUtc = (ConvertTo-FridayUtc (Get-SreProperty $view 'startTime')); endUtc = (ConvertTo-FridayUtc (Get-SreProperty $view 'endTime'))
        output = [string](Get-SreProperty $view 'output'); error = [string](Get-SreProperty $view 'error')
        script = [string](Get-SreProperty (Get-SreProperty $properties 'source') 'script')
    }
}

function Sync-ArcRun {
    <#
    .SYNOPSIS
    Folds what the sources show into the run record: the first time each event is seen, each repair card's first-pending and final status, and the
    newest repair run command. Returns the names of the events that are new.
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Run, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [AllowNull()]$Alerts, [AllowNull()]$Thread,
        [AllowNull()][object[]]$Messages, [AllowNull()]$RepairRun, [string]$MachineLocation = '', [string]$ObservedUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
    )
    $new = [Collections.Generic.List[string]]::new()
    $note = { param($name, $utc) if (Add-ArcRunEvent -Run $Run -Name $name -Utc $utc) { $new.Add($name) } }
    if ($Alerts -and $Alerts.firedUtc) { & $note 'alertFired' $Alerts.firedUtc }
    if ($Alerts -and $Alerts.resolvedUtc -and $Run.events.ContainsKey('alertFired')) { & $note 'alertResolved' $Alerts.resolvedUtc }
    if ($Thread -and $Thread.id) {
        $Run.threadId = $Thread.id
        & $note 'threadCreated' $Thread.createdUtc
        $agentMessages = @(@($Messages) | Where-Object { [string](Get-SreProperty (Get-SreProperty $_ 'author') 'role') -eq 'SREAgent' })
        if ($agentMessages.Count) { & $note 'firstAgentMessage' (ConvertTo-FridayUtc (Get-SreProperty $agentMessages[0] 'timeStamp')) }
        foreach ($card in @(Get-ArcRepairCard -Messages $Messages -Settings $Settings -MachineLocation $MachineLocation)) {
            if (-not $card.id) { continue }
            if (-not $Run.cards.ContainsKey($card.id)) { $Run.cards[$card.id] = @{ command = $card.command; pendingUtc = $null; finalStatus = $null; finalUtc = $null; ok = $card.ok; reasons = @($card.reasons) } }
            $record = $Run.cards[$card.id]
            $record.command = $card.command; $record.ok = $card.ok; $record.reasons = @($card.reasons)
            if ($card.status -eq 'Pending') {
                if (-not $record.pendingUtc) { $record.pendingUtc = $(if ($card.createdUtc) { $card.createdUtc } else { $ObservedUtc }) }
                & $note 'cardPending' $record.pendingUtc
                continue
            }
            if (-not $record.pendingUtc -and $card.createdUtc) { $record.pendingUtc = $card.createdUtc; & $note 'cardPending' $record.pendingUtc }
            if ($record.finalUtc) { continue }
            $record.finalStatus = $(if ($card.status) { $card.status } else { 'Unknown' })
            # Running means a person approved it and it is executing; keep reading until it finishes.
            if ($card.status -eq 'Running') { continue }
            $record.finalUtc = $ObservedUtc
            if ($card.status -eq 'Completed') { & $note 'cardCompleted' $ObservedUtc }
        }
    }
    if ($RepairRun) {
        $Run.repairRun = @{ name = $RepairRun.name; executionState = $RepairRun.executionState; exitCode = $RepairRun.exitCode; output = $RepairRun.output; error = $RepairRun.error }
        & $note 'repairStarted' $RepairRun.startUtc
        if ($RepairRun.executionState -in @('Succeeded', 'Failed')) { & $note 'repairEnded' $RepairRun.endUtc }
    }
    return @($new.ToArray())
}

function Format-ArcRun {
    param([Parameter(Mandatory)][Collections.IDictionary]$Run)
    $lines = [Collections.Generic.List[string]]::new()
    $started = [DateTimeOffset]::Parse($Run.startedUtc, [Globalization.CultureInfo]::InvariantCulture)
    $zero = if ($Run.events.ContainsKey('faultInduced')) { [DateTimeOffset]::Parse($Run.events.faultInduced, [Globalization.CultureInfo]::InvariantCulture) } else { $null }
    $lines.Add("Run $($Run.runId) ($($Run.state)) since $($started.ToString('HH:mm:ss'))Z on $($Run.machine); fault $($Run.faultMode).")
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
        $verdict = if ($card.ok) { 'the command is the allowed repair' } else { "NOT the allowed repair: $(@($card.reasons) -join '; ')" }
        $lines.Add("  card [$state] $verdict")
        $lines.Add("    $($card.command)")
    }
    if ($Run.ContainsKey('repairRun') -and $Run.repairRun) {
        $repair = $Run.repairRun
        $lines.Add("  repair run command $($repair.name): $($repair.executionState), exit code $($repair.exitCode)")
        if ($repair.output) { $lines.Add("    output: $(Get-ArcClip $repair.output 200)") }
        if ($repair.error) { $lines.Add("    error: $(Get-ArcClip $repair.error 200)") }
    }
    return @($lines.ToArray())
}

function Get-ArcInstallScript {
    # The guest script that writes the repair script to the server and prints its SHA-256. The text travels as base64, so nothing in it needs quoting.
    param([Parameter(Mandatory)][string]$ScriptText, [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:\\[A-Za-z0-9_. \\-]+$')][string]$Path)
    $encoded = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($ScriptText))
    $lines = @(
        '$ErrorActionPreference = ''Stop'''
        "`$path = '$Path'"
        'New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null'
        "[IO.File]::WriteAllBytes(`$path, [Convert]::FromBase64String('$encoded'))"
        '"sha256=" + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()'
    )
    return ($lines -join "`n") + "`n"
}

function Get-ArcRunCommand {
    # Run commands on the target machine: all of them, or one by name. A list also returns each script, so it can be long, and it may leave out each
    # run's instanceView; a read by name has it. A name that does not exist reads as $null.
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Name)
    if ($Name) {
        $url = "https://management.azure.com$($Settings.machineId)/runCommands/${Name}?api-version=$($Settings.apiVersion)"
        try { $json = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json }
        catch { if ($_.Exception.Message -match 'ResourceNotFound|NotFound|\(404\)') { return $null }; throw }
        return (ConvertTo-ArcRunView $json)
    }
    $url = "https://management.azure.com$($Settings.machineId)/runCommands?api-version=$($Settings.apiVersion)"
    $json = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json
    @(Get-SreProperty $json 'value' | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-ArcRunView $_ })
}

function Remove-ArcRunCommand {
    # Deletes one run command the agent created. Only names with the repair prefix: the install marker and the T11 commands are never removed here.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch ('^' + [regex]::Escape($Settings.runPrefix) + '[A-Za-z0-9._-]{1,40}$')) { throw "Refusing to delete run command '$Name': only names that start with $($Settings.runPrefix) are removed." }
    $url = "https://management.azure.com$($Settings.machineId)/runCommands/${Name}?api-version=$($Settings.apiVersion)"
    if ($PSCmdlet.ShouldProcess("$($Settings.machineName)/$Name", 'delete the repair run command')) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('rest', '--method', 'delete', '--url', $url, '-o', 'none') | Out-Null
    }
}

function Get-ArcInstallState {
    # Whether the repair script on the server is the one in this repo: the install marker's output carries the SHA-256 of what it wrote.
    param([AllowNull()][object[]]$RunCommand, [Parameter(Mandatory)][Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$ExpectedSha256)
    $marker = @($RunCommand | Where-Object { $_ -and $_.name -ceq $Settings.installName }) | Select-Object -First 1
    if (-not $marker -or $marker.executionState -ne 'Succeeded') { return [pscustomobject]@{ state = 'missing'; detail = "not installed: run -Action Prepare" } }
    $found = [regex]::Match($marker.output, 'sha256=([0-9a-f]{64})')
    if ($found.Success -and $found.Groups[1].Value -ceq $ExpectedSha256) { return [pscustomobject]@{ state = 'installed'; detail = "installed, $($ExpectedSha256.Substring(0, 12)) matches this repo" } }
    return [pscustomobject]@{ state = 'stale'; detail = 'installed, but not the script in this repo: run -Action Prepare again' }
}

function Get-ArcCheckRow {
    <#
    .SYNOPSIS
    The rows of -Action Check from what ARM shows: the server, the repair script, leftover run commands and the alert rule. A row is pass, pending (do
    something first) or fail (do not start).
    #>
    param(
        [AllowNull()]$Machine, [AllowNull()][object[]]$AllMachine, [AllowNull()][object[]]$RunCommand, [Parameter(Mandatory)][Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$ExpectedSha256, [AllowNull()]$AlertRule, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $rows = [Collections.Generic.List[object]]::new()
    $row = { param($name, $status, $detail) $rows.Add([pscustomobject]@{ name = $name; status = $status; detail = $detail }) }
    if (-not $Machine) { & $row 'server' 'fail' "$($Settings.machineName) was not found in $($Settings.resourceGroup)" }
    elseif ([string](Get-SreProperty $Machine 'status') -ne 'Connected') { & $row 'server' 'fail' "$($Settings.machineName) is $(Get-SreProperty $Machine 'status'), not Connected: wake the Arc estate and wait" }
    else {
        $changed = ConvertTo-FridayUtc (Get-SreProperty $Machine 'lastStatusChange')
        $age = if ($changed) { [int][Math]::Floor(($Now - [DateTimeOffset]::Parse($changed, [Globalization.CultureInfo]::InvariantCulture)).TotalMinutes) } else { $null }
        if ($null -ne $age -and $age -lt 30) { & $row 'server' 'pending' "Connected for $age min. Telemetry from a freshly woken estate arrives late; allow 30 minutes before the act" }
        else { & $row 'server' 'pass' "$($Settings.machineName) is Connected$(if ($null -ne $age) { " (since $age min ago)" })" }
    }
    $install = Get-ArcInstallState -RunCommand $RunCommand -Settings $Settings -ExpectedSha256 $ExpectedSha256
    & $row 'repair-script' $(if ($install.state -eq 'installed') { 'pass' } else { 'pending' }) $install.detail
    $left = @($RunCommand | Where-Object { $_ -and $_.name -clike "$($Settings.runPrefix)*" })
    & $row 'leftover-run-commands' $(if ($left.Count) { 'pending' } else { 'pass' }) $(if ($left.Count) { "$($left.Count) from an earlier run ($(@($left | ForEach-Object { $_.name }) -join ', ')): -Action Reset removes them" } else { 'none' })
    $ruleEnabled = [bool]($AlertRule -and (Get-SreProperty (Get-SreProperty $AlertRule 'properties') 'enabled') -eq $true)
    & $row 'alert-rule' $(if ($ruleEnabled) { 'pass' } else { 'fail' }) $(if ($ruleEnabled) { 'the LOB alert rule is enabled' } else { 'the LOB alert rule is missing or disabled: run New-LobArcAppMonitorAlert.ps1' })
    $others = @($AllMachine | Where-Object { $_ -and [string](Get-SreProperty $_ 'status') -ne 'Connected' } | ForEach-Object { "$(Get-SreProperty $_ 'name') $(Get-SreProperty $_ 'status')" })
    $total = @($AllMachine | Where-Object { $_ }).Count
    & $row 'arc-machines' $(if ($others.Count) { 'pending' } else { 'pass' }) $(if ($others.Count) { "not Connected: $($others -join ', '). Act 1 questions about them need them Connected" } else { "all $total Connected" })
    return @($rows.ToArray())
}

Export-ModuleMember -Function Get-ArcDirectory, Read-ArcRun, Save-ArcRun, Initialize-ArcRun, Add-ArcRunEvent, Get-ArcCardCommand, Split-ArcShellWord, Test-ArcRepairCommand, Get-ArcRepairCard, ConvertTo-ArcRunView, Sync-ArcRun, Format-ArcRun, Get-ArcInstallScript, Get-ArcRunCommand, Remove-ArcRunCommand, Get-ArcInstallState, Get-ArcCheckRow
