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

    [string]$Location,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$MachineName = 'win-app-01',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,79}$')]
    [string]$EventSource = 'ArcLobBridgeApp',

    [ValidateSet('Create', 'ShowQuery')]
    [string]$Action = 'ShowQuery',

    [string]$SkinPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments $Arguments
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

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
$skinModule = Join-Path $PSScriptRoot 'lib\DemoSkin.psm1'
Import-Module $skinModule -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('MachineName')) { $MachineName = Get-DemoSkinValue -Skin $skin -Path 'sre.targetArcMachine' -Default $MachineName }
if (-not $PSBoundParameters.ContainsKey('EventSource')) { $EventSource = Get-DemoSkinValue -Skin $skin -Path 'labels.lobEventSource' -Default $EventSource }

if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $WorkspaceName) { $WorkspaceName = "law-$NamePrefix" }
if (-not $ActionGroupName) { $ActionGroupName = "ag-$NamePrefix" }
if (-not $AlertName) { $AlertName = "alert-$NamePrefix-lob-arc-app-fault" }
foreach ($name in @($ArcResourceGroupName, $WorkspaceName, $ActionGroupName, $AlertName)) { Assert-SreName -Value $name -Description 'resource name' }
Assert-SreName -Value $MachineName -Description 'machine name' -Pattern '^[A-Za-z0-9_.-]+$'
Assert-SreName -Value $EventSource -Description 'event source' -Pattern '^[A-Za-z][A-Za-z0-9_.-]{0,79}$'
$titleContains = Get-DemoSkinValue -Skin $skin -Path 'labels.lobAlertTitleContains'
$displayName = "$($skin.labels.demoTitle) - $titleContains"

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

Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
if (-not $Location) {
    $Location = Get-AzTsv -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '-g', $ArcResourceGroupName, '-n', $WorkspaceName, '--query', 'location') -Description 'workspace location'
}
Assert-SreName -Value $Location -Description 'location' -Pattern '^[a-z][a-z0-9]+$'

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

$target = "scheduled query alert '$AlertName' in '$ArcResourceGroupName'"
if ($PSCmdlet.ShouldProcess($target, 'create or update Azure Monitor alert')) {
    $body = @{
        location = $Location
        properties = @{
            displayName = $displayName
            description = "T11 LOB Arc bridge app fault event from $MachineName"
            severity = 2
            enabled = $true
            evaluationFrequency = 'PT5M'
            windowSize = 'PT10M'
            scopes = @($workspaceId)
            criteria = @{
                allOf = @(@{
                    query = $query
                    timeAggregation = 'Count'
                    operator = 'GreaterThan'
                    threshold = 0
                    failingPeriods = @{
                        numberOfEvaluationPeriods = 1
                        minFailingPeriodsToAlert = 1
                    }
                })
            }
            autoMitigate = $true
            actions = @{
                actionGroups = @($actionGroupId)
            }
        }
    } | ConvertTo-Json -Depth 20

    $tempBody = Join-Path $env:TEMP "lob-arc-alert-$(Get-Random).json"
    [System.IO.File]::WriteAllText($tempBody, $body, [System.Text.UTF8Encoding]::new($false))
    try {
        Invoke-AzCli -Arguments @(
            'rest',
            '--method', 'put',
            '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules/${AlertName}?api-version=2023-03-15-preview",
            '--body', "@$tempBody",
            '--headers', 'Content-Type=application/json',
            '--only-show-errors',
            '-o', 'json'
        )
    } finally {
        Remove-Item -LiteralPath $tempBody -Force -ErrorAction SilentlyContinue
    }
}
