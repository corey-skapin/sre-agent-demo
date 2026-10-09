#Requires -Version 7.4
<#
.SYNOPSIS
    Toggles or inspects the arc-demo Azure-native Container App fault.

.DESCRIPTION
    Updates the optional arc-demo Container App workload by setting SIMULATE_CRASH
    to true (Break) or false (Repair). Status mode performs read-only inspection.
    The script is scoped to the Container App created by arc-demo T05 and does not
    automate any SRE Agent portal actions.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SubscriptionId,

    [string]$TenantId,

    [string]$NamePrefix = 'arc-demo',

    [string]$ResourceGroupName,

    [string]$ContainerAppName,

    [ValidateSet('Break', 'Repair', 'Status')]
    [string]$State = 'Status',

    [string]$SkinPath = '',

    [switch]$ShowMetrics
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

function Get-DefaultContainerAppName {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $safePrefix = $Prefix.ToLowerInvariant().Replace('_', '-')
    $name = "ca-$safePrefix-fault"
    if ($name.Length -gt 32) {
        return $name.Substring(0, 32)
    }

    return $name
}

function Get-ContainerAppStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName,

        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    $json = Invoke-AzCli -Arguments @(
        'containerapp', 'show',
        '--resource-group', $GroupName,
        '--name', $AppName,
        '--only-show-errors',
        '--output', 'json'
    )
    $app = $json | ConvertFrom-Json -Depth 50
    $simulateEnvVar = @($app.properties.template.containers[0].env | Where-Object { $_.name -eq 'SIMULATE_CRASH' } | Select-Object -First 1)

    [pscustomobject]@{
        ResourceGroup     = $GroupName
        Name              = $AppName
        Id                = $app.id
        Fqdn              = $app.properties.configuration.ingress.fqdn
        LatestRevision    = $app.properties.latestRevisionName
        ProvisioningState = $app.properties.provisioningState
        RunningStatus     = $app.properties.runningStatus
        SimulateCrash     = if ($simulateEnvVar) { $simulateEnvVar.value } else { '<not set>' }
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
if (-not $PSBoundParameters.ContainsKey('State')) { $State = Get-DemoSkinValue -Skin $skin -Path 'sre.nativeContainerFaultState' -Default $State }

if (-not $ResourceGroupName) {
    $ResourceGroupName = "rg-$NamePrefix-infra"
}
if (-not $ContainerAppName) {
    $ContainerAppName = Get-DefaultContainerAppName -Prefix $NamePrefix
}

if ($SubscriptionId) {
    Write-Host "Selecting subscription $SubscriptionId..."
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
}
if ($TenantId) {
    $accountTenant = Invoke-AzCli -Arguments @('account', 'show', '--query', 'tenantId', '--output', 'tsv', '--only-show-errors')
    if ($accountTenant -ne $TenantId) {
        throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
    }
}

if ($State -ne 'Status') {
    $simulateCrashValue = if ($State -eq 'Break') { 'true' } else { 'false' }
    $target = "$ResourceGroupName/$ContainerAppName"
    if ($PSCmdlet.ShouldProcess($target, "Set SIMULATE_CRASH=$simulateCrashValue")) {
        Invoke-AzCli -Arguments @(
            'containerapp', 'update',
            '--resource-group', $ResourceGroupName,
            '--name', $ContainerAppName,
            '--set-env-vars', "SIMULATE_CRASH=$simulateCrashValue",
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
}

$status = Get-ContainerAppStatus -GroupName $ResourceGroupName -AppName $ContainerAppName
$status

if ($ShowMetrics) {
    Write-Host ''
    Write-Host 'Recent RestartCount metric data:'
    Invoke-AzCli -Arguments @(
        'monitor', 'metrics', 'list',
        '--resource', $status.Id,
        '--metric', 'RestartCount',
        '--interval', 'PT1M',
        '--aggregation', 'Total',
        '--only-show-errors',
        '--output', 'table'
    ) | Write-Host
}
