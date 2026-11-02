#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$routeScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-SreDemoRoute.ps1'
$savedResponder = $global:AzResponder
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Demo route assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Run, [string]$Pattern) {
    try { & $Run | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected route failure: $Pattern"
}
function Reset-Route([string]$Scenario) {
    $global:AzCalls.Clear()
    $name = switch ($Scenario) {
        'SQL' { 'al-arc-demo-sql-lock-timeout' }
        'LOB' { 'alert-arc-demo-lob-arc-app-fault' }
        'ContainerApp' { 'alert-arc-demo-containerapp-restarts' }
    }
    $group = if ($Scenario -eq 'ContainerApp') { 'rg-arc-demo-infra' } else { 'rg-arc-demo' }
    $collection = if ($Scenario -eq 'ContainerApp') { 'metricAlerts' } else { 'scheduledQueryRules' }
    $global:RouteId = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/$group/providers/Microsoft.Insights/$collection/$name"
    $global:RouteRules = @{ $global:RouteId = @{
        id=$global:RouteId; name=$name; type="Microsoft.Insights/$collection"; location='australiaeast';tags=@{original='preserved'}
        properties=@{ enabled=$true; severity=2;description='Original';evaluationFrequency='PT5M';windowSize='PT5M'
            scopes=@('/exact-scope');actions=@{actionGroups=@('/exact-action-group')}
            criteria=@{allOf=@(@{query='Event | where EventID == 6201';threshold=0})} }
    } }
    if ($Scenario -eq 'ContainerApp') {
        $global:RouteRules[$global:RouteId].properties.actions = @(@{actionGroupId='/exact-action-group';webHookProperties=@{original='value'}})
        $global:RouteRules[$global:RouteId].properties.criteria = @{'odata.type'='Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria';allOf=@(@{metricName='RestartCount';threshold=0})}
    } else { $global:RouteRules[$global:RouteId].properties.displayName = 'Matching scenario filter title' }
    $global:RouteMode = ''
}
try {
    $global:AzResponder = {
        $arguments = $args
        $command = $arguments -join ' '
        if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled"}' }
        $method = $arguments[2]
        $id = ([uri]$arguments[4]).AbsolutePath
        if ($method -eq 'get') {
            if ($global:RouteMode -eq 'read-denied') { throw 'Forbidden 403' }
            if ($id -match '/(scheduledQueryRules|metricAlerts)$') { return @{value=@($global:RouteRules.Values)} | ConvertTo-Json -Depth 100 }
            if (-not $global:RouteRules.ContainsKey($id)) { throw 'ResourceNotFound' }
            return $global:RouteRules[$id] | ConvertTo-Json -Depth 100
        }
        if ($global:RouteMode -eq 'write-denied') { throw 'AuthorizationFailed 403' }
        if ($method -eq 'delete') { $global:RouteRules.Remove($id) }
        else {
            $body = $arguments[8] | ConvertFrom-Json -AsHashtable -Depth 100
            if ($method -eq 'put') { $global:RouteRules[$id]=$body; $global:RouteRules[$id].id=$id }
            else { $global:RouteRules[$id].properties.enabled=$body.properties.enabled }
        }
        if ($global:RouteMode -eq 'ambiguous') { throw 'transport timeout after acceptance' }
        '{}'
    }
    foreach ($scenario in @('SQL','LOB','ContainerApp')) {
        Reset-Route $scenario
        $parameters = @{SubscriptionId='00000000-0000-0000-0000-000000000001';TenantId='00000000-0000-0000-0000-000000000002'
            SkinPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'config\demo-skin.json');Scenario=$scenario}
        $preview = & $routeScript @parameters -Action Prepare -WhatIf
        Check ($preview.preview -and $preview.temporaryRuleName.StartsWith(($global:RouteId -split '/')[-1] + '-fresh-')) "$scenario generates a new filter-matching rule name"
        Check (@($global:AzCalls | Where-Object { $_ -match '--method (put|patch|delete)' }).Count -eq 0) 'WhatIf performs only reads'
        $baseline = $global:RouteRules[$global:RouteId].properties | ConvertTo-Json -Depth 100 -Compress
        $prepared = & $routeScript @parameters -Action Prepare
        $copyId = $global:RouteId + '-fresh-' + ($prepared.temporaryRuleName -split '-fresh-')[-1]
        Check (-not $global:RouteRules[$global:RouteId].properties.enabled -and $global:RouteRules[$copyId].properties.enabled) "$scenario switches canonical to fresh copy"
        Check (($global:RouteRules[$copyId].properties | ConvertTo-Json -Depth 100 -Compress) -ceq $baseline) 'Complete criteria/actions/scope/title/severity/window are copied unchanged'
        Check ($global:RouteRules[$copyId].tags.original -eq 'preserved') 'Existing tags survive'
        Check (@($global:AzCalls | Where-Object { $_ -like 'rest --method put*' }).Count -eq 1) 'Exactly one create PUT'
        Throws { & $routeScript @parameters -Action Prepare } 'already prepared'
        $before = @($global:AzCalls | Where-Object { $_ -match '--method (put|patch|delete)' }).Count
        & $routeScript @parameters -Action Restore -WhatIf | Out-Null
        Check (@($global:AzCalls | Where-Object { $_ -match '--method (put|patch|delete)' }).Count -eq $before) 'Restore preview is read-only'
        & $routeScript @parameters -Action Restore | Out-Null
        Check ($global:RouteRules.Count -eq 1 -and $global:RouteRules[$global:RouteId].properties.enabled) "$scenario deletes only copy and restores canonical"
        $before = $global:AzCalls.Count
        & $routeScript @parameters -Action Restore | Out-Null
        Check (@($global:AzCalls | Select-Object -Skip $before | Where-Object { $_ -match '--method (put|patch|delete)' }).Count -eq 0) 'Repeated restore does not replay writes'
        Check (@($global:AzCalls | Where-Object { $_ -match 'get-access-token|account set|/filters|role assignment|/agents' }).Count -eq 0) 'No SRE, cooldown, account-selection, IAM or parent operations'
        if ($scenario -eq 'ContainerApp') {
            Check (@($global:AzCalls | Where-Object { $_ -like 'rest*' -and $_ -notmatch 'api-version=2018-03-01' }).Count -eq 0) 'Metric operations use supported metric API, not log API'
        }
    }
    Reset-Route 'ContainerApp'
    $global:RouteMode = 'ambiguous'
    & $routeScript @parameters -Action Prepare | Out-Null
    Check (@($global:AzCalls | Where-Object { $_ -match '--method (put|patch)' }).Count -eq 3) 'Accepted timeout converges by GET only, without resubmitting any mutation'
    $copy = @($global:RouteRules.Keys | Where-Object { $_ -ne $global:RouteId })[0]
    $global:RouteRules[$copy].tags.sreDemoRoute = '/some-other-canonical'
    Throws { & $routeScript @parameters -Action Restore } 'ownership differs'
    Reset-Route 'ContainerApp'
    $global:RouteMode = 'write-denied'
    Throws { & $routeScript @parameters -Action Prepare } 'AuthorizationFailed'
    Check (@($global:AzCalls | Where-Object { $_ -match '--method (put|patch|delete)' }).Count -eq 1) 'Denied write stops without another write path'
    Reset-Route 'ContainerApp'
    $global:RouteMode = 'read-denied'
    Throws { & $routeScript @parameters -Action Prepare } 'Forbidden'
    Check (@($global:AzCalls | Where-Object { $_ -match '--method (put|patch|delete)' }).Count -eq 0) 'Denied read is not absent state'
    Write-Host "$count demo-route assertions passed; all Azure calls mocked."
} finally {
    $global:AzResponder = $savedResponder
    Remove-Variable -Scope Global -Name RouteId,RouteRules,RouteMode -ErrorAction SilentlyContinue
}
