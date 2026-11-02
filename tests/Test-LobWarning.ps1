#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $root 'scripts\Invoke-LobArcAppOnArc.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sre-lob-warning-'quoted-" + [guid]::NewGuid())
$count = 0
$responderBefore = $global:AzResponder
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "LOB warning assertion failed: $Message" }
    $script:count++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Pattern) "Expected $Pattern, got $($_.Exception.Message)"
        return
    }
    throw "Expected warning rejection: $Pattern"
}
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $target = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000001'
        TenantId = '00000000-0000-0000-0000-000000000002'
        ArcResourceGroupName = 'rg-demo'; MachineName = 'win-demo'
        Action = 'WarnForDuration'; AppRoot = $fixture; TaskName = 'DemoTask'
        EventSource = 'DemoLob'
    }
    $guestPath = Join-Path $fixture 'guest.ps1'
    $callsBefore = $global:AzCalls.Count
    & $helper @target -GuestScriptOutputPath $guestPath -WhatIf | Out-Null
    Check (-not (Test-Path -LiteralPath $guestPath)) 'WhatIf writes no guest file'
    & $helper @target -WhatIf | Out-Null
    Check ($global:AzCalls.Count -eq $callsBefore) 'Warning previews make no Azure or account calls'
    Reject { & $helper @target } 'ApproveWarningWindow'
    Reject { & $helper @target -WarningSeconds 181 -GuestScriptOutputPath $guestPath } 'greater than|range|ValidateRange'
    & $helper @target -GuestScriptOutputPath $guestPath | Out-Null
    Check ($global:AzCalls.Count -eq $callsBefore) 'Offline generation needs no execution approval or Azure access'
    $guest = Get-Content -LiteralPath $guestPath -Raw
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseInput($guest, [ref]$tokens, [ref]$errors) | Out-Null
    Check ($errors.Count -eq 0 -and $guest -notmatch '__[A-Z_]+__') 'Rendered script parses including quoted app-root paths'
    Check ($guest -notmatch 'Stop-Process|Start-ScheduledTask|Stop-ScheduledTask|Write-EventLog|while\s*\(') 'Warning path neither restarts the worker, fabricates events nor creates a load loop'
    Check ($guest.Contains('$WarningSeconds = 120') -and $guest.Contains('[IO.File]::Replace')) 'Default warning is bounded and config replacement is atomic'

    $configPath = Join-Path $fixture 'appsettings.json'
    $pidPath = Join-Path $fixture 'lob-arc-app.pid'
    $script:baseline = '{"FaultMode":"Healthy","IncidentId":"none","EventSource":"DemoLob","LoopSeconds":15,"Unrelated":"preserve"}' + "`r`n"
    $script:mode = 'success'; $script:sleepCalls = 0; $script:taskState = 'Running'
    function Reset-Fixture {
        [IO.File]::WriteAllText($configPath, $script:baseline)
        [IO.File]::WriteAllText($pidPath, '123')
        $script:sleepCalls = 0; $script:mode = 'success'; $script:taskState = 'Running'; $script:taskCount = 1
    }
    function Get-ScheduledTask {
        [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
        Check ($TaskName -eq 'DemoTask' -and $TaskPath -eq '\') 'Only the approved root task is inspected'
        for ($i = 0; $i -lt $script:taskCount; $i++) { [pscustomobject]@{ State = $script:taskState } }
    }
    function Get-CimInstance {
        [CmdletBinding()] param([string]$ClassName, [string]$Filter)
        Check ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId = 123') 'Only the existing worker PID is inspected'
        if ($script:mode -eq 'worker-exited' -and $script:sleepCalls -gt 0) { return }
        $command = if ($script:mode -eq 'wrong-process') { 'unrelated.exe' } else {
            "powershell.exe -File `"$(Join-Path $fixture 'LobArcBridgeApp.ps1')`" -ConfigPath `"$configPath`""
        }
        $created = if ($script:mode -eq 'worker-replaced' -and $script:sleepCalls -gt 0) { '2026-01-02T00:00:00Z' } else { '2026-01-01T00:00:00Z' }
        [pscustomobject]@{ ProcessId = 123; CommandLine = $command; CreationDate = $created }
    }
    function Start-Sleep {
        param([int]$Seconds)
        $script:sleepCalls++
        Check ($Seconds -eq 120) 'One configured warning interval'
        $during = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        Check ($during.FaultMode -eq 'Degraded' -and $during.IncidentId -like 'lob-warning-*' -and $during.Unrelated -eq 'preserve') 'Warning changes only intended config fields'
        if ($script:mode -eq 'sleep-error') { throw 'Synthetic interrupted observation' }
        if ($script:mode -eq 'concurrent') { [IO.File]::WriteAllText($configPath, '{"FaultMode":"Degraded","IncidentId":"other-owner"}') }
    }
    function Get-WinEvent {
        [CmdletBinding()] param([hashtable]$FilterHashtable)
        Check ($FilterHashtable.Id -eq 4200 -and $FilterHashtable.ProviderName -eq 'DemoLob' -and $FilterHashtable.StartTime -le $FilterHashtable.EndTime) 'Evidence is bounded to the actual warning source/ID/window'
        if ($script:mode -ne 'no-events') { [pscustomobject]@{ Id = 4200 } }
    }
    $run = [scriptblock]::Create($guest)
    Reset-Fixture
    $result = & $run | ConvertFrom-Json
    Check ($result.ConfigRestored -and $result.WarningEvents -eq 1 -and $result.FaultMode -eq 'Healthy') 'Success requires warning evidence and restored config'
    Check ([IO.File]::ReadAllText($configPath) -ceq $script:baseline) 'Exact original config including unrelated fields/newline restored'
    Reset-Fixture; $script:taskState = [System.Threading.ThreadState]::Running
    $result = & $run | ConvertFrom-Json
    Check ($result.TaskState -is [string] -and $result.TaskState -ceq 'Running') 'Native enum task state is serialized as Running, not an integer'
    foreach ($case in @('no-events', 'sleep-error', 'worker-exited', 'worker-replaced')) {
        Reset-Fixture; $script:mode = $case
        Reject { & $run } 'No Event 4200|Synthetic interrupted|original worker/task'
        Check ([IO.File]::ReadAllText($configPath) -ceq $script:baseline) "$case surfaces failure after restoring baseline"
    }
    Reset-Fixture; $script:mode = 'concurrent'
    Reject { & $run } 'cleanup unverified.*Concurrent config change'
    Check ((Get-Content -LiteralPath $configPath -Raw).Contains('other-owner')) 'Cleanup preserves concurrent operator changes'
    foreach ($case in @('unhealthy', 'wrong-source', 'slow-loop', 'wrong-process', 'stopped', 'ambiguous-task')) {
        Reset-Fixture
        switch ($case) {
            'unhealthy' { [IO.File]::WriteAllText($configPath, $script:baseline.Replace('Healthy', 'Degraded')) }
            'wrong-source' { [IO.File]::WriteAllText($configPath, $script:baseline.Replace('DemoLob', 'OtherSource')) }
            'slow-loop' { [IO.File]::WriteAllText($configPath, $script:baseline.Replace(':15', ':90')) }
            'wrong-process' { $script:mode = $case }
            'stopped' { $script:taskState = 'Ready' }
            'ambiguous-task' { $script:taskCount = 2 }
        }
        $before = [IO.File]::ReadAllText($configPath)
        Reject { & $run } 'baseline requires|PID does not belong'
        Check ($script:sleepCalls -eq 0 -and [IO.File]::ReadAllText($configPath) -ceq $before) "$case baseline fails without mutation"
    }
    Check (@(Get-ChildItem -LiteralPath $fixture -Filter '.lob-warning-*.tmp').Count -eq 0) 'All named temporary config files cleaned up'
    $state = @{ callerMismatch = $false; guestExitCode = 0; createFailure = $false; target = $target; submitted = ''; createCommand = '' }
    $global:AzResponder = {
        $command = $args -join ' '
        if ($command -like 'account show*') {
            $id = if ($state.callerMismatch) { $state.target.TenantId } else { $state.target.SubscriptionId }
            return (@{id=$id; tenantId=$state.target.TenantId; state='Enabled'} | ConvertTo-Json)
        }
        if ($command -like 'connectedmachine run-command create*') {
            $index = [Array]::IndexOf($args, '--script')
            $state.submitted = Get-Content -LiteralPath $args[$index + 1].TrimStart('@') -Raw
            $state.createCommand = $command
            if ($state.createFailure) { throw 'Synthetic ambiguous create failure' }
            return '{}'
        }
        if ($command -like 'connectedmachine run-command show*') {
            return (@{provisioningState='Succeeded';instanceView=@{executionState='Succeeded';exitCode=$state.guestExitCode}} | ConvertTo-Json)
        }
        throw "Unexpected mocked warning Azure call: $command"
    }.GetNewClosure()
    $state.callerMismatch = $true
    $before = $global:AzCalls.Count
    Reject { & $helper @target -ApproveWarningWindow } 'context does not match'
    Check ($global:AzCalls.Count -eq $before + 1) 'Wrong caller target fails before Run Command'
    $state.callerMismatch = $false
    $result = & $helper @target -ApproveWarningWindow
    Check ($result.Action -eq 'WarnForDuration' -and $result.Result.instanceView.exitCode -eq 0) 'Approved wrapper requires actual mocked guest completion'
    Check ($state.submitted.Contains('Set-ScenarioConfig') -and $state.createCommand.Contains('--timeout-in-seconds 300')) 'Approved create uses guarded script and bounded Arc timeout'
    $state.guestExitCode = 9
    Reject { & $helper @target -ApproveWarningWindow } 'execution failed'
    $state.createFailure = $true
    $before = @($global:AzCalls | Where-Object { $_ -like 'connectedmachine run-command create*' }).Count
    Reject { & $helper @target -ApproveWarningWindow } 'Synthetic ambiguous'
    Check (@($global:AzCalls | Where-Object { $_ -like 'connectedmachine run-command create*' }).Count -eq $before + 1) 'Ambiguous create never resends a consumed warning'
    Write-Host "$count LOB warning assertions passed; guest operations were mocked against local fixture files."
} finally {
    $global:AzResponder = $responderBefore
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
