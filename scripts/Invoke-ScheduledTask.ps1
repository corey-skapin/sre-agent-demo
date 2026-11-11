#Requires -Version 7.4
<#
.SYNOPSIS
    Lists, runs, turns on and turns off the three PROACTIVE scheduled tasks: the estate health check, the Bicep drift scan and the governance deck.

.DESCRIPTION
    Status    Shows each task: Off or On, its schedule, when it last ran and runs next, how many runs, and the thread of the last run.
    Run       Runs one task now (-Name) with the agent's run-now call and prints the thread it started. With -Wait it follows that thread until
              the agent is idle. The task's agent is read-only, so nothing waits for a click.
    Enable / Disable
              Turns one task's schedule on or off, keeping its schedule and prompt as they are on the agent. The apply never changes this once
              a task exists. A schedule that is On starts agent threads by itself, and each thread spends AAUs.

    The tasks are created Off by Initialize-SreConfiguration.ps1. Whether run-now works on an Off task is not proven live: if the agent refuses,
    run -Action Enable, then -Action Run, then -Action Disable.

    Use -WhatIf on Run, Enable or Disable to see what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [ValidateSet('Status', 'Run', 'Enable', 'Disable')]
    [string]$Action = 'Status',

    [string]$Name,

    [string]$SkinPath = '',

    [switch]$Wait,

    [ValidateRange(1, 60)]
    [int]$TimeoutMinutes = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreActs.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreActsExtras.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
$acts = Get-SreActsDesired -Skin $skin -SubscriptionId $SubscriptionId
if (-not $acts -or 'PROACTIVE' -notin $acts.modules) { throw 'This skin does not turn on PROACTIVE, so there are no scheduled tasks. See docs/proactive-checks.md.' }
$taskNames = @($acts.tasks | ForEach-Object { $_.name })
if ($Action -ne 'Status' -and -not $Name) { throw "Say which task with -Name: $($taskNames -join ', ')." }
if ($Name -and $Name -notin $taskNames) { throw "Unknown task '$Name'. The tasks are: $($taskNames -join ', ')." }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$context = New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName "rg-$($skin.azure.namePrefix)-sre" -AgentName ([string]$skin.labels.agentName)

Invoke-SreActsTask -Context $context -TaskNames $taskNames -Action $Action -Name $Name -Wait:$Wait -TimeoutMinutes $TimeoutMinutes -WhatIf:$WhatIfPreference
