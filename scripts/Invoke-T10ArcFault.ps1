#Requires -Version 7.4
<#
.SYNOPSIS
    Safely induces or resets T10 Arc-server experiment faults in the arc-demo lab.

.DESCRIPTION
    This helper targets one Arc-enabled server from arc-demo and either manipulates
    the backing lab Azure VM for a missed-heartbeat scenario or uses Azure Arc Run
    command for bounded guest-level scenarios. It is intentionally scoped to T10
    evidence gathering and does not modify C:\src\arc-demo.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$NamePrefix = 'arc-demo',

    [string]$ArcResourceGroupName,

    [string]$InfraResourceGroupName,

    [string]$MachineName = 'win-app-01',

    [string]$BackingVmName,

    [ValidateSet('HeartbeatByBackingVm', 'StopService', 'DiskPressure', 'CpuPressure', 'WriteEvent')]
    [string]$Scenario = 'HeartbeatByBackingVm',

    [ValidateSet('Induce', 'Reset', 'Status')]
    [string]$Action = 'Status',

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ServiceName = 'Spooler',

    [ValidateRange(64, 8192)]
    [int]$DiskFileSizeMB = 512,

    [ValidateRange(1, 1024)]
    [int]$MinimumFreeGB = 5,

    [ValidateRange(30, 1800)]
    [int]$CpuDurationSeconds = 300,

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

function Get-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $json = Invoke-AzCli -Arguments ($Arguments + @('--only-show-errors', '-o', 'json'))
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
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

function Get-RunCommandName {
    $suffix = (Get-Date).ToUniversalTime().ToString('MMddHHmmss')
    $safeScenario = ($Scenario.ToLowerInvariant() -replace '[^a-z0-9-]', '-')
    $safeAction = $Action.ToLowerInvariant()
    $name = "t10-$safeScenario-$safeAction-$suffix"
    if ($name.Length -gt 36) {
        $name = $name.Substring(0, 36).TrimEnd('-')
    }

    return $name
}

function Get-ScenarioScript {
    switch ($Scenario) {
        'StopService' {
            switch ($Action) {
                'Induce' {
                    return @"
`$serviceName = '$ServiceName'
`$svc = Get-Service -Name `$serviceName -ErrorAction Stop
Write-Output "Before: `$(`$svc.Name) `$(`$svc.Status)"
if (`$svc.Status -ne 'Stopped') {
    Stop-Service -Name `$serviceName -Force -ErrorAction Stop
}
Get-Service -Name `$serviceName | Select-Object Name, Status, StartType
"@
                }
                'Reset' {
                    return @"
`$serviceName = '$ServiceName'
`$svc = Get-Service -Name `$serviceName -ErrorAction Stop
Write-Output "Before: `$(`$svc.Name) `$(`$svc.Status)"
if (`$svc.Status -ne 'Running') {
    Start-Service -Name `$serviceName -ErrorAction Stop
}
Get-Service -Name `$serviceName | Select-Object Name, Status, StartType
"@
                }
                'Status' {
                    return @"
Get-Service -Name '$ServiceName' -ErrorAction Stop | Select-Object Name, Status, StartType
"@
                }
            }
        }
        'DiskPressure' {
            switch ($Action) {
                'Induce' {
                    return @"
`$markerDir = 'C:\ProgramData\ArcSreT10'
`$payload = Join-Path `$markerDir 't10-disk-pressure.bin'
`$requestedBytes = [int64]$DiskFileSizeMB * 1MB
`$minimumFreeBytes = [int64]$MinimumFreeGB * 1GB
New-Item -Path `$markerDir -ItemType Directory -Force | Out-Null
`$drive = Get-PSDrive -Name 'C'
if ((`$drive.Free - `$requestedBytes) -lt `$minimumFreeBytes) {
    throw "Refusing to create `$([Math]::Round(`$requestedBytes / 1MB)) MB file because C: free space would fall below $MinimumFreeGB GB."
}
`$stream = [System.IO.File]::Open(`$payload, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    `$stream.SetLength(`$requestedBytes)
}
finally {
    `$stream.Dispose()
}
Get-Item -LiteralPath `$payload | Select-Object FullName, Length
Get-PSDrive -Name 'C' | Select-Object Name, Used, Free
"@
                }
                'Reset' {
                    return @"
`$markerDir = 'C:\ProgramData\ArcSreT10'
`$payload = Join-Path `$markerDir 't10-disk-pressure.bin'
if (Test-Path -LiteralPath `$payload) {
    Remove-Item -LiteralPath `$payload -Force
}
Get-PSDrive -Name 'C' | Select-Object Name, Used, Free
"@
                }
                'Status' {
                    return @"
`$payload = 'C:\ProgramData\ArcSreT10\t10-disk-pressure.bin'
if (Test-Path -LiteralPath `$payload) {
    Get-Item -LiteralPath `$payload | Select-Object FullName, Length
}
else {
    Write-Output "Disk pressure file not present."
}
Get-PSDrive -Name 'C' | Select-Object Name, Used, Free
"@
                }
            }
        }
        'CpuPressure' {
            switch ($Action) {
                'Induce' {
                    return @"
`$markerDir = 'C:\ProgramData\ArcSreT10'
`$scriptPath = Join-Path `$markerDir 'cpu-pressure.ps1'
`$pidPath = Join-Path `$markerDir 'cpu-pressure.pid'
New-Item -Path `$markerDir -ItemType Directory -Force | Out-Null
`$worker = @'
param([int]`$DurationSeconds)
`$end = (Get-Date).AddSeconds(`$DurationSeconds)
while ((Get-Date) -lt `$end) {
    for (`$i = 0; `$i -lt 250000; `$i++) { [void][Math]::Sqrt(`$i) }
    Start-Sleep -Milliseconds 25
}
'@
Set-Content -LiteralPath `$scriptPath -Value `$worker -Encoding UTF8
`$process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `$scriptPath, '-DurationSeconds', '$CpuDurationSeconds' -PassThru
`$process.Id | Set-Content -LiteralPath `$pidPath -Encoding ASCII
Write-Output "Started bounded CPU pressure. PID=`$(`$process.Id), DurationSeconds=$CpuDurationSeconds"
"@
                }
                'Reset' {
                    return @"
`$pidPath = 'C:\ProgramData\ArcSreT10\cpu-pressure.pid'
if (Test-Path -LiteralPath `$pidPath) {
    `$pidText = Get-Content -LiteralPath `$pidPath -Raw
    try {
        `$pid = [int]`$pidText.Trim()
        Stop-Process -Id `$pid -Force -ErrorAction SilentlyContinue
        Write-Output "Stopped PID `$pid if it was still running."
    }
    catch {
        Write-Warning "PID marker contained an invalid value: `$pidText"
    }
    Remove-Item -LiteralPath `$pidPath -Force
}
else {
    Write-Output "CPU pressure PID marker not present."
}
"@
                }
                'Status' {
                    return @"
`$pidPath = 'C:\ProgramData\ArcSreT10\cpu-pressure.pid'
if (Test-Path -LiteralPath `$pidPath) {
    `$pid = [int](Get-Content -LiteralPath `$pidPath -Raw)
    Get-Process -Id `$pid -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, CPU, StartTime
}
else {
    Write-Output "CPU pressure PID marker not present."
}
"@
                }
            }
        }
        'WriteEvent' {
            switch ($Action) {
                'Induce' {
                    return @"
`$source = 'T10ArcFault'
if (-not [System.Diagnostics.EventLog]::SourceExists(`$source)) {
    New-EventLog -LogName Application -Source `$source
}
Write-EventLog -LogName Application -Source `$source -EventId 1010 -EntryType Error -Message 'T10 induced application error event for Azure SRE Agent on Arc experiment.'
Write-Output 'Wrote Application Error event source=T10ArcFault eventId=1010.'
"@
                }
                'Reset' {
                    return @"
`$source = 'T10ArcFault'
if ([System.Diagnostics.EventLog]::SourceExists(`$source)) {
    Write-EventLog -LogName Application -Source `$source -EventId 1011 -EntryType Information -Message 'T10 reset marker for Azure SRE Agent on Arc experiment.'
    Write-Output 'Wrote reset marker event source=T10ArcFault eventId=1011.'
}
else {
    Write-Output 'T10ArcFault source does not exist; nothing to reset.'
}
"@
                }
                'Status' {
                    return @"
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'T10ArcFault'; StartTime = (Get-Date).AddHours(-4) } -ErrorAction SilentlyContinue |
    Select-Object -First 10 TimeCreated, ProviderName, Id, LevelDisplayName, Message
"@
                }
            }
        }
    }
}

function Invoke-ArcRunCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script
    )

    $runCommandName = Get-RunCommandName
    $target = "Arc machine '$MachineName' in '$ArcResourceGroupName'"
    if (-not $PSCmdlet.ShouldProcess($target, "create Run command '$runCommandName' for $Scenario/$Action")) {
        return
    }

    # The connectedmachine CLI extension is more reliable with inline scripts
    # when the script is a single line. Preserve pipeline continuations first.
    $normalizedScript = ($Script -replace "\|\s*(`r`n|`n|`r)\s*", '| ') -replace "(`r`n|`n|`r)", '; '

    $resultText = Invoke-AzCli -Arguments @(
        'connectedmachine', 'run-command', 'create',
        '--name', $runCommandName,
        '--machine-name', $MachineName,
        '--resource-group', $ArcResourceGroupName,
        '--script', $normalizedScript,
        '--only-show-errors',
        '-o', 'json'
    )
    $result = $null
    try {
        $jsonStart = $resultText.IndexOf('{')
        if ($jsonStart -ge 0) {
            $result = $resultText.Substring($jsonStart) | ConvertFrom-Json
        } else {
            $result = [pscustomobject]@{ rawOutput = $resultText }
        }
    } catch {
        $result = [pscustomobject]@{ rawOutput = $resultText; parseError = $_.Exception.Message }
    }

    [pscustomobject]@{
        Scenario = $Scenario
        Action = $Action
        MachineName = $MachineName
        RunCommandName = $runCommandName
        Result = $result
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before this script.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$skinModule = Join-Path $PSScriptRoot 'lib\DemoSkin.psm1'
Import-Module $skinModule -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('MachineName')) { $MachineName = Get-DemoSkinValue -Skin $skin -Path 'sre.targetArcMachine' -Default $MachineName }
if (-not $PSBoundParameters.ContainsKey('Scenario')) { $Scenario = Get-DemoSkinValue -Skin $skin -Path 'sre.t10Scenario' -Default $Scenario }

if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $InfraResourceGroupName) { $InfraResourceGroupName = "rg-$NamePrefix-infra" }
if (-not $BackingVmName) { $BackingVmName = $MachineName }

Write-Verbose "Selecting subscription $SubscriptionId."
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
$accountTenant = Get-AzTsv -Arguments @('account', 'show', '--query', 'tenantId') -Description 'current Azure CLI tenant'
if ($accountTenant -ne $TenantId) {
    throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
}

$machine = Get-AzJson -Arguments @(
    'connectedmachine', 'show',
    '--resource-group', $ArcResourceGroupName,
    '--name', $MachineName,
    '--query', '{id:id, location:location, osName:osName, osType:osType, status:status}'
)
if (-not $machine) {
    throw "Unable to resolve Arc machine '$MachineName' in resource group '$ArcResourceGroupName'."
}

if ($Scenario -ne 'HeartbeatByBackingVm' -and $machine.osName -and $machine.osName -notmatch 'Windows') {
    Write-Warning "Scenario $Scenario currently emits Windows PowerShell guest commands, but target OS is '$($machine.osName)'."
}

if ($Scenario -eq 'HeartbeatByBackingVm') {
    switch ($Action) {
        'Induce' {
            if ($PSCmdlet.ShouldProcess("backing VM '$BackingVmName' in '$InfraResourceGroupName'", 'az vm deallocate --no-wait')) {
                Invoke-AzCli -Arguments @('vm', 'deallocate', '--resource-group', $InfraResourceGroupName, '--name', $BackingVmName, '--no-wait', '--only-show-errors') | Out-Null
                [pscustomobject]@{
                    Scenario = $Scenario
                    Action = $Action
                    MachineName = $MachineName
                    BackingVmName = $BackingVmName
                    Result = 'Deallocate requested. Wait for Heartbeat to age past the alert threshold.'
                }
            }
        }
        'Reset' {
            if ($PSCmdlet.ShouldProcess("backing VM '$BackingVmName' in '$InfraResourceGroupName'", 'az vm start --no-wait')) {
                Invoke-AzCli -Arguments @('vm', 'start', '--resource-group', $InfraResourceGroupName, '--name', $BackingVmName, '--no-wait', '--only-show-errors') | Out-Null
                [pscustomobject]@{
                    Scenario = $Scenario
                    Action = $Action
                    MachineName = $MachineName
                    BackingVmName = $BackingVmName
                    Result = 'Start requested. Verify Heartbeat returns in Log Analytics.'
                }
            }
        }
        'Status' {
            $vmView = Get-AzJson -Arguments @(
                'vm', 'get-instance-view',
                '--resource-group', $InfraResourceGroupName,
                '--name', $BackingVmName
            )
            $powerStateStatus = @($vmView.instanceView.statuses) | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1
            $powerState = if ($powerStateStatus) { $powerStateStatus.displayStatus } else { 'Unknown' }
            [pscustomobject]@{
                Scenario = $Scenario
                Action = $Action
                MachineName = $MachineName
                ArcStatus = $machine.status
                BackingVmName = $BackingVmName
                BackingVmPowerState = $powerState
                ArcMachineId = $machine.id
            }
        }
    }

    return
}

$scenarioScript = Get-ScenarioScript
if ([string]::IsNullOrWhiteSpace($scenarioScript)) {
    throw "No guest script generated for $Scenario/$Action."
}

Invoke-ArcRunCommand -Script $scenarioScript
