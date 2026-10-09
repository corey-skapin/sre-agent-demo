#Requires -Version 7.4
<#
.SYNOPSIS
    Creates or prints the Azure Monitor log alert for the T11 LOB Arc bridge app.

.DESCRIPTION
    The alert watches the existing arc-demo Log Analytics workspace for Windows
    Application events emitted by the sample LOB app on a target Arc server, then
    routes the incident to the existing arc-demo Action Group consumed by SRE Agent.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$NamePrefix = 'arc-demo',

    [string]$ArcResourceGroupName,

    [string]$WorkspaceName,

    [string]$ActionGroupName,

    [string]$AlertName,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$MachineName = 'win-app-01',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,79}$')]
    [string]$EventSource = 'ArcLobBridgeApp',

    [ValidateSet('Create', 'ShowQuery')]
    [string]$Action = 'ShowQuery'
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

if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $WorkspaceName) { $WorkspaceName = "law-$NamePrefix" }
if (-not $ActionGroupName) { $ActionGroupName = "ag-$NamePrefix" }
if (-not $AlertName) { $AlertName = "alert-$NamePrefix-lob-arc-app-fault" }

$query = @"
Event
| where TimeGenerated > ago(10m)
| where EventLog =~ "Application"
| where Source == "$EventSource"
| where EventID in (4100, 4101, 4200)
| where Computer =~ "$MachineName" or _ResourceId has "/machines/$MachineName"
| project TimeGenerated, Computer, EventLog, Source, EventID, EventLevelName, RenderedDescription, _ResourceId
"@

if ($Action -eq 'ShowQuery') {
    [pscustomobject]@{
        AlertName = $AlertName
        WorkspaceName = $WorkspaceName
        ActionGroupName = $ActionGroupName
        Query = $query
        Condition = "count '$($query.Replace("'", "''"))' > 0"
    }
    return
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for -Action Create.'
}

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
$accountTenant = Get-AzTsv -Arguments @('account', 'show', '--query', 'tenantId') -Description 'current Azure CLI tenant'
if ($accountTenant -ne $TenantId) {
    throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
}

$workspaceId = Get-AzTsv -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--resource-group', $ArcResourceGroupName,
    '--workspace-name', $WorkspaceName,
    '--query', 'id'
) -Description "Log Analytics workspace '$WorkspaceName'"

$actionGroupId = Get-AzTsv -Arguments @(
    'monitor', 'action-group', 'show',
    '--resource-group', $ArcResourceGroupName,
    '--name', $ActionGroupName,
    '--query', 'id'
) -Description "Action Group '$ActionGroupName'"

$condition = "count '$($query.Replace("'", "''"))' > 0"
$target = "scheduled query alert '$AlertName' in '$ArcResourceGroupName'"
if ($PSCmdlet.ShouldProcess($target, 'create or update Azure Monitor alert')) {
    Invoke-AzCli -Arguments @(
        'monitor', 'scheduled-query', 'create',
        '--resource-group', $ArcResourceGroupName,
        '--name', $AlertName,
        '--scopes', $workspaceId,
        '--description', "T11 LOB Arc bridge app fault event from $MachineName",
        '--condition', $condition,
        '--evaluation-frequency', '5m',
        '--window-size', '10m',
        '--severity', '2',
        '--action-groups', $actionGroupId,
        '--auto-mitigate', 'true',
        '--only-show-errors',
        '-o', 'json'
    )
}
