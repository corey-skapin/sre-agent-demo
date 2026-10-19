#Requires -Version 7.4
<#
.SYNOPSIS
Renders versioned, skin-specific desired SRE data-plane configuration.
.DESCRIPTION
Export is local and read-only. Apply fails explicitly because the supported MCP
surface does not expose custom-handler read-back or plan update. A connected
MCP/browser agent must execute the bounded ensure/verify procedure in the docs.
The returned requests are MCP arguments, not an undocumented REST payload.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$SkinPath = '',
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Assert-SreContextIds -SubscriptionId $SubscriptionId -TenantId $TenantId
$skin = Get-DemoSkin -Path $SkinPath
if ($Apply) {
    throw 'SRE_BOOTSTRAP_CAPABILITY_REQUIRED: connect Azure MCP plus an authorized visible browser to sre.azure.com. Supported commands provide handler create/update and plan create/list, but no custom-handler read or plan update. Follow docs\sre-response-plan-automation.md; do not invent REST endpoints, retry plan creation blindly, or claim Ready from the parent deployment.'
}
$prefix = $skin.azure.namePrefix
$common = [ordered]@{
    subscription = $SubscriptionId
    tenant = $TenantId
    'resource-group' = "rg-$prefix-sre"
    agent = $skin.labels.agentName
}
$tokens = @{
    arcGroup = "rg-$prefix"; infraGroup = "rg-$prefix-infra"; containerApp = "ca-$prefix-fault"
    arcMachine = $skin.sre.targetArcMachine; eventSource = $skin.labels.lobEventSource
    repositoryUrl = $skin.codeContext.lobRepositoryUrl; sourceCommit = $skin.codeContext.lobSourceCommit
    sourcePath = $skin.codeContext.lobSourcePath
}
$instructions = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\sre-handler.instructions.txt') -Raw
foreach ($key in $tokens.Keys) { $instructions = $instructions.Replace("{$key}", $tokens[$key]) }
$handler = Merge-DemoHashtable -Defaults $common -Overrides @{
    name = $skin.labels.agentName
    description = "$($skin.labels.demoTitle) Review-mode demo handler."
    instructions = $instructions
}
$scenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
$plans = @()
if ('T09' -in $scenarios) {
    $plans += [ordered]@{
        scenario = 'T09'
        command = 'sreagent_incidents_plans_create'
        parameters = (Merge-DemoHashtable -Defaults $common -Overrides @{
            name = $skin.labels.containerResponsePlan; severity = 'high'; 'agent-mode' = 'review'
            'trigger-condition' = 'containerapp-restarts'
            services = @('Azure Container Apps', "ca-$prefix-fault", "rg-$prefix-infra")
            steps = @('Inspect revision health, RestartCount and SIMULATE_CRASH.', 'Propose resetting SIMULATE_CRASH=false and wait for Review approval.', 'Verify healthy revision, endpoint and alert recovery.')
        })
    }
}
if ('T11' -in $scenarios) {
    $plans += [ordered]@{
        scenario = 'T11'
        command = 'sreagent_incidents_plans_create'
        parameters = (Merge-DemoHashtable -Defaults $common -Overrides @{
            name = (Get-DemoSkinValue -Skin $skin -Path 'labels.lobResponsePlan' -Default 'lob-arc-app-review-v2')
            severity = 'high'; 'agent-mode' = 'review'
            'trigger-condition' = $skin.labels.lobAlertTitleContains
            services = @('Azure Arc', $skin.sre.targetArcMachine, $skin.labels.lobEventSource)
            steps = @('Inspect Event ID 4100, Log Analytics evidence and Arc connection state.', 'Explain evidence and any RCA limitation; do not promise reliable T11 RCA.', 'Guide operator Arc Run Command recovery; never perform autonomous Arc repair.')
        })
    }
}
[ordered]@{
    schemaVersion = 1
    kind = 'SreDesiredConfiguration'
    requiredScenarios = $scenarios
    handler = @{ command = 'sreagent_agents_create'; parameters = $handler }
    plans = $plans
    verification = @{ command = 'sreagent_incidents_plans_list'; parameters = $common }
    capabilityRequirement = 'Connected Azure MCP and authorized visible browser for custom-handler read-back, plan update, filter/status/Review verification and conflict detection.'
} | ConvertTo-Json -Depth 30
