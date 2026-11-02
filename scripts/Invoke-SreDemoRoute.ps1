#Requires -Version 7.4
<#
.SYNOPSIS
Prepare a fresh copy of a demo alert, or restore its canonical rule after use.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SkinPath,
    [Parameter(Mandatory)][ValidateSet('SQL','LOB','ContainerApp')][string]$Scenario,
    [Parameter(Mandatory)][ValidateSet('Prepare','Restore')][string]$Action,
    [string]$TemporaryRuleName,
    [ValidateRange(30,600)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\SreConfiguration.psm1')
$skin = Get-DemoSkin -Path $SkinPath
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$prefix = $skin.azure.namePrefix
$group = if ($Scenario -eq 'ContainerApp') { "rg-$prefix-infra" } else { "rg-$prefix" }
$collection = if ($Scenario -eq 'ContainerApp') { 'metricAlerts' } else { 'scheduledQueryRules' }
$version = if ($Scenario -eq 'ContainerApp') { '2018-03-01' } else { '2021-08-01' }
$canonicalName = switch ($Scenario) {
    'SQL' { "al-$prefix-sql-lock-timeout" }
    'LOB' { "alert-$prefix-lob-arc-app-fault" }
    'ContainerApp' { "alert-$prefix-containerapp-restarts" }
}
$collectionId = "/subscriptions/$SubscriptionId/resourceGroups/$group/providers/Microsoft.Insights/$collection"
$canonicalId = "$collectionId/$canonicalName"

function Read-Rule([string]$Id, [switch]$AllowAbsent) {
    try {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @(
            'rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$version",'-o','json'
        ) | ConvertFrom-Json -AsHashtable -Depth 100
    } catch {
        if ($AllowAbsent -and $_.Exception.Message -match '\bResourceNotFound\b') { return $null }
        throw
    }
}
function Copy-RuleBody([Collections.IDictionary]$Rule) {
    $body = $Rule | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    foreach ($key in @('id','name','type','systemData','etag')) { $body.Remove($key) }
    foreach ($key in @('createdWithApiVersion','isWorkspaceAlertsStorageConfigured','provisioningState','isLegacyLogAnalyticsRule','lastUpdatedTime')) {
        $body.properties.Remove($key)
    }
    if (-not $body.Contains('tags') -or -not $body.tags) { $body.tags = @{} }
    return $body
}
function Test-Body([object]$Actual, [object]$Expected) {
    (Test-SreProperties $Actual $Expected) -and (Test-SreProperties $Expected $Actual)
}
function Write-Rule([string]$Id, [string]$Method, [object]$Body, [object]$Expected) {
    $arguments = @('rest','--method',$Method,'--url',"https://management.azure.com${Id}?api-version=$version",'-o','json')
    if ($null -ne $Body) { $arguments += @('--body',($Body | ConvertTo-Json -Depth 100 -Compress)) }
    try { Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments $arguments | Out-Null }
    catch {
        if ($_.Exception.Message -match '(?i)AuthorizationFailed|Forbidden|Unauthorized|BadRequest|InvalidRequest|\b(400|401|403)\b') { throw }
        Write-Warning "Write outcome ambiguous; GET-only read-back, never resubmitting $Method. $($_.Exception.Message)"
    }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    do {
        try {
            $actual = Read-Rule $Id -AllowAbsent
            if ($null -eq $Expected -and $null -eq $actual) { return }
            if ($actual -and $actual.id -ieq $Id -and $null -ne $Expected -and (Test-Body (Copy-RuleBody $actual) $Expected)) { return }
        } catch {
            if ($_.Exception.Message -match '(?i)AuthorizationFailed|Forbidden|Unauthorized|BadRequest|InvalidRequest|\b(400|401|403)\b') { throw }
            Write-Warning "Read-back failed; only GET will be retried. $($_.Exception.Message)"
        }
        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($delay,[Math]::Ceiling($remaining)))
        $delay = [Math]::Min(20,$delay * 2)
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Read-back timed out for $Id. Inspect this exact rule before any retry; no write was replayed."
}

$canonical = Read-Rule $canonicalId
if ($canonical.id -ine $canonicalId) { throw 'Canonical rule identity differs.' }
$baseline = Copy-RuleBody $canonical
$inventory = Read-Rule $collectionId
if (-not $inventory.Contains('value') -or $inventory.value -isnot [array] -or
    ($inventory.Contains('nextLink') -and $inventory.nextLink)) { throw 'Incomplete rule inventory; refusing ambiguous route ownership.' }
$copies = @($inventory.value | Where-Object {
    $_.id.StartsWith("$canonicalId-fresh-",[StringComparison]::OrdinalIgnoreCase)
})
if ($Action -eq 'Prepare') {
    if (-not $baseline.properties.enabled -or $copies.Count) { throw 'A route is already prepared or canonical is disabled; inspect/Restore, do not replay Prepare.' }
    if (-not $TemporaryRuleName) { $TemporaryRuleName = "$canonicalName-fresh-$([datetime]::UtcNow.ToString('yyyyMMddHHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,6))" }
} elseif (-not $TemporaryRuleName) {
    if ($copies.Count -gt 1) { throw 'Multiple copies remain; specify the exact TemporaryRuleName to Restore.' }
    if ($copies.Count -eq 1) { $TemporaryRuleName = ($copies[0].id -split '/')[-1] }
}
if ($TemporaryRuleName) {
    Assert-SreName -Value $TemporaryRuleName -Description 'temporary alert rule name'
    if (-not $TemporaryRuleName.StartsWith("$canonicalName-fresh-",[StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary name must retain the canonical name plus -fresh- and a unique suffix.' }
    $temporaryId = "$collectionId/$TemporaryRuleName"
    $temporary = Read-Rule $temporaryId -AllowAbsent
} else { $temporaryId = ''; $temporary = $null }

if ($Action -eq 'Prepare') {
    if ($temporary) { throw 'Temporary rule already exists; never overwrite it.' }
    $copy = Copy-RuleBody $canonical
    $copy.properties.enabled = $false
    $copy.tags['sreDemoRoute'] = $canonicalId
    Write-Host "Temporary rule: $TemporaryRuleName"
    if ($PSCmdlet.ShouldProcess($canonicalId,"Prepare $TemporaryRuleName; disable canonical; no fault or cooldown changes")) {
        Write-Rule $temporaryId 'put' $copy $copy
        if (-not (Test-Body (Copy-RuleBody (Read-Rule $canonicalId)) $baseline)) { throw 'Concurrent canonical change; inspect the disabled clone before proceeding.' }
        $disabled = Copy-RuleBody $canonical
        $disabled.properties.enabled = $false
        Write-Rule $canonicalId 'patch' @{properties=@{enabled=$false}} $disabled
        $copy.properties.enabled = $true
        Write-Rule $temporaryId 'patch' @{properties=@{enabled=$true}} $copy
    }
} else {
    if ($temporary -and (-not $temporary.tags -or -not $temporary.tags.Contains('sreDemoRoute') -or $temporary.tags.sreDemoRoute -ine $canonicalId)) {
        throw 'Temporary rule ownership differs; nothing deleted.'
    }
    if ($PSCmdlet.ShouldProcess($canonicalId,"Delete only $TemporaryRuleName and re-enable canonical; may replay old alerts/email")) {
        if ($temporary) { Write-Rule $temporaryId 'delete' $null $null }
        if (-not $baseline.properties.enabled) {
            $baseline.properties.enabled = $true
            Write-Rule $canonicalId 'patch' @{properties=@{enabled=$true}} $baseline
        }
    }
}
[pscustomobject]@{ action=$Action; scenario=$Scenario; canonicalRuleId=$canonicalId; temporaryRuleName=$TemporaryRuleName; preview=[bool]$WhatIfPreference }
