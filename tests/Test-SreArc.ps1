#Requires -Version 7.4
# Offline checks for the ARC module (Act 6, the server room): what it renders (the skill, the repair script, the handler paragraph, the plan setting),
# the repair script's behavior with the scheduled-task cmdlets stood in, the check on the card's command, the run record and its helpers, and the real
# runner script against a copy of the repo scripts. Every Azure call is mocked and the data plane is never reached; nothing leaves this machine.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
foreach ($module in 'DemoSkin', 'SreRuntime', 'SreRelease', 'SreConfiguration', 'SreActs', 'SreDataPlane', 'SreFridayRelease', 'SreArcServerRoom') { Import-Module (Join-Path $root "scripts\lib\$module.psm1") -Force }
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ARC assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}

# This suite always mocks az, even when it is run on its own, so it can never reach Azure. The earlier mock's script block is kept by value:
# defining the function again updates the same function object in place, so a saved function object would end up holding this suite's mock.
$previousAzBlock = (Get-Item Function:\az -ErrorAction SilentlyContinue)?.ScriptBlock
$global:ArcAzCalls = [Collections.Generic.List[string]]::new()
$global:ArcAzExit = 0
$global:ArcAzResponder = { throw "Unexpected az call: $($args -join ' ')" }
function global:az {
    $global:ArcAzCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = $global:ArcAzExit
    & $global:ArcAzResponder @args
}
$temps = [Collections.Generic.List[string]]::new()
function New-TempPath([string]$Suffix = '') {
    $path = Join-Path ([IO.Path]::GetTempPath()) "arc-test-$([guid]::NewGuid())$Suffix"
    $temps.Add($path)
    $path
}
function New-ArcSkinFile {
    param([string[]]$Scenarios = @('T11', 'ARC'), [string]$AccessLevel = 'High')
    $path = New-TestT12SkinFile -Root $root -Scenarios $Scenarios
    $temps.Add($path)
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $data.sre.accessLevel = $AccessLevel
    [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20))
    $path
}

try {
    # --- Which skins turn it on, and what it renders ------------------------------------------------------------------------------------
    $skinPath = New-ArcSkinFile
    $skin = Get-DemoSkin -Path $skinPath -RepoRoot $root
    $desired = Get-SreActsDesired -Skin $skin -SubscriptionId $subscription
    $config = Get-SreArcConfig -Skin $skin -SubscriptionId $subscription
    Check ((@(Get-SreActsModules -Skin $skin) -join ',') -ceq 'ARC' -and (@($desired.modules) -join ',') -ceq 'ARC') 'A skin with T11 and ARC turns the module on'
    Check ((@($desired.skills | ForEach-Object { $_.name }) -join ',') -ceq 'arc-server-repair' -and @($desired.agents).Count -eq 0 -and @($desired.tasks).Count -eq 0 -and $null -eq $desired.seed) 'ARC alone is one skill: no agent, no task, no seed'
    Check ($desired.arc.repairSha256 -cmatch '^[0-9a-f]{64}$' -and $desired.arc.repairScript -notmatch "`r" -and $desired.arc.settings.repairPath -ceq 'C:\ProgramData\ArcSreLobApp\Repair-LobApp.ps1') 'The repair script has a SHA-256, LF line endings and a fixed path on the server'
    Check ($config.machineId -ceq "/subscriptions/$subscription/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/win-app-01" -and $config.runPrefix -ceq 'sre-repair-lob-' -and $config.installName -ceq 'arc-repair-install' -and $config.apiVersion -ceq '2024-11-10-preview') 'The settings name the server, the run command prefix, the install marker and the API version'
    Check ($config.runPrefix -notlike "$($config.installName)*" -and $config.installName -notlike "$($config.runPrefix)*") 'The agent prefix and the install marker cannot be mistaken for each other'
    $all = Get-SreActsDesired -Skin (Get-DemoSkin -Path (New-TestT12SkinFile -Root $root -Scenarios @('T12', 'ASK', 'MEMORY', 'PROACTIVE')) -RepoRoot $root) -SubscriptionId $subscription
    Check ($null -eq $all.arc -and (@($all.modules) -join ',') -ceq 'ASK,MEMORY,PROACTIVE') 'The other three modules do not turn ARC on'
    $withTwo = Get-SreActsDesired -Skin (Get-DemoSkin -Path (New-ArcSkinFile -Scenarios @('T11', 'ASK', 'ARC')) -RepoRoot $root) -SubscriptionId $subscription
    Check ((@($withTwo.skills | ForEach-Object { $_.name }) -join ',') -ceq 'estate-query,arc-server-repair') 'ARC adds its skill beside ASK'

    $noT11 = Get-DemoSkin -Path $skinPath -RepoRoot $root
    $noT11.sre.requiredScenarios = @('T09', 'ARC')
    Throws { Get-SreActsDesired -Skin $noT11 -SubscriptionId $subscription } 'must also require T11'
    $low = Get-DemoSkin -Path $skinPath -RepoRoot $root
    $low.sre.accessLevel = 'Low'
    Throws { Get-SreActsDesired -Skin $low -SubscriptionId $subscription } 'High access profile'
    Throws { Get-DemoSkin -Path (New-ArcSkinFile -Scenarios @('ARC')) -RepoRoot $root } 'schema|valid|contains'
    Throws { Get-DemoSkin -Path (New-ArcSkinFile -Scenarios @('T11', 'ARC') -AccessLevel 'Low') -RepoRoot $root } 'schema|valid|const'
    Check ((@(Get-SreActsModules -Skin (Get-DemoSkin -Path (New-ArcSkinFile -Scenarios @('T09', 'T11', 'ARC')) -RepoRoot $root)) -join ',') -ceq 'ARC') 'ARC loads beside T09 and T11'

    # --- The skill ----------------------------------------------------------------------------------------------------------------------
    $skill = $desired.skills[0]
    Check ($skill.description.Length -ge 40 -and $skill.description.Length -le 400 -and $skill.content -notmatch '\{[A-Za-z][A-Za-z0-9]*\}' -and $skill.content -notmatch "`r" -and $skill.content -notmatch '<!--') 'The skill has a description, no unfilled token, no CR and no comment marker'
    Check ($skill.content -notmatch '[$]' -and $skill.content -match 'never add an expand option' -and $skill.content -match 'plain GET') 'The skill has no dollar sign and says why a read is plain'
    $guids = @([regex]::Matches($skill.content + $desired.arc.repairScript, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '^00000000-0000-0000-0000-0000000000\d\d$' })
    Check ($guids.Count -eq 0) 'No real GUID in the skill or the script'
    Check ($skill.content -match [regex]::Escape($config.machineId) -and $skill.content -match 'ArcLobBridgeApp' -and $skill.content -match 'ArcSreLobApp' -and $skill.content -match [regex]::Escape($config.repairPath)) 'The skill names the server, the event source, the task and the script path'
    Check ($skill.content -match 'at most six reads' -and $skill.content -match 'Propose one Run Command per incident' -and $skill.content -match 'Do not name a clock time or a delay for a re-check' -and $skill.content -match 'never from when the card appeared' -and $skill.content -match 'Do not say or imply that the alert will clear') 'The skill keeps the one-write, timing and no-prediction rules the closing check needs'
    Check ($skill.content -match 'never recreate it inline' -and $skill.content -match 'Never use this skill for SQL') 'The skill does not recreate the script inline and stays off SQL'
    $line = @($skill.content -split "`n" | Where-Object { $_.StartsWith('`az rest --method put') })
    Check ($line.Count -eq 1) 'The skill has exactly one write command'
    $template = $line[0].Trim([char]96)
    $command = $template.Replace('<STAMP>', '202611111200').Replace('<MACHINE_LOCATION>', 'australiaeast')
    $verdict = Test-ArcRepairCommand -Command $command -Settings $config -MachineLocation 'Australia East'
    Check ($verdict.ok -and $verdict.runName -ceq 'sre-repair-lob-202611111200' -and $verdict.location -ceq 'australiaeast') "The command in the skill passes its own check: $($verdict.reasons -join '; ')"
    $encoded = [Text.Encodings.Web.JavaScriptEncoder]::Default.Encode($command).Length
    Check ($encoded -lt 2500) "The PUT stays well under the size at which an approval card went missing (about 4,000 escaped characters); it is $encoded"
    Check (($command.ToCharArray() | Where-Object { $_ -eq "'" }).Count -eq 2 -and $command.Contains('--body ''{"location"')) 'The body is one single-quoted JSON argument, so a shell passes it through untouched'

    # --- The repair script --------------------------------------------------------------------------------------------------------------
    $repairText = $desired.arc.repairScript
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseInput($repairText, [ref]$tokens, [ref]$errors) | Out-Null
    Check ($errors.Count -eq 0 -and $repairText -notmatch '\{[A-Za-z][A-Za-z0-9]*\}' -and $repairText.Contains("'ArcSreLobApp'") -and $repairText.Contains("'C:\ProgramData\ArcSreLobApp'")) 'The repair script parses, and has the task and the app folder filled in'
    Check ($repairText -notmatch 'Remove-Item|Restart-Computer|Stop-Computer|Invoke-WebRequest|Invoke-RestMethod|Invoke-Expression|Start-Process|Set-ExecutionPolicy|New-Object Net') 'The repair script has no delete, restart, download or process-launch call'
    function Invoke-RepairScript {
        # Runs the rendered script with the scheduled-task cmdlets and the sleep stood in, against a temporary app folder.
        param([string]$Mode, [string]$TaskState = 'Running', [string]$PidText = $null, [hashtable]$CommandLines = @{})
        $folder = New-TempPath
        New-Item -ItemType Directory -Path $folder | Out-Null
        $before = [ordered]@{ AppName = 'Arc LOB Bridge App'; FaultMode = $Mode; IncidentId = 't11-20261111000000'; EventSource = 'ArcLobBridgeApp'; LoopSeconds = 15 }
        [IO.File]::WriteAllText((Join-Path $folder 'appsettings.json'), ($before | ConvertTo-Json))
        if ($null -ne $PidText) { [IO.File]::WriteAllText((Join-Path $folder 'lob-arc-app.pid'), $PidText) }
        $calls = [Collections.Generic.List[string]]::new()
        $harness = {
            param([string]$Text, $Calls, [string]$State, $CommandLines)
            function Stop-ScheduledTask { [CmdletBinding()] param($TaskName) $Calls.Add("stop $TaskName") }
            function Start-ScheduledTask { [CmdletBinding()] param($TaskName) $Calls.Add("start $TaskName") }
            function Start-Sleep { [CmdletBinding()] param($Seconds) $Calls.Add("sleep $Seconds") }
            function Get-ScheduledTask { [CmdletBinding()] param($TaskName) [pscustomobject]@{ State = $State } }
            function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskName) [pscustomobject]@{ LastTaskResult = 267009 } }
            function Get-CimInstance {
                [CmdletBinding()] param($ClassName, $Filter)
                if ($Filter -match '^ProcessId = (\d+)$' -and $CommandLines.ContainsKey($Matches[1])) { [pscustomobject]@{ ProcessId = [int]$Matches[1]; CommandLine = $CommandLines[$Matches[1]] } }
            }
            function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) $Calls.Add("kill $Id") }
            & ([scriptblock]::Create($Text))
        }
        $failure = $null
        $output = @()
        try { $output = @(& $harness $repairText.Replace($config.appRoot, $folder) $calls $TaskState $CommandLines) } catch { $failure = $_.Exception.Message }
        [pscustomobject]@{ output = ($output -join "`n"); calls = @($calls.ToArray()); folder = $folder; failure = $failure; config = (Get-Content -LiteralPath (Join-Path $folder 'appsettings.json') -Raw | ConvertFrom-Json) }
    }
    $fixed = Invoke-RepairScript -Mode 'CrashOnProcessing'
    Check ($null -eq $fixed.failure -and $fixed.output -ceq 'was=CrashOnProcessing now=Healthy state=Running last=267009') "A faulted app is repaired and the script says so on one line: $($fixed.output) $($fixed.failure)"
    Check ($fixed.config.FaultMode -ceq 'Healthy' -and $fixed.config.IncidentId -ceq 'repaired' -and $fixed.config.AppName -ceq 'Arc LOB Bridge App' -and $fixed.config.EventSource -ceq 'ArcLobBridgeApp' -and $fixed.config.LoopSeconds -eq 15) 'It changes only the fault mode and the incident ID, and keeps the rest of the config'
    Check ((@($fixed.calls) -join ',') -ceq 'stop ArcSreLobApp,start ArcSreLobApp,sleep 8') 'It stops the task, starts it and waits, in that order'
    Check ((Get-Content -LiteralPath (Join-Path $fixed.folder 'appsettings.json.bak') -Raw | ConvertFrom-Json).FaultMode -ceq 'CrashOnProcessing') 'The old config stays beside it as appsettings.json.bak, so the repair is reversible'
    $appCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ArcSreLobApp\LobArcBridgeApp.ps1" -ConfigPath "C:\ProgramData\ArcSreLobApp\appsettings.json"'
    $survivor = Invoke-RepairScript -Mode 'CrashOnProcessing' -PidText "4242`r`n" -CommandLines @{ '4242' = $appCommand }
    Check ($null -eq $survivor.failure -and (@($survivor.calls) -join ',') -ceq 'stop ArcSreLobApp,kill 4242,start ArcSreLobApp,sleep 8') "A worker that outlived the stop is ended before the start, because the task allows one instance: $(@($survivor.calls) -join ',') $($survivor.failure)"
    $reused = Invoke-RepairScript -Mode 'CrashOnProcessing' -PidText '4242' -CommandLines @{ '4242' = 'notepad.exe C:\notes.txt' }
    Check ((@($reused.calls) -join ',') -ceq 'stop ArcSreLobApp,start ArcSreLobApp,sleep 8') 'A process that only reuses the stale process ID is left alone'
    Check ((@((Invoke-RepairScript -Mode 'CrashOnProcessing' -PidText '4242').calls) -join ',') -ceq 'stop ArcSreLobApp,start ArcSreLobApp,sleep 8' -and (@((Invoke-RepairScript -Mode 'CrashOnProcessing' -PidText 'garbage 1; calc' -CommandLines @{ '1' = $appCommand }).calls) -join ',') -ceq 'stop ArcSreLobApp,start ArcSreLobApp,sleep 8') 'A process ID with no live process behind it, or a file that holds anything but one number, ends nothing'
    $untouched = Invoke-RepairScript -Mode 'Healthy'
    Check ($untouched.output -ceq 'was=Healthy now=Healthy state=Running last=267009' -and @($untouched.calls).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $untouched.folder 'appsettings.json.bak')) -and $untouched.config.IncidentId -ceq 't11-20261111000000') 'An app that is already healthy is left alone: no restart, no backup, no change, so a stale card is harmless'
    Check ((Invoke-RepairScript -Mode 'Degraded').config.FaultMode -ceq 'Healthy') 'The degraded fault is repaired too'
    $stuck = Invoke-RepairScript -Mode 'CrashOnProcessing' -TaskState 'Ready'
    Check ($stuck.failure -match 'not healthy after the repair: now=Healthy state=Ready') 'If the task is not running afterwards the script fails and says what it saw, so the run command reports a failure'

    # --- The install script -------------------------------------------------------------------------------------------------------------
    $install = Get-ArcInstallScript -ScriptText $repairText -Path $config.repairPath
    $errors = $null
    [Management.Automation.Language.Parser]::ParseInput($install, [ref]$tokens, [ref]$errors) | Out-Null
    Check ($errors.Count -eq 0 -and $install -notmatch '[\r]' -and $install.Contains("'$($config.repairPath)'")) 'The install script parses, has LF line endings and writes to the fixed path on the server'
    # It runs here against a temporary path, swapped in after rendering: the path check rejects a short 8.3 temp name such as RUNNER~1.
    $target = Join-Path (New-TempPath) 'Repair-LobApp.ps1'
    $installed = @(& ([scriptblock]::Create($install.Replace($config.repairPath, $target))))
    Check ($installed.Count -eq 1 -and $installed[0] -ceq "sha256=$($desired.arc.repairSha256)" -and (Get-Content -LiteralPath $target -Raw) -ceq $repairText) 'It writes the script exactly and prints the SHA-256 this repo computes'
    Throws { Get-ArcInstallScript -ScriptText $repairText -Path "C:\x'; Remove-Item C:\y" } 'does not match'
    Throws { Get-ArcInstallScript -ScriptText $repairText -Path 'relative\path.ps1' } 'does not match'

    # --- The handler and the plan -------------------------------------------------------------------------------------------------------
    $offPath = New-ArcSkinFile -Scenarios @('T09', 'T11')
    $onPath = New-ArcSkinFile -Scenarios @('T09', 'T11', 'ARC')
    $off = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $offPath
    $on = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $onPath
    $offText = [string]$off.handler.properties.instructions
    $onText = [string]$on.handler.properties.instructions
    $exception = 'The one exception to this read-only rule is the Arc application recovery policy below. '
    Check ($offText -notmatch 'Arc application recovery policy' -and $offText -match 'Windows application and SQL investigations are\s+read-only: no remediation, SQL execution, session termination, guest commands') 'Without ARC the handler is the base text: read-only for Windows, no recovery policy'
    Check ($onText -match ('configuration changes or restarts\. ' + [regex]::Escape($exception) + 'Recommend human checks, not unapproved actions\.') -and $onText -match 'Arc application recovery policy\s+Only for an incident on win-app-01 whose Application events come from ArcLobBridgeApp') 'With ARC the sentence after the read-only rule names the one exception, and a closing paragraph holds the policy for the one server'
    $undone = $onText.Replace($exception, '')
    Check ($undone.StartsWith($offText) -and $undone.Length -gt $offText.Length) 'With the exception taken out, the ARC handler is the plain handler plus one appended paragraph'
    $tail = $undone.Substring($offText.Length)
    Check ($tail -match 'arc-server-repair skill' -and $tail -match 'exactly one Run Command' -and $tail -match 'human\s+approval in\s+Review mode' -and $tail -match 'never\s+from when the card appeared' -and $tail -match 'Never name a clock time' -and $tail -match 'Do not apply this policy to SQL, to another machine or\s+to the Container App') 'The paragraph says one Run Command, approval, timing from the start, no clock time for a re-check, and no other target'
    Check ($onText -notmatch '\{[A-Za-z][A-Za-z0-9]*\}' -and $onText -notmatch 'arcMachineName') 'No token is left in the handler'
    $offT11 = @($off.plans | Where-Object { $_.scenario -eq 'T11' })[0]
    $onT11 = @($on.plans | Where-Object { $_.scenario -eq 'T11' })[0]
    $onT09 = @($on.plans | Where-Object { $_.scenario -eq 'T09' })[0]
    Check ($offT11.properties.mergeEnabled -eq $true -and $onT11.properties.mergeEnabled -eq $false -and $onT09.properties.mergeEnabled -eq $true) 'ARC turns the cooldown off for the T11 plan only'
    Check ($onT11.properties.agentMode -ceq 'Review' -and @($on.plans | Where-Object { $_.properties.agentMode -cne 'Review' }).Count -eq 0) 'Every plan stays in Review mode with ARC on'
    Check ((@($on.handler.properties.tools) -join ',') -ceq (@($off.handler.properties.tools) -join ',') -and $null -eq $on.release -and $on.acts.modules[0] -ceq 'ARC') 'The handler keeps its tools, and ARC adds no GitHub or release part'

    # --- Reading the command on a card --------------------------------------------------------------------------------------------------
    $words = Split-ArcShellWord -Line 'az rest --method put --url "https://x/y?api-version=1" --body ''{"a":"b c","d":"C:\\p"}'''
    Check (-not $words.unsafe -and @($words.words).Count -eq 8 -and $words.words[5] -ceq 'https://x/y?api-version=1' -and $words.words[7] -ceq '{"a":"b c","d":"C:\\p"}') 'Words are split like bash: double quotes and single quotes group, and single quotes keep every character'
    Check ((Split-ArcShellWord -Line 'az rest --body "a\"b"').words[3] -ceq 'a"b' -and -not (Split-ArcShellWord -Line 'az rest --body "a\"b"').unsafe) 'A backslash escapes a double quote inside double quotes'
    foreach ($bad in @('az rest --url "x$(date)"', 'az rest --url "x$HOME"', 'az rest; az group delete', 'az rest | tee x', 'az rest --url x && az y', 'az rest > out.txt', 'az rest `whoami`', "az rest --url 'unterminated", 'az rest $x')) {
        Check ((Split-ArcShellWord -Line $bad).unsafe) "Shell syntax is flagged and not expanded: $bad"
    }
    Check ((Get-ArcCardCommand '{"Name":"RunAzCliWriteCommands","Arguments":{"command":"az rest --method put"}}') -ceq 'az rest --method put' -and (Get-ArcCardCommand @{ Arguments = @{ command = 'az x' } }) -ceq 'az x' -and (Get-ArcCardCommand 'az plain') -ceq 'az plain' -and (Get-ArcCardCommand $null) -ceq '') 'The command comes out of the card JSON, an object or plain text'
    $check = { param([string]$Text, [string]$Location = '') Test-ArcRepairCommand -Command $Text -Settings $config -MachineLocation $Location }
    $mutate = { param([string]$From, [string]$To) & $check $command.Replace($From, $To) }
    $refused = [ordered]@{
        'a different method' = { & $mutate '--method put' '--method delete' }
        'a different machine' = { & $mutate 'win-app-01' 'win-sql-01' }
        'a name without the prefix' = { & $mutate 'runCommands/sre-repair-lob-202611111200' 'runCommands/arc-repair-install' }
        'a different API version' = { & $mutate '2024-11-10-preview' '2023-01-01' }
        'an extra key in properties' = { & $mutate '"asyncExecution":false' '"asyncExecution":false,"runAsUser":"x"' }
        'an extra top-level key' = { & $mutate '{"location"' '{"tags":{},"location"' }
        'a different script' = { & $mutate 'Repair-LobApp.ps1' 'Other.ps1' }
        'inline script text' = { & $mutate 'C:\\ProgramData\\ArcSreLobApp\\Repair-LobApp.ps1' 'Remove-Item C:\\ -Recurse' }
        'asynchronous execution' = { & $mutate '"asyncExecution":false' '"asyncExecution":true' }
        'a long timeout' = { & $mutate '"timeoutInSeconds":120' '"timeoutInSeconds":3600' }
        'a body in a file' = { & $check 'az rest --method put --url "https://management.azure.com/x" --body @body.json' }
        'a script from a URI' = { & $mutate '"source":{"script":"C:\\ProgramData\\ArcSreLobApp\\Repair-LobApp.ps1"}' '"source":{"scriptUri":"https://example.invalid/x.ps1"}' }
        'a chained command' = { & $check "$command ; az group delete -n rg" }
        'a command substitution' = { & $mutate '202611111200' '$(date +%s)' }
        'another az command' = { & $check 'az vm delete -g rg-arc-demo-infra -n win-app-01 --yes' }
        'an extra option' = { & $check "$command --verbose" }
        'a header that is not JSON content negotiation' = { & $mutate '--method put' '--headers "Authorization=Bearer x" --method put' }
        'a header option with no value' = { & $check "$command --headers" }
        'no command' = { & $check '' }
    }
    foreach ($name in $refused.Keys) {
        $result = & $refused[$name]
        Check (-not $result.ok -and @($result.reasons).Count -ge 1) "The check refuses $name"
    }
    Check ((& $check $command 'Australia South East').ok -eq $false -and (& $check $command 'australiaeast').ok -and (& $check $command 'Australia East').ok) 'The location must be the machine''s, whatever its spacing and case'
    Check ((& $check ($command + ' -o json --only-show-errors --subscription ' + $subscription)).ok) 'Output and subscription options do not change what runs'
    Check ((& $check $command.Replace('--body ''', '--body=''')).ok) 'The body option may be given with an equals sign'
    Check ((& $mutate '--method put' '--headers "Content-Type=application/json" --method put').ok -and (& $mutate '--method put' '--headers Content-Type=application/json Accept=application/json --method put').ok -and (& $mutate '--method put' '--headers=Content-Type=application/json --method put').ok) 'A JSON content type or accept header, a harmless addition a model may make, does not turn the repair into something else'
    $reasonsText = (& $mutate 'win-app-01' 'win-sql-01').reasons -join ';'
    Check ($reasonsText -match 'not a run command on win-app-01') 'A refusal says why, in words a person can read out'

    # --- The run record and what is folded into it --------------------------------------------------------------------------------------
    $t0 = [DateTimeOffset]::Parse('2026-11-12T00:00:00Z')
    $at = { param([int]$seconds) $t0.AddSeconds($seconds).ToString('o') }
    $repo = New-TempPath
    New-Item -ItemType Directory -Path $repo | Out-Null
    Check ($null -eq (Read-ArcRun -RepoRoot $repo)) 'No run is recorded at first'
    $run = Initialize-ArcRun -Settings $config
    Check ($run.state -ceq 'running' -and $run.machine -ceq 'win-app-01' -and $run.faultMode -ceq 'CrashOnProcessing' -and $run.runId -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$') 'A new run records the server, the fault and a unique ID'
    Check (@(1..20 | ForEach-Object { (Initialize-ArcRun -Settings $config).runId } | Select-Object -Unique).Count -eq 20) 'Runs created in the same second get different IDs'
    Check (Add-ArcRunEvent -Run $run -Name faultInduced -Utc (& $at 0)) 'The first sighting of an event is new'
    Check (-not (Add-ArcRunEvent -Run $run -Name faultInduced -Utc (& $at 60)) -and $run.events.faultInduced -ceq (& $at 0) -and -not (Add-ArcRunEvent -Run $run -Name alertFired -Utc '') -and -not (Add-ArcRunEvent -Run $run -Name alertFired -Utc $null)) 'A later sighting never moves it, and a blank time records nothing'
    Throws { Add-ArcRunEvent -Run $run -Name nonsense -Utc (& $at 1) } 'Unknown run event'
    $run.startedUtc = & $at -5
    Save-ArcRun -RepoRoot $repo -Run $run
    $back = Read-ArcRun -RepoRoot $repo
    Check ($back.runId -ceq $run.runId -and $back.events.faultInduced -ceq (& $at 0) -and $back.events -is [hashtable] -and $back.cards -is [hashtable]) 'A run round-trips through its JSON file with its times in UTC'
    Check (-not (Test-Path -LiteralPath (Join-Path $repo '.local\arc-server-room\current.json.tmp'))) 'No temporary copy of the record is left behind'
    $ignored = (Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -split "`r?`n"
    Check ('.local/' -in $ignored -or '.local' -in $ignored) 'The run record folder is git-ignored'

    $messageAt = { param([int]$seconds) $t0.AddSeconds($seconds).ToString('o') }
    $card = {
        param([string]$Id, [string]$Status, [string]$Text, [int]$Seconds)
        @{ author = @{ role = 'SREAgent' }; timeStamp = (& $messageAt $Seconds)
            azCliExecution = @{ id = $Id; status = $Status; description = 'Executing rest --method'; createdTimestamp = (& $messageAt $Seconds)
                originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $Text } } | ConvertTo-Json -Depth 5 -Compress) } }
    }
    $readCard = & $card 'read-1' 'Completed' "az rest --method get --url `"https://management.azure.com$($config.machineId)/runCommands?api-version=2024-11-10-preview`"" 100
    $graphCard = & $card 'read-2' 'Completed' 'az graph query -q "Resources | take 1"' 110
    $deleteCard = & $card 'bad-1' 'Pending' 'az vm delete -g rg-arc-demo-infra -n win-app-01 --yes' 200
    $goodPending = & $card 'good-1' 'Pending' $command 300
    $goodDone = & $card 'good-1' 'Completed' $command 300
    $cards = @(Get-ArcRepairCard -Messages @($readCard, $graphCard, @{ text = 'hello' }, $deleteCard, $goodPending) -Settings $config -MachineLocation 'australiaeast')
    Check ($cards.Count -eq 2 -and $cards[0].id -ceq 'bad-1' -and -not $cards[0].ok -and $cards[1].id -ceq 'good-1' -and $cards[1].ok -and $cards[1].status -ceq 'Pending') 'Reads are ignored; a pending card for anything else is listed as not the allowed repair, and the repair is listed as allowed'
    Check ((@(Get-ArcRepairCard -Messages @($goodDone) -Settings $config).Count) -eq 1 -and @(Get-ArcRepairCard -Messages @($readCard) -Settings $config).Count -eq 0) 'A finished write on a run command is still listed; a finished read is not'

    $view = ConvertTo-ArcRunView @{ name = 'sre-repair-lob-202611111200'; properties = @{ provisioningState = 'Succeeded'; source = @{ script = $config.repairPath }
            instanceView = @{ executionState = 'Succeeded'; exitCode = 0; startTime = (& $at 400); endTime = (& $at 410); output = "was=CrashOnProcessing now=Healthy state=Running last=267009`n"; error = '' } } }
    Check ($view.name -ceq 'sre-repair-lob-202611111200' -and $view.executionState -ceq 'Succeeded' -and $view.exitCode -eq 0 -and $view.startUtc -ceq (& $at 400) -and $view.script -ceq $config.repairPath -and $view.output -match 'now=Healthy') 'A run command is read into one flat view'
    $flat = ConvertTo-ArcRunView ([pscustomobject]@{ name = 'x'; provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Failed'; exitCode = 1 } })
    Check ($flat.executionState -ceq 'Failed' -and $flat.exitCode -eq 1 -and $null -eq (ConvertTo-ArcRunView $null)) 'The CLI shape without a properties wrapper is read too'

    $fresh = Initialize-ArcRun -Settings $config
    $fresh.startedUtc = & $at -5
    $null = Add-ArcRunEvent -Run $fresh -Name faultInduced -Utc (& $at 0)
    $alertOpen = [pscustomobject]@{ firedUtc = (& $at 480); resolvedUtc = $null }
    $thread = [pscustomobject]@{ id = 'thread-1'; createdUtc = (& $at 495) }
    $new1 = @(Sync-ArcRun -Run $fresh -Settings $config -Alerts $alertOpen -Thread $thread -Messages @($readCard, $goodPending) -RepairRun $null -MachineLocation 'australiaeast' -ObservedUtc (& $at 600))
    Check (($new1 -join ',') -ceq 'alertFired,threadCreated,firstAgentMessage,cardPending' -and $fresh.threadId -ceq 'thread-1' -and $fresh.events.cardPending -ceq (& $at 300)) 'The first sync records the alert, the thread, the first agent message and the pending card, in that order'
    Check ($fresh.cards['good-1'].ok -and $null -eq $fresh.cards['good-1'].finalStatus -and $fresh.cards['good-1'].pendingUtc -ceq (& $at 300)) 'The pending card is recorded as the allowed repair, with no final status'
    Check (@(Sync-ArcRun -Run $fresh -Settings $config -Alerts $alertOpen -Thread $thread -Messages @($goodPending) -RepairRun $null -ObservedUtc (& $at 620)).Count -eq 0) 'Syncing the same sources again changes nothing'
    $alertDone = [pscustomobject]@{ firedUtc = (& $at 480); resolvedUtc = (& $at 900) }
    $new2 = @(Sync-ArcRun -Run $fresh -Settings $config -Alerts $alertDone -Thread $thread -Messages @($goodDone) -RepairRun $view -MachineLocation 'australiaeast' -ObservedUtc (& $at 700))
    Check (($new2 -join ',') -ceq 'alertResolved,cardCompleted,repairStarted,repairEnded' -and $fresh.cards['good-1'].finalStatus -ceq 'Completed' -and $fresh.events.repairStarted -ceq (& $at 400) -and $fresh.repairRun.executionState -ceq 'Succeeded') 'A completed card, the repair run command and the resolved alert are folded in'
    $running = ConvertTo-ArcRunView @{ name = 'sre-repair-lob-202611111200'; properties = @{ instanceView = @{ executionState = 'Running'; startTime = (& $at 400) } } }
    $mid = Initialize-ArcRun -Settings $config
    $null = Sync-ArcRun -Run $mid -Settings $config -Alerts $null -Thread $null -Messages @() -RepairRun $running
    Check ($mid.events.ContainsKey('repairStarted') -and -not $mid.events.ContainsKey('repairEnded')) 'A repair that is still running has started but not ended'
    $report = @(Format-ArcRun -Run $fresh) -join "`n"
    Check ($report -match 'fault induced on the server\s+00:00:00Z \(\+0m00s\)' -and $report -match 'alert fired\s+00:08:00Z \(\+8m00s\)' -and $report -match 'Approve card pending\s+00:05:00Z \(\+5m00s\)' -and $report -match 'repair run command started\s+00:06:40Z' -and $report -match 'card \[Completed\] the command is the allowed repair' -and $report -match 'repair run command sre-repair-lob-202611111200: Succeeded, exit code 0' -and $report -match 'output: was=CrashOnProcessing now=Healthy') 'The report shows each event with its offset from the fault, the card with its verdict and the repair output'
    $badRun = Initialize-ArcRun -Settings $config
    $null = Sync-ArcRun -Run $badRun -Settings $config -Alerts $null -Thread $thread -Messages @($deleteCard) -MachineLocation 'australiaeast'
    Check ((@(Format-ArcRun -Run $badRun) -join "`n") -match 'card \[Pending\] NOT the allowed repair: ') 'A card that is not the repair is called that in the report'

    # --- Rows of Check, the install marker, and the run command calls ---------------------------------------------------------------------
    $sha = $desired.arc.repairSha256
    $now = [DateTimeOffset]::Parse('2026-11-12T12:00:00Z')
    $machine = [pscustomobject]@{ name = 'win-app-01'; status = 'Connected'; lastStatusChange = '2026-11-12T10:00:00Z'; location = 'australiaeast' }
    $markerOk = [pscustomobject]@{ name = 'arc-repair-install'; executionState = 'Succeeded'; output = "sha256=$sha" }
    $markerOld = [pscustomobject]@{ name = 'arc-repair-install'; executionState = 'Succeeded'; output = 'sha256=' + ('0' * 64) }
    $others = @($machine, [pscustomobject]@{ name = 'win-sql-01'; status = 'Connected' }, [pscustomobject]@{ name = 'sql-guest'; status = 'Disconnected' })
    $rule = [pscustomobject]@{ properties = [pscustomobject]@{ enabled = $true } }
    $rows = { param($m, $a, $c, $r) @(Get-ArcCheckRow -Machine $m -AllMachine $a -RunCommand $c -Settings $config -ExpectedSha256 $sha -AlertRule $r -Now $now) }
    $good = & $rows $machine @($machine) @($markerOk) $rule
    Check (@($good | Where-Object { $_.status -ne 'pass' }).Count -eq 0 -and (@($good | ForEach-Object { $_.name }) -join ',') -ceq 'server,repair-script,leftover-run-commands,alert-rule,arc-machines') 'A healthy estate passes every row'
    Check ((& $rows $machine @($machine) @($markerOk) $rule)[0].detail -match 'since 120 min ago') 'The server row says how long it has been Connected'
    Check ((& $rows $null @() @($markerOk) $rule)[0].status -ceq 'fail' -and (& $rows ([pscustomobject]@{ name = 'win-app-01'; status = 'Disconnected' }) @() @($markerOk) $rule)[0].status -ceq 'fail') 'A missing or disconnected server fails'
    $recent = [pscustomobject]@{ name = 'win-app-01'; status = 'Connected'; lastStatusChange = '2026-11-12T11:45:00Z' }
    Check ((& $rows $recent @($recent) @($markerOk) $rule)[0].status -ceq 'pending' -and (& $rows $recent @($recent) @($markerOk) $rule)[0].detail -match 'Connected for 15 min.*allow 30 minutes') 'A server Connected for under 30 minutes is pending, with the reason'
    Check ((& $rows $machine @($machine) @() $rule)[1].status -ceq 'pending' -and (& $rows $machine @($machine) @() $rule)[1].detail -match 'Prepare' -and (& $rows $machine @($machine) @($markerOld) $rule)[1].detail -match 'not the script in this repo') 'A missing or stale repair script is pending, and says to run Prepare'
    $leftover = [pscustomobject]@{ name = 'sre-repair-lob-202611111100'; executionState = 'Succeeded' }
    $leftRow = (& $rows $machine @($machine) @($markerOk, $leftover, [pscustomobject]@{ name = 't11-lob-deploy-1'; executionState = 'Succeeded' }) $rule)[2]
    Check ($leftRow.status -ceq 'pending' -and $leftRow.detail -match '^1 from an earlier run \(sre-repair-lob-202611111100\)') 'Only the agent''s leftover run commands are counted: not the marker, not the T11 ones'
    Check ((& $rows $machine @($machine) @($markerOk) $null)[3].status -ceq 'fail' -and (& $rows $machine @($machine) @($markerOk) ([pscustomobject]@{ properties = [pscustomobject]@{ enabled = $false } }))[3].status -ceq 'fail') 'A missing or disabled alert rule fails'
    $manyRow = (& $rows $machine $others @($markerOk) $rule)[4]
    Check ($manyRow.status -ceq 'pending' -and $manyRow.detail -match 'sql-guest Disconnected') 'Another Arc machine that is not Connected is named'
    Check ((Get-ArcInstallState -RunCommand @($markerOk) -Settings $config -ExpectedSha256 $sha).state -ceq 'installed' -and (Get-ArcInstallState -RunCommand @($markerOld) -Settings $config -ExpectedSha256 $sha).state -ceq 'stale' -and (Get-ArcInstallState -RunCommand @() -Settings $config -ExpectedSha256 $sha).state -ceq 'missing' -and (Get-ArcInstallState -RunCommand @([pscustomobject]@{ name = 'arc-repair-install'; executionState = 'Failed'; output = "sha256=$sha" }) -Settings $config -ExpectedSha256 $sha).state -ceq 'missing') 'The install state is installed, stale or missing, and a failed install is missing'

    $global:ArcAzResponder = {
        $text = $args -join ' '
        if ($text -match 'runCommands/missing-one\?') { $global:LASTEXITCODE = 3; Write-Error 'ERROR: (ResourceNotFound) The Resource was not found.' -ErrorAction Continue; return }
        if ($text -match 'runCommands/arc-repair-install\?') { return (@{ name = 'arc-repair-install'; properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = "sha256=$sha" } } } | ConvertTo-Json -Depth 6) }
        if ($text -match '^rest --method get --url \S+/runCommands\?') { return (@{ value = @(@{ name = 'arc-repair-install'; properties = @{ provisioningState = 'Succeeded' } }, @{ name = 'sre-repair-lob-1'; properties = @{ provisioningState = 'Succeeded' } }) } | ConvertTo-Json -Depth 6) }
        if ($text -match '^rest --method delete --url ') { return '' }
        throw "Unexpected az call: $text"
    }
    $global:ArcAzCalls.Clear()
    $listed = @(Get-ArcRunCommand -SubscriptionId $subscription -Settings $config)
    Check ($listed.Count -eq 2 -and $listed[1].name -ceq 'sre-repair-lob-1' -and $global:ArcAzCalls[0].StartsWith("rest --method get --url https://management.azure.com$($config.machineId)/runCommands?api-version=2024-11-10-preview -o json --subscription ")) 'Listing is one GET on the server''s run commands'
    $named = Get-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name 'arc-repair-install'
    Check ($named.executionState -ceq 'Succeeded' -and $named.output -ceq "sha256=$sha" -and $null -eq (Get-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name 'missing-one')) 'A read by name has the result, and a name that does not exist reads as nothing'
    Throws { Get-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name 'bad name; x' } 'does not match'
    $global:ArcAzCalls.Clear()
    foreach ($protected in @('arc-repair-install', 't11-lob-deploy-1105082038', 'sre-repair-lob-', 'other')) {
        Throws { Remove-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name $protected -Confirm:$false } 'Refusing to delete'
    }
    Check ($global:ArcAzCalls.Count -eq 0) 'The install marker, the T11 run commands and other names are never deleted, and no az call is made for them'
    Remove-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name 'sre-repair-lob-202611111200' -WhatIf
    Check ($global:ArcAzCalls.Count -eq 0) 'Delete with -WhatIf makes no call'
    Remove-ArcRunCommand -SubscriptionId $subscription -Settings $config -Name 'sre-repair-lob-202611111200' -Confirm:$false
    Check ($global:ArcAzCalls.Count -eq 1 -and $global:ArcAzCalls[0].StartsWith("rest --method delete --url https://management.azure.com$($config.machineId)/runCommands/sre-repair-lob-202611111200?api-version=2024-11-10-preview -o none --subscription ")) 'An agent-created run command is deleted with one DELETE'

    # --- The thread and its cards as the data plane serves them ---------------------------------------------------------------------------
    $agent = Start-FakeAgent
    try {
        $context = New-TestDataContext -Agent $agent -SubscriptionId $subscription -TenantId $tenant
        $alertTitle = "Sev2 alert-arc-demo-$($config.alertTitle) fired"
        $agent.state.threads = @(@{ id = 'thread-old'; title = $alertTitle; createdTimestamp = (& $at -3600) }, @{ id = 'thread-9'; title = $alertTitle; createdTimestamp = (& $at 495) },
            @{ id = 'thread-other'; title = 'Sev2 containerapp-restarts fired'; createdTimestamp = (& $at 500) })
        $agent.state.messages['thread-9'] = @($readCard, $deleteCard, $goodPending)
        $observed = Get-FridayThreadObservation -Threads (Get-SreThreads -Context $context -Top 30) -Since (& $at -5) -AlertTitle $config.alertTitle
        Check ($observed.count -eq 1 -and $observed.id -ceq 'thread-9') 'Only this run''s thread for the LOB alert is picked'
        $served = @((Get-SreThreadMessages -Context $context -ThreadId $observed.id).Messages)
        $served1 = Initialize-ArcRun -Settings $config
        $served1.startedUtc = & $at -5
        $servedNew = @(Sync-ArcRun -Run $served1 -Settings $config -Alerts $null -Thread $observed -Messages $served -RepairRun $null -MachineLocation 'australiaeast')
        Check (($servedNew -join ',') -ceq 'threadCreated,firstAgentMessage,cardPending' -and $served1.cards.Count -eq 2 -and $served1.cards['good-1'].ok -and -not $served1.cards['bad-1'].ok) 'Cards read through the data plane keep their verdict: the repair is allowed and a VM delete is not'
        Check ($served1.cards['bad-1'].reasons[0] -match 'not an az rest command') 'The card that is not the repair says why'
        $agent.state.messages['thread-9'] = @($readCard, $deleteCard, $goodDone)
        $servedAgain = @((Get-SreThreadMessages -Context $context -ThreadId 'thread-9').Messages)
        $null = Sync-ArcRun -Run $served1 -Settings $config -Alerts $null -Thread $observed -Messages $servedAgain -RepairRun $null -MachineLocation 'australiaeast' -ObservedUtc (& $at 700)
        Check ($served1.cards['good-1'].finalStatus -ceq 'Completed' -and $served1.events.ContainsKey('cardCompleted') -and -not $served1.cards['bad-1'].finalStatus) 'A later read records the approved card as Completed, and the card that is not the repair stays pending'
    } finally { Stop-FakeAgent -Agent $agent }

    # --- The real runner, against a copy of the scripts ---------------------------------------------------------------------------------
    $fixture = New-TempPath
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination (Join-Path $fixture 'scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination (Join-Path $fixture 'config') -Recurse
    $lobLog = Join-Path $fixture 'lob-calls.txt'
    # The T11 script is swapped for a stub that records how it was called, so no guest command is ever sent.
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Invoke-LobArcAppOnArc.ps1'), @'
[CmdletBinding(SupportsShouldProcess)]
param($SubscriptionId, $TenantId, $SkinPath, $Action, $FaultMode)
"$Action $FaultMode" | Add-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'lob-calls.txt')
[pscustomobject]@{ Action = $Action; GuestExitCode = 0; GuestOutput = 'ok' }
'@)
    $runner = Join-Path $fixture 'scripts\Invoke-ArcServerRoom.ps1'
    $global:ArcFake = @{
        status = 'Connected'; changed = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); ruleEnabled = $true; agentReady = $false; installFails = $false
        commands = [ordered]@{}; alerts = @(); deleted = [Collections.Generic.List[string]]::new(); created = [Collections.Generic.List[string]]::new()
    }
    $global:ArcAzResponder = {
        $text = $args -join ' '
        $s = $global:ArcFake
        if ($text -match '^account show') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
        if ($text -match '^connectedmachine show ') { return (@{ name = 'win-app-01'; status = $s.status; lastStatusChange = $s.changed; location = 'australiaeast' } | ConvertTo-Json) }
        if ($text -match '^connectedmachine list ') { return (ConvertTo-Json -InputObject @(@{ name = 'win-app-01'; status = $s.status }, @{ name = 'win-sql-01'; status = 'Connected' }, @{ name = 'sql-guest'; status = 'Disconnected' })) }
        if ($text -match '^resource show --ids \S+/scheduledQueryRules/') { return (@{ properties = @{ enabled = $s.ruleEnabled } } | ConvertTo-Json -Depth 4) }
        if ($s.agentReady -and $text -match '^resource show --ids \S+/providers/Microsoft\.App/agents/') { return '{"properties":{"provisioningState":"Succeeded","runningState":"Running","actionConfiguration":{"mode":"Review"},"agentEndpoint":"https://example.azuresre.ai"}}' }
        if ($s.agentReady -and $text -match '^account get-access-token ') { return 'test-token' }
        if ($text -match '^rest --method get --url \S+/runCommands/([^?\s]+)\?') {
            $name = $Matches[1]
            if ($s.commands.Contains($name)) { return ($s.commands[$name] | ConvertTo-Json -Depth 8) }
            $global:LASTEXITCODE = 3; Write-Error 'ERROR: (ResourceNotFound) The Resource was not found.' -ErrorAction Continue; return
        }
        if ($text -match '^rest --method get --url \S+/runCommands\?') { return (@{ value = @($s.commands.Values) } | ConvertTo-Json -Depth 8) }
        if ($text -match '^rest --method get --url \S+/providers/Microsoft\.AlertsManagement/alerts\?') { return (@{ value = @($s.alerts) } | ConvertTo-Json -Depth 12) }
        if ($text -match '^rest --method delete --url \S+/runCommands/([^?\s]+)\?') { $s.deleted.Add($Matches[1]); $s.commands.Remove($Matches[1]); return '' }
        if ($text -match '^connectedmachine run-command create ') {
            $file = ([string]$args[[Array]::IndexOf($args, '--script') + 1]).TrimStart('@')
            $body = Get-Content -LiteralPath $file -Raw
            $name = [string]$args[[Array]::IndexOf($args, '--name') + 1]
            $s.created.Add($name)
            $encoded = [regex]::Match($body, "FromBase64String\('([^']+)'\)").Groups[1].Value
            $hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($encoded))) -replace '-', '').ToLowerInvariant()
            $s.commands[$name] = @{ name = $name; properties = @{ provisioningState = 'Succeeded'; instanceView = @{ executionState = $(if ($s.installFails) { 'Failed' } else { 'Succeeded' }); exitCode = $(if ($s.installFails) { 1 } else { 0 }); output = "sha256=$hash`n" } } }
            return ''
        }
        if ($text -match '^connectedmachine run-command show ') { $name = [string]$args[[Array]::IndexOf($args, '--name') + 1]; return ($s.commands[$name] | ConvertTo-Json -Depth 8) }
        throw "Unexpected mocked call: $text"
    }
    $invoke = { param([hashtable]$Arguments) @(& $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath @Arguments 6>&1 3>&1) }
    $text = { param($records) (@($records | ForEach-Object { [string]$_ }) -join "`n") }
    $fake = $global:ArcFake
    $writes = { @($global:ArcAzCalls | Where-Object { $_ -match 'run-command create|--method (put|delete|patch|post)' }).Count }

    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath (New-ArcSkinFile -Scenarios @('T09', 'T11')) -Action Check } 'does not turn on ARC'
    $global:ArcAzCalls.Clear()
    $checkText = & $text (& $invoke @{ Action = 'Check' })
    Check ($checkText -match 'PASS\s+server\s+win-app-01 is Connected \(since \d+ min ago\)' -and $checkText -match 'PENDING\s+repair-script\s+not installed: run -Action Prepare' -and $checkText -match 'PENDING\s+arc-machines\s+not Connected: sql-guest Disconnected' -and $checkText -match 'Overall: pending') 'Check prints a row for each part and an overall result, and says what to do first'
    Check ((& $writes) -eq 0) 'Check changes nothing'
    $prepareWhatIf = & $text (& $invoke @{ Action = 'Prepare'; WhatIf = $true })
    Check ($prepareWhatIf -match "repair script: $($sha.Substring(0, 12)), \d+ characters, to C:\\ProgramData\\ArcSreLobApp\\Repair-LobApp\.ps1 on win-app-01" -and $fake.created.Count -eq 0) 'Prepare -WhatIf says what it would install, and installs nothing'
    $prepareText = & $text (& $invoke @{ Action = 'Prepare' })
    Check ($fake.created.Count -eq 1 -and $fake.created[0] -ceq 'arc-repair-install' -and $prepareText -match "Installed: the server reports the same SHA-256 \($($sha.Substring(0, 12))") 'Prepare sends one run command, and confirms that the server reports this repo''s hash'
    $fake.installFails = $true
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Prepare } 'was not confirmed on the server'
    $fake.installFails = $false
    $null = & $invoke @{ Action = 'Prepare' }
    $checkAfter = & $text (& $invoke @{ Action = 'Check' })
    Check ($checkAfter -match 'PASS\s+repair-script\s+installed, [0-9a-f]{12} matches this repo') 'After Prepare, Check finds the script installed and matching'

    $writesBefore = & $writes
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start } 'Pass -ApproveFault'
    Check ((& $writes) -eq $writesBefore) 'A Start without consent made no write'
    $fake.status = 'Disconnected'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'Nothing was changed.*server'
    $fake.status = 'Connected'
    $fake.ruleEnabled = $false
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'alert-rule: the LOB alert rule is missing or disabled'
    $fake.ruleEnabled = $true
    $fake.commands.Remove('arc-repair-install')
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'repair-script: not installed'
    $null = & $invoke @{ Action = 'Prepare' }
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'SRE agent is not ready'
    Check (-not (Test-Path -LiteralPath $lobLog) -and -not (Test-Path -LiteralPath (Join-Path $fixture '.local\arc-server-room\current.json'))) 'Every refused Start broke nothing and recorded no run'
    $fake.agentReady = $true
    $whatIfStart = & $text (& $invoke @{ Action = 'Start'; WhatIf = $true })
    Check (-not (Test-Path -LiteralPath $lobLog) -and -not (Test-Path -LiteralPath (Join-Path $fixture '.local\arc-server-room\current.json'))) 'Start -WhatIf breaks nothing and needs no consent'
    $startText = & $text (& $invoke @{ Action = 'Start'; ApproveFault = $true })
    $record = Read-ArcRun -RepoRoot $fixture
    Check ((@(Get-Content -LiteralPath $lobLog) -join ',') -ceq 'InduceFault CrashOnProcessing' -and $record.state -ceq 'running' -and $record.events.ContainsKey('faultInduced') -and $startText -match 'is set to CrashOnProcessing at \d\d:\d\d:\d\dZ' -and $startText -match 'Next: -Action Status -Wait') 'Start sets the T11 fault once, records the run and says what to do next'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'already in progress'
    $fake.agentReady = $false

    $sinceFault = [DateTimeOffset]::Parse($record.events.faultInduced, [Globalization.CultureInfo]::InvariantCulture)
    $fake.alerts = @(@{ properties = @{ essentials = @{ alertRule = "/subscriptions/$subscription/resourceGroups/rg-arc-demo/providers/Microsoft.Insights/scheduledQueryRules/alert-arc-demo-lob-arc-app-fault"; startDateTime = $sinceFault.AddMinutes(6).ToString('o'); monitorCondition = 'Fired'; alertState = 'New'; monitorConditionResolvedDateTime = $null } } })
    $fake.commands['sre-repair-lob-202611111200'] = @{ name = 'sre-repair-lob-202611111200'; properties = @{ provisioningState = 'Succeeded'; source = @{ script = $config.repairPath }
            instanceView = @{ executionState = 'Succeeded'; exitCode = 0; startTime = $sinceFault.AddMinutes(12).ToString('o'); endTime = $sinceFault.AddMinutes(12).AddSeconds(11).ToString('o'); output = "was=CrashOnProcessing now=Healthy state=Running last=267009`n" } } }
    $global:ArcAzCalls.Clear()
    $statusText = & $text (& $invoke @{ Action = 'Status' })
    $seen = Read-ArcRun -RepoRoot $fixture
    Check ($seen.events.ContainsKey('alertFired') -and $seen.events.ContainsKey('repairStarted') -and $seen.events.ContainsKey('repairEnded') -and $seen.repairRun.name -ceq 'sre-repair-lob-202611111200') 'Status records the alert and the repair run command it finds'
    Check ($statusText -match 'data plane is not reachable' -and $statusText -match 'alert fired\s+\d\d:\d\d:\d\dZ \(\+6m00s\)' -and $statusText -match 'repair run command sre-repair-lob-202611111200: Succeeded, exit code 0' -and $statusText -match 'output: was=CrashOnProcessing now=Healthy state=Running') 'Without the SRE agent, Status still reports the alert and the repair, and says what it skipped'
    Check ((& $writes) -eq 0) 'Status changes nothing in Azure'

    $whatIfReset = & $text (& $invoke @{ Action = 'Reset'; WhatIf = $true })
    Check ($whatIfReset -match 'delete 1 created by the agent \(sre-repair-lob-202611111200\)' -and $whatIfReset -match 'the install marker and the T11 commands stay' -and $whatIfReset -match 'threads: keep' -and $fake.deleted.Count -eq 0 -and @(Get-Content -LiteralPath $lobLog).Count -eq 1) 'Reset -WhatIf says what it would do and does none of it'
    $resetText = & $text (& $invoke @{ Action = 'Reset' })
    Check ((@(Get-Content -LiteralPath $lobLog) -join ',') -ceq 'InduceFault CrashOnProcessing,ResetFault ' -and ($fake.deleted -join ',') -ceq 'sre-repair-lob-202611111200' -and $fake.commands.Contains('arc-repair-install')) 'Reset runs the T11 reset, deletes only the agent''s run command and keeps the install marker'
    Check ($resetText -match 'Reset complete: the app is Healthy, 1 run command\(s\) removed, 0 thread\(s\) deleted' -and -not (Test-Path -LiteralPath (Join-Path $fixture '.local\arc-server-room\current.json')) -and @(Get-ChildItem -LiteralPath (Join-Path $fixture '.local\arc-server-room') -Filter 'run-*.json').Count -eq 1) 'Reset archives the run record, so the next run starts clean'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Status } 'No run is recorded'
    $currentFile = Join-Path $fixture '.local\arc-server-room\current.json'
    [IO.File]::WriteAllText($currentFile, '{"runId": "half-written", "events": {')
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Status } 'current\.json cannot be read'
    Throws { & $runner -SubscriptionId $subscription -TenantId $tenant -SkinPath $skinPath -Action Start -ApproveFault } 'current\.json cannot be read'
    $unreadable = & $text (& $invoke @{ Action = 'Reset' })
    Check ($unreadable -match 'could not be read' -and $unreadable -match 'Reset complete' -and -not (Test-Path -LiteralPath $currentFile) -and @(Get-ChildItem -LiteralPath (Join-Path $fixture '.local\arc-server-room') -Filter 'unreadable-*.json').Count -eq 1) 'Reset moves a record it cannot read aside and carries on'

    Write-Host "$count ARC assertions passed. Azure was mocked, the data plane was never reached and no guest command was sent."
} finally {
    $global:ArcAzResponder = $null
    Remove-Variable -Scope Global -Name ArcAzCalls, ArcAzExit, ArcAzResponder, ArcFake -ErrorAction SilentlyContinue
    if ($previousAzBlock) { Set-Item Function:\global:az -Value $previousAzBlock } else { Remove-Item Function:\az -ErrorAction SilentlyContinue }
    foreach ($path in $temps) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
}
