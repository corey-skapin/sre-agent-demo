#Requires -Version 7.4
<#
.SYNOPSIS
Renders or reconciles current-schema SRE configuration using pinned official protocols.
.DESCRIPTION
Default rendering is local. Inspect/Apply use the exact data-plane paths published
in microsoft/sre-agent templates. Apply backs up full objects outside git, preserves
parent/identity/history, updates named objects only and verifies read-back.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$SkinPath = '',
    [switch]$Inspect,
    [switch]$Apply,
    [string]$BackupPath,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SreConfiguration.psm1') -Force
$desired = Get-SreDesiredConfiguration -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath
if ($Inspect -and $Apply) { throw 'Choose -Inspect or -Apply, not both.' }
if (-not $Inspect -and -not $Apply) { $desired | ConvertTo-Json -Depth 100; return }
if ($Apply -and [string]::IsNullOrWhiteSpace($BackupPath)) { throw '-Apply requires an explicit -BackupPath outside the repository before any cloud request.' }
$session = New-SreConfigurationSession -Desired $desired -TimeoutSeconds $TimeoutSeconds
try {
    if ($Inspect) {
        $snapshot = Get-SreConfigurationSnapshot $session
        @{
            desired = $desired; observed = $snapshot
            reconciliation = Get-SreConfigurationPlan $desired $snapshot
        } | ConvertTo-Json -Depth 100
    } else {
        Invoke-SreConfigurationReconcile -Desired $desired -Session $session -BackupPath $BackupPath -WhatIf:$WhatIfPreference |
            ConvertTo-Json -Depth 100
    }
} finally { $session.token = $null }
