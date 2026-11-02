#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\SreReadiness.psm1') -Force
$module = Get-Module SreReadiness
& $module {
    function Check([bool]$Value, [string]$Message) {
        if (-not $Value) { throw "SQL readiness assertion failed: $Message" }
        $script:SqlReadinessAssertions++
    }
    $script:SqlReadinessAssertions = 0
    $base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-demo'
    $target = @{
        AlertId = "$base/providers/Microsoft.Insights/scheduledQueryRules/al-demo-sql-lock-timeout"
        MachineResourceId = "$base/providers/Microsoft.HybridCompute/machines/win-sql-demo"
        WorkspaceId = "$base/providers/Microsoft.OperationalInsights/workspaces/law-demo"
        ActionGroupId = "$base/providers/Microsoft.Insights/actionGroups/ag-demo"
        DisplayName = 'Arc SQL lock timeout - demo'
    }
    $query = Get-SreSqlAlertQuery -MachineResourceId $target.MachineResourceId
    Check ($query.Contains("tolower(_ResourceId) == '$($target.MachineResourceId.ToLowerInvariant())'") -and
        $query.Contains("Source == 'ArcSqlEngineDemo' and EventID == 6201") -and
        $query.Contains('toint(Incident.sqlErrorNumber) == 1222') -and
        $query.Contains("tostring(Incident.state) == 'detected'")) 'Canonical query pins actual host/source/timeout/state JSON contract'
    $fixture = @{
        id = $target.AlertId
        tags = @{ managedBy = 'arc-demo-sql-incident'; workload = 'sql-lock-timeout' }
        properties = @{
            displayName = $target.DisplayName; enabled = $true; severity = 2
            scopes = @($target.WorkspaceId); evaluationFrequency = 'PT1M'; windowSize = 'PT15M'; autoMitigate = $true
            actions = @{ actionGroups = @($target.ActionGroupId) }
            criteria = @{ allOf = @(@{
                query = $query; timeAggregation = 'Count'; operator = 'GreaterThan'; threshold = 0
                failingPeriods = @{ numberOfEvaluationPeriods = 1; minFailingPeriodsToAlert = 1 }
            }) }
        }
    }
    Check (Test-SreSqlAlertDefinition -Alert $fixture @target) 'Exact optional Arc alert contract passes without querying Azure'
    Check (-not (Test-SreSqlAlertDefinition -Alert $null @target)) 'Missing alert is not a successful definition'
    $changed = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $changed.properties.criteria.allOf[0].query = $query.Replace("`n", "`r`n    ")
    Check (Test-SreSqlAlertDefinition -Alert $changed @target) 'Only whitespace differences accepted in canonical SQL query'
    foreach ($case in @('host', 'source', 'error', 'state', 'schema', 'window-query', 'rule-id', 'owner', 'enabled', 'severity', 'title', 'frequency', 'window', 'mitigate', 'scope', 'action', 'extra-scope', 'extra-action', 'count', 'threshold', 'period', 'extra-condition', 'missing-criteria')) {
        $changed = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $p = $changed.properties
        $c = $p.criteria.allOf[0]
        switch ($case) {
            'host' { $c.query = $query.Replace('win-sql-demo', 'other-host') }
            'source' { $c.query = $query.Replace('ArcSqlEngineDemo', 'OtherSource') }
            'error' { $c.query = $query.Replace('1222', '1205') }
            'state' { $c.query = $query.Replace("'detected'", "'recovered'") }
            'schema' { $c.query = $query.Replace('schemaVersion) == 1', 'schemaVersion) == 2') }
            'window-query' { $c.query = $query.Replace('ago(15m)', 'ago(1d)') }
            'rule-id' { $changed.id += '-other' }
            'owner' { $changed.tags.managedBy = 'unowned' }
            'enabled' { $p.enabled = $false }
            'severity' { $p.severity = 3 }
            'title' { $p.displayName = 'Unrelated SQL title' }
            'frequency' { $p.evaluationFrequency = 'PT5M' }
            'window' { $p.windowSize = 'PT30M' }
            'mitigate' { $p.autoMitigate = $false }
            'scope' { $p.scopes = @('/other/workspace') }
            'action' { $p.actions.actionGroups = @('/other/actionGroup') }
            'extra-scope' { $p.scopes += '/other/workspace' }
            'extra-action' { $p.actions.actionGroups += '/other/actionGroup' }
            'count' { $c.timeAggregation = 'Average' }
            'threshold' { $c.threshold = 5 }
            'period' { $c.failingPeriods.minFailingPeriodsToAlert = 2 }
            'extra-condition' { $p.criteria.allOf += $c.Clone() }
            'missing-criteria' { $p.Remove('criteria') }
        }
        Check (-not (Test-SreSqlAlertDefinition -Alert $changed @target)) "$case drift fails closed"
    }
    Write-Host "$script:SqlReadinessAssertions SQL alert-definition assertions passed; no cloud requests."
    Remove-Item Function:\Check
    Remove-Variable SqlReadinessAssertions -Scope Script
}
