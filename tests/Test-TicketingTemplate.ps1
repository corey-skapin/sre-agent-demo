#Requires -Version 7.4
# Checks the compiled T12 workload template (az bicep build --file infra\ticketing\main.bicep --outfile <path>) against the scripts that deploy and inspect it.
# Optionally also checks the compiled quota probe. No Azure sign-in or deployment.
param([Parameter(Mandatory)][string]$TemplatePath, [string]$ProbeTemplatePath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRelease.psm1') -Force
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Ticketing template assertion failed: $Message" }
    $script:count++
}
function Resolve-Format([string]$Expression, [hashtable]$Values) {
    if ($Expression -notmatch "^\[format\('(?<format>[^']*)'(?<arguments>.*)\)\]$") { throw "Not a format() expression: $Expression" }
    $format = $Matches.format
    $arguments = @([regex]::Matches($Matches.arguments, "parameters\('([^']+)'\)") | ForEach-Object { $Values[$_.Groups[1].Value] })
    return [string]::Format($format, $arguments)
}

$subscription = '00000000-0000-0000-0000-000000000001'
$skinPath = Join-Path ([IO.Path]::GetTempPath()) "ticketing-template-skin-$([guid]::NewGuid()).json"
try {
    $skinData = Get-Content -LiteralPath (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
    $skinData.sre.requiredScenarios = @('T12')
    $skinData.release = @{ location = 'australiasoutheast'; appRepository = 'example-owner/ticketing-app'; goodVersion = 'v1.2.0'; badVersion = 'v1.3.0' }
    [IO.File]::WriteAllText($skinPath, ($skinData | ConvertTo-Json -Depth 20))
    $skin = Get-DemoSkin -Path $skinPath -RepoRoot $root
} finally { Remove-Item -LiteralPath $skinPath -Force -ErrorAction SilentlyContinue }
$settings = Get-SreReleaseSettings -Skin $skin -SubscriptionId $subscription
$template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100

# The deploy script's parameter file and the template agree.
$body = Get-SreReleaseDeploymentParameters -Skin $skin -Settings $settings -Version $settings.goodVersion -SiteWriterAssignmentName '' -Tags @{ owner = 'demo' }
$supplied = @($body.parameters.Keys)
$declared = @($template.parameters.Keys)
Check (@($supplied | Where-Object { $_ -notin $declared }).Count -eq 0) "Every parameter the deploy script supplies is declared by the template: $(@($supplied | Where-Object { $_ -notin $declared }) -join ', ')"
$required = @($declared | Where-Object { -not $template.parameters[$_].ContainsKey('defaultValue') })
Check (@($required | Where-Object { $_ -notin $supplied }).Count -eq 0) "Every parameter without a default is supplied: $(@($required | Where-Object { $_ -notin $supplied }) -join ', ')"

# Two groups, the shared identity module, one workload module.
$groups = @($template.resources | Where-Object type -EQ 'Microsoft.Resources/resourceGroups')
Check ($groups.Count -eq 2) 'The template declares only the SRE group and the workload group'
$identityModule = @($template.resources | Where-Object name -EQ 'sre-agent-identity')
Check ($identityModule.Count -eq 1 -and $identityModule[0].properties.mode -eq 'Incremental') 'The identity module has the same name as infra/main.bicep, so the SRE layer finds and keeps it'
$workloadModule = @($template.resources | Where-Object name -EQ 'ticketing-workload')[0]
$resources = @($workloadModule.properties.template.resources)
$variables = $workloadModule.properties.template.variables
$workloadGroup = @($groups | Where-Object { $_.name -like "*workloadResourceGroupName*" })[0]
Check ([string]$workloadGroup.tags -match "'sreScenario', 'T12'") 'The workload group is tagged sreScenario=T12 so Remove-TicketingWorkload.ps1 can prove ownership'

# Names match what the scripts derive from the skin.
$values = @{ namePrefix = $skin.azure.namePrefix; siteSuffix = $settings.siteSuffix }
Check ((Resolve-Format $variables.planName $values) -ceq $settings.planName) 'Plan name matches Get-SreReleaseSettings'
Check ((Resolve-Format $variables.workspaceName $values) -ceq $settings.workspaceName) 'Workspace name matches'
Check ((Resolve-Format $variables.appInsightsName $values) -ceq $settings.appInsightsName) 'Application Insights name matches'
Check ((Resolve-Format $variables.actionGroupName $values) -ceq $settings.actionGroupName) 'Action group name matches'
Check ((Resolve-Format $variables.alertName $values) -ceq $settings.alertName) 'Alert rule name matches'
Check ((Resolve-Format $variables.siteName $values) -ceq $settings.appName) 'Web app name matches, so the site ID and the grant scope are computable offline'
Check ($settings.alertName.Contains($settings.alertTitle) -and $settings.spareAlertName.Contains($settings.alertTitle)) 'Both rule names contain the response-plan keyword'

# The web app runs from a package and is locked down.
$site = @($resources | Where-Object type -EQ 'Microsoft.Web/sites')[0]
$appSettings = @{}
foreach ($setting in @($site.properties.siteConfig.appSettings)) { $appSettings[$setting.name] = $setting.value }
Check ($appSettings['WEBSITE_RUN_FROM_PACKAGE'] -eq "[parameters('packageUrl')]") 'The app is created already running from the package URL (an app cannot switch from a local zip to a URL later)'
Check ($appSettings['SCM_DO_BUILD_DURING_DEPLOYMENT'] -eq 'false' -and $appSettings['ENABLE_ORYX_BUILD'] -eq 'false') 'No build runs on the small plan'
Check ($appSettings.ContainsKey('APPLICATIONINSIGHTS_CONNECTION_STRING') -and $appSettings['NODE_OPTIONS'] -eq '--enable-source-maps') 'Telemetry is wired and stack frames are source-mapped'
Check ($site.properties.httpsOnly -eq $true -and $site.properties.siteConfig.healthCheckPath -eq '/healthz' -and $site.properties.siteConfig.ftpsState -eq 'Disabled') 'HTTPS only, health check and FTP off'
Check ([string]$site.tags -match "'sreScenario', 'T12'") 'The web app is tagged sreScenario=T12'
$policies = @($resources | Where-Object type -EQ 'Microsoft.Web/sites/basicPublishingCredentialsPolicies')
Check ($policies.Count -eq 2 -and @($policies | Where-Object { $_.properties.allow }).Count -eq 0) 'FTP and SCM basic authentication are disabled'
$plan = @($resources | Where-Object type -EQ 'Microsoft.Web/serverfarms')[0]
Check ($plan.sku.tier -eq 'Basic' -and $plan.properties.reserved -eq $true -and $plan.kind -eq 'linux') 'A Linux Basic plan'

# Two alert rules, one on.
$rules = @($resources | Where-Object type -EQ 'Microsoft.Insights/scheduledQueryRules')
Check ($rules.Count -eq 2) 'Two alert rules'
Check ($rules[0].properties.enabled -eq $true -and $rules[1].properties.enabled -eq $false) 'The first rule is on and the spare is off'
Check ($rules[1].name -eq "[format('{0}-b', variables('alertName'))]") 'The spare is named after the first rule plus -b'
foreach ($rule in $rules) {
    Check ($rule.properties.severity -eq 2 -and $rule.properties.evaluationFrequency -eq 'PT1M' -and $rule.properties.windowSize -eq 'PT5M' -and $rule.properties.autoMitigate -eq $true) 'Sev2, every minute over five minutes, auto-resolve'
    Check ($rule.properties.scopes[0] -like "*workspaces*" -and $rule.properties.criteria.allOf[0].operator -eq 'GreaterThan' -and $rule.properties.criteria.allOf[0].threshold -eq 0) 'Scoped to the workspace, fires on any failure'
}
Check ($variables.checkoutFailureQuery -match 'AppRequests' -and $variables.checkoutFailureQuery -match 'POST /checkout' -and $variables.checkoutFailureQuery -match 'Success == false') 'The query watches failed checkouts in AppRequests'

# The one grant.
$assignments = @($resources | Where-Object type -EQ 'Microsoft.Authorization/roleAssignments')
Check ($assignments.Count -eq 1) 'The workload gives the agent identity exactly one role assignment'
Check ($variables.websiteContributorRoleId -eq 'de139f84-1756-47ae-9be6-808fbbe84772' -and $assignments[0].properties.roleDefinitionId -match 'websiteContributorRoleId') 'It is Website Contributor'
Check ($assignments[0].scope -match "Microsoft\.Web/sites" -and $assignments[0].properties.principalType -eq 'ServicePrincipal') 'It is scoped to the web app, not the group'
$known = @(Get-SreReleaseKnownGrants -Settings $settings)
Check ($known.Count -eq 1 -and $known[0].scope -ceq $settings.appId -and $known[0].roleId -ceq $variables.websiteContributorRoleId) 'The known-grants list matches the template exactly'
$text = $template | ConvertTo-Json -Depth 100
$guids = @([regex]::Matches($text, '(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
Check ($guids.Count -eq 1 -and $guids[0] -ceq 'de139f84-1756-47ae-9be6-808fbbe84772') 'The only role the template knows is Website Contributor: no Reader, Contributor, Owner or subscription Monitoring Contributor grant is created'

if ($ProbeTemplatePath) {
    $probe = Get-Content -LiteralPath $ProbeTemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Check (@($probe.resources).Count -eq 1 -and $probe.resources[0].type -eq 'Microsoft.Web/serverfarms') 'The quota probe is one App Service plan and nothing else'
    Check ($probe.parameters.ContainsKey('location') -and $probe.parameters.ContainsKey('skuName') -and $probe.resources[0].kind -eq 'linux') 'The probe takes a location and a SKU'
}
Write-Host "$count compiled ticketing-template assertions passed; no Azure sign-in or deployment."
