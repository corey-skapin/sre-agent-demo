#Requires -Version 7.4
<#
.SYNOPSIS
Renders the SRE presenter guide from saved nonsecret context. No Azure calls.
#>
[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot '..\.local\demo-context.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outputDirectory = Join-Path $root '.local'
$outputPath = Join-Path $outputDirectory 'presenter-runsheet.md'
if (-not (Test-Path -LiteralPath $ContextPath -PathType Leaf)) {
    throw 'Missing local demo context. Setup must save approved nonsecret inputs to .local/demo-context.json; see docs/ai-deploy-handbook.md#local-presenter-guide.'
}
$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -AsHashtable
$required = @(
    'schemaVersion', 'subscriptionId', 'tenantId', 'recordedAtUtc', 'resourceGroups',
    'agentName', 'agentUrl', 'applicationUrl', 'applicationInsightsResourceId',
    'logAnalyticsWorkspaceId', 'containerAppResourceId', 'arcMachineResourceId',
    'containerResponsePlan', 'lobResponsePlan', 'lobAlertTitleContains', 'lobEventSource'
)
if ($context -isnot [System.Collections.IDictionary]) { throw 'Context must be a JSON object.' }
foreach ($key in $context.Keys) {
    if ($key -notin ($required + @('companionArcRunsheetPath', 'sql'))) {
        throw "Unsupported context field '$key'. Store only the documented nonsecret presenter fields."
    }
}
foreach ($key in $required) {
    if (-not $context.Contains($key) -or $null -eq $context[$key] -or "$($context[$key])".Trim() -eq '') {
        throw "Missing context field '$key'. Refresh context from approved setup inputs."
    }
    if ($key -notin @('schemaVersion', 'resourceGroups', 'recordedAtUtc') -and $context[$key] -isnot [string]) {
        throw "Invalid $key; expected one string."
    }
}
if ($context.schemaVersion -ne 1) { throw 'Unsupported local context schemaVersion; expected 1.' }
foreach ($key in @('subscriptionId', 'tenantId')) {
    if ($context[$key] -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        throw "Invalid $key; explicit GUID required."
    }
}
$timestamp = [DateTimeOffset]::MinValue
if ($context.recordedAtUtc -is [datetime] -and $context.recordedAtUtc.Kind -eq [DateTimeKind]::Utc) {
    $context.recordedAtUtc = $context.recordedAtUtc.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
}
if (-not [DateTimeOffset]::TryParse($context.recordedAtUtc, [ref]$timestamp) -or $context.recordedAtUtc -notmatch 'Z$') {
    throw 'recordedAtUtc must be an explicit UTC timestamp ending in Z.'
}
if ($context.resourceGroups -isnot [System.Collections.IDictionary] -or
    @($context.resourceGroups.Keys | Where-Object { $_ -notin @('arc', 'infra', 'sre') }).Count) {
    throw 'resourceGroups must contain only arc, infra and sre names.'
}
foreach ($group in @('arc', 'infra', 'sre')) {
    if (-not $context.resourceGroups.Contains($group) -or $context.resourceGroups[$group] -isnot [string] -or
        $context.resourceGroups[$group] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,89}$') {
        throw "Invalid resourceGroups.$group."
    }
}
foreach ($key in @('agentName', 'containerResponsePlan', 'lobResponsePlan', 'lobAlertTitleContains', 'lobEventSource')) {
    if ($context[$key] -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,127}$') { throw "Invalid $key." }
}
$resources = @{
    applicationInsightsResourceId = @('sre', 'Microsoft.Insights/components')
    logAnalyticsWorkspaceId = @('arc', 'Microsoft.OperationalInsights/workspaces')
    containerAppResourceId = @('infra', 'Microsoft.App/containerApps')
    arcMachineResourceId = @('arc', 'Microsoft.HybridCompute/machines')
}
if ($context.Contains('sql')) {
    $sql = $context.sql
    $sqlFields = @('machineResourceId', 'alertResourceId', 'responsePlan', 'alertTitleContains', 'eventSource')
    if ($sql -isnot [Collections.IDictionary] -or @($sql.Keys | Where-Object { $_ -notin $sqlFields }).Count) {
        throw 'sql must contain only the documented nonsecret SQL presenter fields.'
    }
    foreach ($key in $sqlFields) {
        if (-not $sql.Contains($key) -or $sql[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($sql[$key])) {
            throw "Missing or invalid sql.$key."
        }
    }
    if ($sql.responsePlan -notmatch '^[a-z][a-z0-9-]{1,79}$' -or
        $sql.responsePlan -in @($context.containerResponsePlan, $context.lobResponsePlan) -or
        $sql.alertTitleContains -cne 'Arc SQL lock timeout' -or $sql.eventSource -cne 'ArcSqlEngineDemo') {
        throw 'Invalid SQL plan, exact alert title or event source contract.'
    }
    $context['sqlMachineResourceId'] = $sql.machineResourceId
    $context['sqlAlertResourceId'] = $sql.alertResourceId
    $resources.sqlMachineResourceId = @('arc', 'Microsoft.HybridCompute/machines')
    $resources.sqlAlertResourceId = @('arc', 'Microsoft.Insights/scheduledQueryRules')
}
foreach ($key in $resources.Keys) {
    $scope = "/subscriptions/$($context.subscriptionId)/resourceGroups/$($context.resourceGroups[$resources[$key][0]])/providers/$($resources[$key][1])/"
    if ($context[$key] -notmatch ('^' + [regex]::Escape($scope) + '[A-Za-z0-9][A-Za-z0-9._-]*$')) {
        throw "Invalid $key; resource must match the explicit subscription, group and resource type."
    }
}
foreach ($key in @('agentUrl', 'applicationUrl')) {
    $uri = $null
    if (-not [Uri]::TryCreate($context[$key], [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or
        $context[$key] -match '[\s()<>"''`]' -or $context[$key] -match '(?i)(token|secret|password|signature|access_key)=') {
        throw "Invalid $key; use an HTTPS resource URL without credentials, query parameters or Markdown delimiters."
    }
    if ($key -eq 'agentUrl' -and $uri.Host -notin @('portal.azure.com', 'sre.azure.com')) {
        throw 'agentUrl must be the actual Azure portal or SRE portal resource link saved during setup.'
    }
    if ($key -eq 'agentUrl' -and $uri.Host -eq 'portal.azure.com') {
        $agentId = "/subscriptions/$($context.subscriptionId)/resourceGroups/$($context.resourceGroups.sre)/providers/Microsoft.App/agents/$($context.agentName)"
        if ([Uri]::UnescapeDataString($uri.AbsoluteUri).IndexOf($agentId, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'agentUrl targets a different agent or subscription.'
        }
    }
    if ($key -eq 'applicationUrl' -and $uri.Fragment) { throw 'applicationUrl must not have a fragment.' }
}
function Get-RelativeLink([string]$Path) {
    $relative = [IO.Path]::GetRelativePath($outputDirectory, [IO.Path]::GetFullPath($Path))
    if ([IO.Path]::IsPathRooted($relative)) { throw 'Linked guide must be on the same filesystem volume.' }
    return (($relative -split '[\\/]') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
}
$values = @{}
foreach ($key in @('recordedAtUtc', 'subscriptionId', 'tenantId', 'agentName', 'agentUrl', 'applicationUrl', 'containerResponsePlan', 'lobResponsePlan', 'lobAlertTitleContains', 'lobEventSource', 'arcMachineResourceId', 'logAnalyticsWorkspaceId')) {
    $values[$key] = $context[$key]
}
foreach ($key in $resources.Keys) {
    $values[$key + 'Url'] = 'https://portal.azure.com/#resource' + $context[$key]
    $values[$key + 'Name'] = ($context[$key] -split '/')[-1]
}
$values.arcStep = 'The Arc section is separate. If the companion Arc guide is absent, skip that section and continue here only after the Arc owner confirms readiness.'
if ($context.Contains('companionArcRunsheetPath')) {
    $companion = $context.companionArcRunsheetPath
    if ($companion -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($companion)) {
        throw 'companionArcRunsheetPath must be an explicit absolute path, or omitted.'
    }
    if (Test-Path -LiteralPath $companion -PathType Leaf) {
        $values.arcStep = 'Complete [the Arc section](' + (Get-RelativeLink $companion) + ') first, then continue here.'
    }
}
$values.incidentGuideUrl = Get-RelativeLink (Join-Path $root 'docs\t09-native-containerapp-closed-loop.md')
$values.lifecycleGuideUrl = Get-RelativeLink (Join-Path $root 'docs\sre-response-plan-automation.md')
$template = Get-Content -LiteralPath (Join-Path $root 'docs\delivery-runsheet.md') -Raw
$values.sqlPlanRow = ''
if ($context.Contains('sql')) {
    $values.sqlPlanRow = $sql.responsePlan
    $values.sqlPlanSignal = $sql.alertTitleContains
    $values.sqlPlanCheck = 'On, Azure Monitor, Sev2, Review, three-hour cooldown'
    $values.sqlEventSource = $sql.eventSource
    $values.sqlMachineResourceId = $sql.machineResourceId
    $template = [regex]::Replace($template, '(?m)^<!-- SQL:(START|END) -->\r?\n?', '')
} else {
    $template = [regex]::Replace($template, '(?m)^\| \{\{sqlPlanRow\}\}.*\r?\n', '')
    $template = [regex]::Replace($template, '(?s)<!-- SQL:START -->.*?<!-- SQL:END -->',
        'SQL is not configured in this saved guide. Skip the SQL scene until setup has verified its engine, signal and SRE route; do not infer readiness from source defaults.')
}
$rendered = [regex]::Replace($template, '\{\{([A-Za-z]+)\}\}', {
    param($match)
    if (-not $values.ContainsKey($match.Groups[1].Value)) { throw "Unknown template field $($match.Value)." }
    return [string]$values[$match.Groups[1].Value]
})
if ($rendered -match '\{\{|\}\}') { throw 'Unresolved presenter template field.' }
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
[IO.File]::WriteAllText($outputPath, $rendered, [Text.UTF8Encoding]::new($false))
Write-Output $outputPath
