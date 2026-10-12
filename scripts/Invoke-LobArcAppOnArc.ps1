#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys and operates the T11 LOB Arc bridge app on a Windows Arc server.

.DESCRIPTION
    Uses Azure Arc-enabled servers Run command to copy a tiny PowerShell LOB app
    to a target Windows Arc machine, run it as a SYSTEM scheduled task, toggle
    its fault mode, and collect Application-log/text-log evidence. Use
    -GuestScriptOutputPath to generate the guest script for a manual fallback
    without invoking Azure.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$NamePrefix = 'arc-demo',

    [string]$ArcResourceGroupName,

    [string]$MachineName = 'win-app-01',

    [ValidateSet('Deploy', 'Start', 'Stop', 'Status', 'InduceFault', 'ResetFault', 'CollectLogs', 'Remove')]
    [string]$Action = 'Status',

    [ValidateSet('CrashOnProcessing', 'Degraded')]
    [string]$FaultMode = 'CrashOnProcessing',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,79}$')]
    [string]$EventSource = 'ArcLobBridgeApp',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,63}$')]
    [string]$TaskName = 'ArcSreLobApp',

    [string]$AppRoot = 'C:\ProgramData\ArcSreLobApp',

    [string]$AppSourcePath,

    [string]$SourceRepositoryUrl = 'https://github.com/<org>/lob-arc-app-demo',

    [string]$SourceCommit = 'pending-live-demo-commit',

    [string]$SourcePath = 'LobArcBridgeApp.ps1',

    [string]$AppName = 'Arc LOB Bridge App',

    [ValidateRange(5, 300)]
    [int]$LoopSeconds = 15,

    [string]$GuestScriptOutputPath,

    [string]$SkinPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $exitCode`n$text"
    }

    return $text
}

function Get-AzTsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $value = Invoke-AzCli -Arguments ($Arguments + @('--only-show-errors', '-o', 'tsv'))
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Unable to resolve $Description."
    }

    return $value.Trim()
}

function ConvertTo-GuestLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    return "'$($Value.Replace("'", "''"))'"
}

function ConvertTo-Base64Utf8 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-RunCommandName {
    $suffix = (Get-Date).ToUniversalTime().ToString('MMddHHmmss')
    $safeAction = ($Action.ToLowerInvariant() -replace '[^a-z0-9-]', '-')
    $name = "t11-lob-$safeAction-$suffix"
    if ($name.Length -gt 36) {
        $name = $name.Substring(0, 36).TrimEnd('-')
    }

    return $name
}

function Expand-GuestTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [hashtable]$Tokens = @{}
    )

    $expanded = $Template
    foreach ($key in $Tokens.Keys) {
        $expanded = $expanded.Replace("__${key}__", [string]$Tokens[$key])
    }

    return $expanded
}

function New-DeployGuestScript {
    if (-not (Test-Path -LiteralPath $AppSourcePath)) {
        throw "App source not found: $AppSourcePath"
    }

    $appScript = Get-Content -LiteralPath $AppSourcePath -Raw
    $config = [ordered]@{
        AppName = $AppName
        FaultMode = 'Healthy'
        IncidentId = 'none'
        EventSource = $EventSource
        LoopSeconds = $LoopSeconds
        HeartbeatEveryCycles = 4
        SourceRepositoryUrl = $SourceRepositoryUrl
        SourceCommit = $SourceCommit
        SourcePath = $SourcePath
    }
    $configJson = ConvertTo-Json $config -Depth 5

    $template = @'
$AppRoot = __APP_ROOT__
$TaskName = __TASK_NAME__
$EventSource = __EVENT_SOURCE__
$AppScriptBase64 = __APP_SCRIPT_BASE64__
$ConfigBase64 = __CONFIG_BASE64__

$ErrorActionPreference = 'Stop'
$appScriptPath = Join-Path $AppRoot 'LobArcBridgeApp.ps1'
$configPath = Join-Path $AppRoot 'appsettings.json'
$logRoot = Join-Path $AppRoot 'logs'
$logPath = Join-Path $logRoot 'lob-arc-app.log'
$pidPath = Join-Path $AppRoot 'lob-arc-app.pid'
New-Item -Path $AppRoot -ItemType Directory -Force | Out-Null
New-Item -Path $logRoot -ItemType Directory -Force | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($appScriptPath, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AppScriptBase64)), $utf8NoBom)
[System.IO.File]::WriteAllText($configPath, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigBase64)), $utf8NoBom)

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        New-EventLog -LogName Application -Source $EventSource
    }
}
catch {
    Write-Warning "Could not create event source '$EventSource': $($_.Exception.Message)"
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if (Test-Path -LiteralPath $pidPath) {
    $pidText = Get-Content -LiteralPath $pidPath -Raw
    if ($pidText -match '^\s*(\d+)\s*$') {
        Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

$taskArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$appScriptPath`" -ConfigPath `"$configPath`" -LogPath `"$logPath`""
$taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgument
$taskTrigger = New-ScheduledTaskTrigger -AtStartup
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 30)
Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Action = 'Deploy'
    AppRoot = $AppRoot
    TaskName = $TaskName
    TaskState = $task.State
    LastTaskResult = $info.LastTaskResult
    ConfigPath = $configPath
    LogPath = $logPath
    EventSource = $EventSource
}
'@

    Expand-GuestTemplate -Template $template -Tokens @{
        APP_ROOT = ConvertTo-GuestLiteral $AppRoot
        TASK_NAME = ConvertTo-GuestLiteral $TaskName
        EVENT_SOURCE = ConvertTo-GuestLiteral $EventSource
        APP_SCRIPT_BASE64 = ConvertTo-GuestLiteral (ConvertTo-Base64Utf8 $appScript)
        CONFIG_BASE64 = ConvertTo-GuestLiteral (ConvertTo-Base64Utf8 $configJson)
    }
}

function New-StartGuestScript {
    $template = @'
$TaskName = __TASK_NAME__
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{ Action = 'Start'; TaskName = $TaskName; TaskState = $task.State; LastTaskResult = $info.LastTaskResult }
'@

    Expand-GuestTemplate -Template $template -Tokens @{ TASK_NAME = ConvertTo-GuestLiteral $TaskName }
}

function New-StopGuestScript {
    $template = @'
$AppRoot = __APP_ROOT__
$TaskName = __TASK_NAME__
$pidPath = Join-Path $AppRoot 'lob-arc-app.pid'
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $pidPath) {
    $pidText = Get-Content -LiteralPath $pidPath -Raw
    if ($pidText -match '^\s*(\d+)\s*$') {
        Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    }
}
$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{ Action = 'Stop'; TaskName = $TaskName; TaskState = $task.State; LastTaskResult = $info.LastTaskResult }
'@

    Expand-GuestTemplate -Template $template -Tokens @{
        APP_ROOT = ConvertTo-GuestLiteral $AppRoot
        TASK_NAME = ConvertTo-GuestLiteral $TaskName
    }
}

function New-SetFaultGuestScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$IncidentId
    )

    $template = @'
$AppRoot = __APP_ROOT__
$TaskName = __TASK_NAME__
$Mode = __FAULT_MODE__
$IncidentId = __INCIDENT_ID__
$configPath = Join-Path $AppRoot 'appsettings.json'
$pidPath = Join-Path $AppRoot 'lob-arc-app.pid'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "App config does not exist at $configPath. Run Deploy first."
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$config.FaultMode = $Mode
$config.IncidentId = $IncidentId
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $pidPath) {
    $pidText = Get-Content -LiteralPath $pidPath -Raw
    if ($pidText -match '^\s*(\d+)\s*$') {
        Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    }
}
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{ Action = 'SetFaultMode'; FaultMode = $Mode; IncidentId = $IncidentId; TaskState = $task.State; LastTaskResult = $info.LastTaskResult }
'@

    Expand-GuestTemplate -Template $template -Tokens @{
        APP_ROOT = ConvertTo-GuestLiteral $AppRoot
        TASK_NAME = ConvertTo-GuestLiteral $TaskName
        FAULT_MODE = ConvertTo-GuestLiteral $Mode
        INCIDENT_ID = ConvertTo-GuestLiteral $IncidentId
    }
}

function New-StatusGuestScript {
    param([int]$Tail = 20)

    $template = @'
$AppRoot = __APP_ROOT__
$TaskName = __TASK_NAME__
$EventSource = __EVENT_SOURCE__
$Tail = __TAIL__
$configPath = Join-Path $AppRoot 'appsettings.json'
$logPath = Join-Path $AppRoot 'logs\lob-arc-app.log'
$pidPath = Join-Path $AppRoot 'lob-arc-app.pid'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $TaskName } else { $null }
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } else { $null }
$pid = if (Test-Path -LiteralPath $pidPath) { (Get-Content -LiteralPath $pidPath -Raw).Trim() } else { $null }
$process = if ($pid -match '^\d+$') { Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue } else { $null }
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $EventSource; StartTime = (Get-Date).AddHours(-4) } -ErrorAction SilentlyContinue |
    Select-Object -First 10 TimeCreated, ProviderName, Id, LevelDisplayName, Message
$logTail = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail $Tail } else { @('Log file not present.') }
[pscustomobject]@{
    Action = 'Status'
    AppRoot = $AppRoot
    TaskName = $TaskName
    TaskState = if ($task) { $task.State } else { 'NotRegistered' }
    LastTaskResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
    FaultMode = if ($config) { $config.FaultMode } else { $null }
    SourceRepositoryUrl = if ($config) { $config.SourceRepositoryUrl } else { $null }
    SourceCommit = if ($config) { $config.SourceCommit } else { $null }
    Pid = $pid
    ProcessRunning = [bool]$process
    RecentEvents = $events
    LogTail = $logTail
}
'@

    Expand-GuestTemplate -Template $template -Tokens @{
        APP_ROOT = ConvertTo-GuestLiteral $AppRoot
        TASK_NAME = ConvertTo-GuestLiteral $TaskName
        EVENT_SOURCE = ConvertTo-GuestLiteral $EventSource
        TAIL = [string]$Tail
    }
}

function New-RemoveGuestScript {
    $template = @'
$AppRoot = __APP_ROOT__
$TaskName = __TASK_NAME__
$pidPath = Join-Path $AppRoot 'lob-arc-app.pid'
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $pidPath) {
    $pidText = Get-Content -LiteralPath $pidPath -Raw
    if ($pidText -match '^\s*(\d+)\s*$') {
        Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    }
}
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
[pscustomobject]@{ Action = 'Remove'; TaskName = $TaskName; AppRoot = $AppRoot; DataRetained = $true }
'@

    Expand-GuestTemplate -Template $template -Tokens @{
        APP_ROOT = ConvertTo-GuestLiteral $AppRoot
        TASK_NAME = ConvertTo-GuestLiteral $TaskName
    }
}

function Get-GuestScript {
    switch ($Action) {
        'Deploy' { return New-DeployGuestScript }
        'Start' { return New-StartGuestScript }
        'Stop' { return New-StopGuestScript }
        'Status' { return New-StatusGuestScript }
        'CollectLogs' { return New-StatusGuestScript -Tail 80 }
        'InduceFault' {
            $incidentId = "t11-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
            return New-SetFaultGuestScript -Mode $FaultMode -IncidentId $incidentId
        }
        'ResetFault' { return New-SetFaultGuestScript -Mode 'Healthy' -IncidentId 'reset' }
        'Remove' { return New-RemoveGuestScript }
    }
}

function Invoke-ArcRunCommand {
    param([Parameter(Mandatory = $true)][string]$Script)

    $runCommandName = Get-RunCommandName
    $target = "Arc machine '$MachineName' in '$ArcResourceGroupName'"
    if (-not $PSCmdlet.ShouldProcess($target, "create Run command '$runCommandName' for T11 $Action")) {
        return
    }

    $scriptPath = Join-Path $env:TEMP "$runCommandName.ps1"
    [System.IO.File]::WriteAllText($scriptPath, $Script, [System.Text.UTF8Encoding]::new($false))
    try {
        $resultText = Invoke-AzCli -Arguments @(
            'connectedmachine', 'run-command', 'create',
            '--name', $runCommandName,
            '--machine-name', $MachineName,
            '--resource-group', $ArcResourceGroupName,
            '--script', "@$scriptPath",
            '--only-show-errors',
            '-o', 'json'
        )
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }

    $result = $null
    try {
        $jsonStart = $resultText.IndexOf('{')
        if ($jsonStart -ge 0) {
            $result = $resultText.Substring($jsonStart) | ConvertFrom-Json -Depth 100
        } else {
            $result = [pscustomobject]@{ rawOutput = $resultText }
        }
    } catch {
        $result = [pscustomobject]@{ rawOutput = $resultText; parseError = $_.Exception.Message }
    }

    [pscustomobject]@{
        Action = $Action
        MachineName = $MachineName
        RunCommandName = $runCommandName
        Result = $result
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$skinModule = Join-Path $PSScriptRoot 'lib\DemoSkin.psm1'
Import-Module $skinModule -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('MachineName')) { $MachineName = Get-DemoSkinValue -Skin $skin -Path 'sre.targetArcMachine' -Default $MachineName }
if (-not $PSBoundParameters.ContainsKey('FaultMode')) { $FaultMode = Get-DemoSkinValue -Skin $skin -Path 'sre.lobFaultMode' -Default $FaultMode }
if (-not $PSBoundParameters.ContainsKey('EventSource')) { $EventSource = Get-DemoSkinValue -Skin $skin -Path 'labels.lobEventSource' -Default $EventSource }
if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName = Get-DemoSkinValue -Skin $skin -Path 'labels.lobTaskName' -Default $TaskName }
if (-not $PSBoundParameters.ContainsKey('AppName')) { $AppName = Get-DemoSkinValue -Skin $skin -Path 'labels.lobAppName' -Default $AppName }
if (-not $PSBoundParameters.ContainsKey('SourceRepositoryUrl')) { $SourceRepositoryUrl = Get-DemoSkinValue -Skin $skin -Path 'codeContext.lobRepositoryUrl' -Default $SourceRepositoryUrl }
if (-not $PSBoundParameters.ContainsKey('SourceCommit')) { $SourceCommit = Get-DemoSkinValue -Skin $skin -Path 'codeContext.lobSourceCommit' -Default $SourceCommit }
if (-not $PSBoundParameters.ContainsKey('SourcePath')) { $SourcePath = Get-DemoSkinValue -Skin $skin -Path 'codeContext.lobSourcePath' -Default $SourcePath }

if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $AppSourcePath) {
    $AppSourcePath = Join-Path $repoRoot 'samples\lob-arc-app\LobArcBridgeApp.ps1'
}

$guestScript = Get-GuestScript

if ($GuestScriptOutputPath) {
    $resolvedGuestScriptPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($GuestScriptOutputPath)
    Set-Content -LiteralPath $resolvedGuestScriptPath -Value $guestScript -Encoding UTF8
    [pscustomobject]@{
        Action = $Action
        GuestScriptOutputPath = $resolvedGuestScriptPath
        ManualFallback = 'Copy this script to the target Windows Arc server and run it in an elevated PowerShell session.'
    }
    return
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required unless -GuestScriptOutputPath is used for manual fallback.'
}

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
$accountTenant = Get-AzTsv -Arguments @('account', 'show', '--query', 'tenantId') -Description 'current Azure CLI tenant'
if ($accountTenant -ne $TenantId) {
    throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
}

Invoke-ArcRunCommand -Script $guestScript
