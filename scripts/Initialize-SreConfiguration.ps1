#Requires -Version 7.4
<#
.SYNOPSIS
Renders or reconciles current-schema SRE configuration using pinned official protocols.
.DESCRIPTION
Default rendering is local. Inspect/Apply use the exact data-plane paths published
in microsoft/sre-agent templates. Apply backs up full objects outside git, preserves
parent/identity/history, updates named objects only and verifies read-back.
When the skin requires T12 (the Friday release), Apply also sets the GitHub tool policy and the
repository-only instruction first, then the skills and the Stop hook, then the handler and plan,
and last the code repository. The repository needs the one-time GitHub sign-in; add -GitHubSignIn
to print the link and wait for it. Run Apply again after the sign-in with a new -BackupPath.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$SkinPath = '',
    [switch]$Inspect,
    [switch]$Apply,
    [string]$BackupPath,
    [switch]$GitHubSignIn,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SreConfiguration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreReleaseExtras.psm1') -Force
$desired = Get-SreDesiredConfiguration -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath
if ($Inspect -and $Apply) { throw 'Choose -Inspect or -Apply, not both.' }
if (-not $Inspect -and -not $Apply) { $desired | ConvertTo-Json -Depth 100; return }
if ($Apply -and [string]::IsNullOrWhiteSpace($BackupPath)) { throw '-Apply requires an explicit -BackupPath outside the repository before any cloud request.' }
$session = New-SreConfigurationSession -Desired $desired -TimeoutSeconds $TimeoutSeconds
try {
    $context = if ($desired.release) { ConvertTo-SreDataContext -Session $session -SubscriptionId $SubscriptionId -TenantId $TenantId } else { $null }
    if ($Inspect) {
        $snapshot = Get-SreConfigurationSnapshot $session
        $report = @{
            desired = $desired; observed = $snapshot
            reconciliation = Get-SreConfigurationPlan $desired $snapshot
        }
        if ($context) {
            $observedExtras = Get-SreReleaseObserved -Context $context -Desired $desired
            $report.release = @{
                before = Get-SreReleaseExtrasPlan -Desired $desired -Observed $observedExtras -Stage Before
                after = Get-SreReleaseExtrasPlan -Desired $desired -Observed $observedExtras -Stage After
            }
        }
        $report | ConvertTo-Json -Depth 100
    } else {
        $releaseBefore = $null
        if ($context) { $releaseBefore = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage Before -BackupPath $BackupPath -WhatIf:$WhatIfPreference }
        $result = Invoke-SreConfigurationReconcile -Desired $desired -Session $session -BackupPath $BackupPath -WhatIf:$WhatIfPreference
        if ($context) {
            $releaseAfter = Invoke-SreReleaseExtras -Context $context -Desired $desired -Stage After -BackupPath $BackupPath -GitHubSignIn:$GitHubSignIn -WhatIf:$WhatIfPreference
            $result.release = @{ before = $releaseBefore; after = $releaseAfter }
        }
        $result | ConvertTo-Json -Depth 100
    }
} finally { $session.token = $null }
