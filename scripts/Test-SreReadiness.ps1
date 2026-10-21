#Requires -Version 7.4
<#
.SYNOPSIS
Read-only, bounded readiness inspection. Exit 0 pass, 1 fail/error, 2 pending.
.DESCRIPTION
Ready inspects ARM and supported full service configuration; fresh incident
telemetry/rehearsal remains a separate pending gate. Hibernated verifies the
retained UAMI/group, absent parent/diagnostics and revoked owned grants.
No Azure account selection, faults, guest commands or cloud mutations are performed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$SkinPath = '',
    [ValidateSet('Ready', 'Hibernated')][string]$DesiredState = 'Ready',
    [ValidateSet('Json', 'Table')][string]$OutputFormat = 'Table',
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 180,
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PreviousIdentityPrincipalId
)
$ErrorActionPreference = 'Stop'
$arguments = @{
    SubscriptionId = $SubscriptionId; TenantId = $TenantId; SkinPath = $SkinPath
    DesiredState = $DesiredState; PreviousIdentityPrincipalId = $PreviousIdentityPrincipalId
}
$job = $null
try {
    $job = Start-Job -ScriptBlock {
        param($ModulePath, $Parameters)
        $items = @(& {
            Import-Module $ModulePath -Force
            Get-SreReadinessReport @Parameters
        } 3>&1)
        $reports = @($items | Where-Object { $_ -isnot [Management.Automation.WarningRecord] })
        if ($reports.Count -ne 1) { throw 'Readiness worker must return exactly one report.' }
        # Remoting can replay host warnings despite Receive-Job preferences.
        @{
            report = $reports[0]
            warnings = @($items | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        }
    } -ArgumentList (Join-Path $PSScriptRoot 'lib\SreReadiness.psm1'), $arguments
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        throw [TimeoutException]::new("Readiness exceeded ${TimeoutSeconds}s; completion remains pending.")
    }
    if ($job.State -ne 'Completed') { throw "Readiness worker ended in state $($job.State)." }
    $inspection = Receive-Job -Job $job -ErrorAction Stop
    $report = $inspection.report
    $inspectionWarnings = @($inspection.warnings)
    # Do not leak PowerShell job remoting metadata into the shared JSON contract.
    $clean = [ordered]@{}
    foreach ($key in @('schemaVersion', 'workload', 'checkedAtUtc', 'subscriptionId', 'tenantId', 'resourceGroups', 'desiredState', 'status', 'checks')) {
        $clean[$key] = $report.$key
    }
    $report = $clean
    if ($inspectionWarnings.Count) {
        $report.checks += @(@{
            id = 'inspection-warnings'; resourceId = ''; required = $false
            expected = 'Warnings surfaced without corrupting JSON'; observed = @($inspectionWarnings | ForEach-Object { "$_" })
            status = 'pending'; message = 'Azure/worker warnings require review; required checks retain their own outcomes.'
        })
    }
} catch {
    $isTimeout = $_.Exception -is [TimeoutException]
    $status = if ($isTimeout) { 'pending' } else { 'fail' }
    $report = [ordered]@{
        schemaVersion = 1; workload = 'sre-agent'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceGroups = @()
        desiredState = $DesiredState; status = $status
        checks = @(@{ id = 'inspection-error'; resourceId = ''; required = $true; expected = 'Bounded successful inspection'; observed = $null; status = $status; message = $_.Exception.Message })
    }
} finally {
    if ($job) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}
if ($OutputFormat -eq 'Json') { $report | ConvertTo-Json -Depth 30 }
else { $report.checks | ForEach-Object { [pscustomobject]$_ } | Format-Table id, status, message -Wrap; Write-Host "Overall: $($report.status)" }
switch ($report.status) { 'pass' { exit 0 }; 'pending' { exit 2 }; default { exit 1 } }
