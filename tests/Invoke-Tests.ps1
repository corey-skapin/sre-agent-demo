#Requires -Version 7.4
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$previousAz = Get-Item Function:\az -ErrorAction SilentlyContinue
try {
$global:AzCalls = [Collections.Generic.List[string]]::new()
$global:AzExitCode = 0
$global:AzResponder = { 'false' }
function global:az {
    $global:AzCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = $global:AzExitCode
    & $global:AzResponder @args
}
$count = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Assertion failed: $Message" }
    $script:count++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$parseErrors = @()
Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.psm1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $parseErrors += $errors
}
Assert-True ($parseErrors.Count -eq 0) "All PowerShell files parse: $($parseErrors -join '; ')"
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRuntime.psm1') -Force
$cliFixture = Join-Path ([IO.Path]::GetTempPath()) ("sre-cli-test-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $cliFixture 'wbin') | Out-Null
    $pythonFixture = Join-Path $cliFixture 'python.exe'
    [IO.File]::WriteAllText($pythonFixture, '')
    $shim = [pscustomobject]@{ CommandType = 'Application'; Source = (Join-Path $cliFixture 'wbin\az.cmd') }
    $invocation = Get-SreAzInvocation -Command $shim
    Assert-True ($invocation.command -eq $pythonFixture) 'Windows MSI uses its own native Python, never cmd.exe'
    Assert-True (($invocation.prefix -join ' ') -eq '-IBm azure.cli' -and $invocation.installer -eq 'MSI') 'Windows invocation preserves the official launcher module/isolation/install mode'
    $invocation = Get-SreAzInvocation -Command ([pscustomobject]@{ CommandType = 'Function'; Source = '' })
    Assert-True ($invocation.command -eq 'az' -and $invocation.prefix.Count -eq 0) 'Mocks/functions and non-Windows launchers retain ordinary invocation'
    Remove-Item -LiteralPath $pythonFixture -Force
    Assert-Throws { Get-SreAzInvocation -Command $shim } 'bundled python.exe'
} finally {
    Remove-Item -LiteralPath (Join-Path $cliFixture 'wbin'), $cliFixture -Force
}
$extensionWarning = "C:\fixture\ext\_create.py:21: SyntaxWarning: `"\s`" is an invalid escape sequence. Such sequences will not work in the future. Did you mean `"\\s`"? A raw string is also an option.`n  az monitor data-collection rule create --rule-file `"C:\samples\dcrEx1.json`"`n"
Assert-True ((Get-SreAzWarningText -Text ($extensionWarning * 2)).Trim() -eq '') 'Known benign Azure CLI extension SyntaxWarnings are dropped'
Assert-True ((Get-SreAzWarningText -Text "ERROR: real problem`n$extensionWarning").Trim() -eq 'ERROR: real problem') 'A real error beside the extension warning is preserved'
Assert-True ((Get-SreAzWarningText -Text "WARNING: keep this`r`n") -eq "WARNING: keep this`r`n" -and (Get-SreAzWarningText -Text $null) -eq '') 'Unrelated stderr text and empty input are untouched'
$skin = Get-DemoSkin -RepoRoot $root
& (Join-Path $PSScriptRoot 'Test-RepoDefaults.ps1')
& (Join-Path $PSScriptRoot 'Test-PresenterRunsheet.ps1')
& (Join-Path $PSScriptRoot 'Test-LobWarning.ps1')
Assert-True ($skin.sre.requiredScenarios[0] -is [string]) 'JSON array strings remain strings, not PSCustomObject Length properties'
foreach ($file in @('demo-skin.json', 'dummy-customer.demo-skin.json')) {
    $config = Get-DemoSkin -Path (Join-Path $root "config\$file") -RepoRoot $root
    Assert-True ($config.schemaVersion -eq 1) "$file validates"
}
Assert-Throws { Get-DemoSkin -Path 'missing-skin.json' -RepoRoot $root } 'not found'
$temp = [IO.Path]::GetTempFileName()
try {
    $badSkin = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw
    [IO.File]::WriteAllText($temp, $badSkin.Replace('"High"', '"Autonomous"'))
    Assert-Throws { Get-DemoSkin -Path $temp -RepoRoot $root } 'schema|valid|enum'
    [IO.File]::WriteAllText($temp, $badSkin.Replace('"arc-demo"', '"bad prefix"'))
    Assert-Throws { Get-DemoSkin -Path $temp -RepoRoot $root } 'schema|valid|pattern'
} finally { Remove-Item -LiteralPath $temp -Force }
Assert-Throws { Assert-SreContextIds 'not-a-guid' $tenant } 'Explicit GUID'
Assert-Throws { Assert-SreArmId "/subscriptions/$tenant/resourceGroups/elsewhere" $subscription 'test' } 'explicit subscription'
Assert-Throws { Assert-SreName 'machine"; throw "injection' 'machine' } 'Invalid'
$global:AzResponder = {
    if ($args[0] -eq 'account') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
    if ($args[0] -eq 'role') { return '[]' }
    if ($args[0] -eq 'rest') { return '{"value":[]}' }
    'false'
}
Assert-SreContext $subscription $tenant | Out-Null
Assert-True ($global:AzCalls[-1] -match "--subscription $subscription") 'Every Azure request has explicit subscription'
$queryUrl = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&" + '$filter=principalId%20eq%20%27' + $tenant + '%27'
Invoke-SreAz -SubscriptionId $subscription -Arguments @('rest', '--method', 'get', '--url', $queryUrl, '-o', 'json') | Out-Null
Assert-True ($global:AzCalls[-1].Contains($queryUrl)) 'Exact principal-filter URL reaches CLI unchanged, including ampersand and encoding'
Assert-Throws { Assert-SreContext $subscription $subscription } 'does not match'
$global:AzExitCode = 7
Assert-Throws { Invoke-SreAz -Arguments @('group', 'exists') -SubscriptionId $subscription } 'failed \(7\)'
$global:AzExitCode = 0
foreach ($result in @(
    '{"provisioningState":"Succeeded","instanceView":{"executionState":"Succeeded","exitCode":4}}',
    '{"provisioningState":"Creating"}',
    '{"provisioningState":"Succeeded"}',
    'not-json'
)) { Assert-Throws { Assert-SreRunCommandResult $result } 'failed|pending|unverified|provisioningState|JSON' }
$success = Assert-SreRunCommandResult '{"provisioningState":"Succeeded","instanceView":{"executionState":"Succeeded","exitCode":0}}'
Assert-True ($success.instanceView.exitCode -eq 0) 'Guest success requires both completion state and exit code'
$initialize = Join-Path $root 'scripts\Initialize-SreConfiguration.ps1'
$desired = & $initialize -SubscriptionId $subscription -TenantId $tenant | ConvertFrom-Json
Assert-True ($desired.plans.Count -eq 2) 'Default skin renders T09 and T11'
Assert-True ($desired.plans[0].properties.titleContains -eq 'containerapp-restarts') 'Filter is one keyword, not invented OR syntax'
Assert-True (@($desired.plans | Where-Object { $_.properties.agentMode -ne 'Review' }).Count -eq 0) 'Every plan explicitly uses Review'
Assert-True ($desired.handler.properties.instructions -match 'Windows application and SQL investigations are\s+read-only: no remediation') 'Handler preserves the hybrid read-only boundary'
Assert-True ($desired.handler.properties.instructions -match '4200 dependency warning' -and $desired.handler.properties.instructions -match 'Processor Information\(_Total\)' -and $desired.handler.properties.instructions -match 'Memory/Available MBytes') 'Rendered handler correlates actual warning and configured host counters'
Assert-True ($desired.handler.properties.instructions -match 'not process measurements' -and $desired.handler.properties.instructions -match 'no remediation, SQL execution, session termination, guest commands') 'Handler preserves contextual host metrics and Arc recovery that you run'
Assert-True ($desired.handler.properties.instructions -match 'No external source repository is configured') 'Default handler explicitly omits external repository context'
$sourceSkinPath = [IO.Path]::GetTempFileName()
$sourceGuestPath = [IO.Path]::GetTempFileName()
try {
    $configured = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
    $configured.codeContext.lobRepositoryUrl = 'https://example.invalid/lob-source'
    $configured.codeContext.lobSourceCommit = 'example-revision'
    $configured | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $sourceSkinPath
    $withSource = & $initialize -SubscriptionId $subscription -TenantId $tenant -SkinPath $sourceSkinPath | ConvertFrom-Json
    Assert-True ($withSource.handler.properties.instructions.Contains('https://example.invalid/lob-source at example-revision')) 'Explicit private-style skin still renders configured repository/revision'
    Assert-True ($withSource.handler.properties.instructions -notmatch 'No external source repository') 'Configured source is not silently omitted'
    $configured.codeContext.lobSourceCommit = ''
    $configured | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $sourceSkinPath
    Assert-Throws { Get-DemoSkin -Path $sourceSkinPath } 'schema|valid|minLength'
    $configured.codeContext.lobRepositoryUrl = ''
    $configured.codeContext.lobSourceCommit = 'example-revision'
    $configured | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $sourceSkinPath
    Assert-Throws { Get-DemoSkin -Path $sourceSkinPath } 'schema|valid|const'
    $callsBefore = $global:AzCalls.Count
    & (Join-Path $root 'scripts\Invoke-LobArcAppOnArc.ps1') -SubscriptionId $subscription -TenantId $tenant -Action Deploy -GuestScriptOutputPath $sourceGuestPath | Out-Null
    $guest = Get-Content -LiteralPath $sourceGuestPath -Raw
    $encoded = [regex]::Match($guest, '(?m)^\$ConfigBase64 = ''(?<value>[A-Za-z0-9+/=]+)''').Groups['value'].Value
    Assert-True ($encoded.Length -gt 0) 'Generated guest script carries explicit app configuration'
    $guestConfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    Assert-True ($guestConfig.SourceRepositoryUrl -eq '' -and $guestConfig.SourceCommit -eq '') 'Default guest config has no invented external repository or revision'
    Assert-True ($global:AzCalls.Count -eq $callsBefore) 'Local guest generation does not contact Azure'
    Assert-Throws { & (Join-Path $root 'scripts\Invoke-LobArcAppOnArc.ps1') -SubscriptionId $subscription -TenantId $tenant -SourceRepositoryUrl 'https://example.invalid/lob-source' -GuestScriptOutputPath $sourceGuestPath } 'together'
    $tokens = $null; $errors = $null
    $sampleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'samples\lob-arc-app\LobArcBridgeApp.ps1'), [ref]$tokens, [ref]$errors)
    $contextFunction = $sampleAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RepositoryContext' }, $true)
    . ([scriptblock]::Create($contextFunction.Extent.Text))
    $contextText = Get-RepositoryContext -Config $guestConfig
    Assert-True ($contextText -match 'repo=<not configured> commit=<not configured>') 'Runtime event context explicitly labels omitted external source'
} finally {
    Remove-Item -LiteralPath $sourceSkinPath, $sourceGuestPath -Force
}
Assert-Throws { & $initialize -SubscriptionId $subscription -TenantId $tenant -Apply } 'BackupPath'
Assert-True (-not (Get-Command $initialize).Parameters.ContainsKey('AllowLegacyMigration')) 'Initializer has no legacy-instance migration switch'
Assert-True (-not (Get-Command (Join-Path $root 'scripts\Deploy-SreAgent.ps1')).Parameters.ContainsKey('AllowLegacyMigration')) 'Deployment has no legacy-instance migration switch'
$second = & $initialize -SubscriptionId $subscription -TenantId $tenant
Assert-True (($desired | ConvertTo-Json -Depth 30 -Compress) -eq (($second | ConvertFrom-Json) | ConvertTo-Json -Depth 30 -Compress)) 'Repeated desired-state rendering is deterministic'
& (Join-Path $PSScriptRoot 'Test-SreConfiguration.ps1')
& (Join-Path $PSScriptRoot 'Test-SreSqlConfiguration.ps1')
& (Join-Path $PSScriptRoot 'Test-SreSqlReadiness.ps1')

Import-Module (Join-Path $root 'scripts\lib\SreReadiness.psm1') -Force
$hibernated = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
Assert-True ($hibernated.status -eq 'fail') 'Absent identity does not certify normal retained-identity Hibernated'
$hibernatedKnown = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId '00000000-0000-0000-0000-000000000003'
Assert-True ($hibernatedKnown.status -eq 'fail') 'Legacy whole-group deletion is not normal identity-retained Hibernated'
$ready = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant
Assert-True ($ready.status -eq 'fail') 'Absent parent never becomes Ready'
Assert-True ($ready.checks[0].id -eq 'parent') 'Machine-readable readiness identifies missing parent'
$active = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Active
Assert-True ($active.desiredState -eq 'Active' -and $active.status -eq $ready.status -and $active.checks[0].id -eq 'parent') 'Active and compatible Ready alias use the same readiness path'
$readinessModule = Get-Module SreReadiness
try {
    & $readinessModule {
        param($Desired, $Skin)
        $script:ReadinessDesired = $Desired
        $script:ReadinessSkin = $Skin
        $script:ReadinessFailure = ''
        $script:ReadinessBase = "/subscriptions/$($Desired.subscriptionId)/resourceGroups"
        $script:ReadinessAgentId = "$script:ReadinessBase/rg-arc-demo-sre/providers/Microsoft.App/agents/sre-arc-demo"
        $script:ReadinessIdentityId = "$script:ReadinessBase/rg-arc-demo-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami"
        function script:Assert-SreContext {}
        function script:New-SreConfigurationSession { @{ token = 'unit-test' } }
        function script:Get-SreConfigurationSnapshot {
            if ($script:ReadinessFailure -eq 'denied') { throw 'Synthetic Forbidden data-plane read' }
            $filters = $script:ReadinessDesired.plans | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            if ($script:ReadinessFailure -eq 'sql-filter') { $filters = @($filters | Where-Object scenario -ne 'SQL') }
            if ($script:ReadinessFailure -eq 'sql-cooldown') { ($filters | Where-Object scenario -eq 'SQL').properties.mergeWindowHours = 1 }
            @{
                subagents = @($script:ReadinessDesired.handler)
                filters = @($filters)
                handlers = @()
            }
        }
        function script:Get-SreArmRoleAssignments {
            foreach ($rg in @('rg-arc-demo', 'rg-arc-demo-infra')) {
                foreach ($role in @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c')) {
                    @{ principalId = '00000000-0000-0000-0000-000000000003'; scope = "$script:ReadinessBase/$rg"; roleDefinitionId = "/roles/$role" }
                }
            }
            if ($script:ReadinessFailure -ne 'platform-missing') {
            $grant = @{ id='/unit-test/platform-role'; principalId='00000000-0000-0000-0000-000000000003'; scope="/subscriptions/$($script:ReadinessDesired.subscriptionId)"; roleDefinitionId='/roles/749f88d5-cbae-40b8-bcfc-e573ddc772fa' }
            switch ($script:ReadinessFailure) {
                'platform-role' { $grant.roleDefinitionId='/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' }
                'platform-principal' { $grant.principalId='00000000-0000-0000-0000-000000000004' }
                'platform-scope' { $grant.scope='/subscriptions/00000000-0000-0000-0000-000000000004' }
                'platform-duplicate' { $grant.Clone() }
            }
            $grant
            }
        }
        function script:Invoke-SreAz {
            param($SubscriptionId, $Arguments)
            $command = $Arguments -join ' '
            $base = $script:ReadinessBase
            $appId = "$base/rg-arc-demo-infra/providers/Microsoft.App/containerApps/ca-arc-demo-fault"
            $failedReads = @{
                'missing-app' = 'containerapp show*'
                'missing-container-alert' = 'monitor metrics alert show*'
                'missing-arc' = 'connectedmachine show*'
                'missing-lob-alert' = 'resource show*scheduledQueryRules/alert-*-lob-arc-app-fault*'
                'denied-lob-alert' = 'resource show*scheduledQueryRules/alert-*-lob-arc-app-fault*'
                'missing-sql-alert' = 'resource show*scheduledQueryRules/al-*-sql-lock-timeout*'
            }
            if ($failedReads.ContainsKey($script:ReadinessFailure) -and $command -like $failedReads[$script:ReadinessFailure]) {
                throw "Azure CLI failed (3): synthetic resource inspection $($script:ReadinessFailure)"
            }
            $value = switch -Wildcard ($command) {
                'group exists*' { $true; break }
                'resource list*' { @(@{ id = $script:ReadinessIdentityId }, @{ id = $script:ReadinessAgentId }); break }
                'identity show*' { @{ principalId = '00000000-0000-0000-0000-000000000003' }; break }
                'resource show*Microsoft.App/agents/*' {
                    $managedResources = @("$base/rg-arc-demo", "$base/rg-arc-demo-infra", "$base/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo", "$base/rg-arc-demo/providers/Microsoft.Insights/actionGroups/ag-arc-demo", $appId, "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/win-app-01")
                    if ($script:ReadinessFailure -eq 'sql-scope') {
                        $managedResources = @($managedResources | Where-Object { $_ -ne "$base/rg-arc-demo" })
                        $managedResources += "$base/foreign-group"
                    }
                    if ('SQL' -in $script:ReadinessSkin.sre.requiredScenarios -and $script:ReadinessFailure -notin @('sql-scope', 'sql-group-covered')) {
                        $managedResources += "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/$($script:ReadinessSkin.sre.sqlTargetArcMachine)"
                    }
                    @{
                        id = $script:ReadinessAgentId
                        identity = @{ type = 'SystemAssigned,UserAssigned'; userAssignedIdentities = @{ $script:ReadinessIdentityId = @{} } }
                        properties = @{
                            provisioningState = $(if ($script:ReadinessFailure -eq 'parent') { 'Failed' } else { 'Succeeded' })
                            runningState = 'Running'
                            actionConfiguration = @{ mode = 'Review'; accessLevel = 'High'; identity = $script:ReadinessIdentityId }
                            incidentManagementConfiguration = $(if ($script:ReadinessFailure -eq 'platform-unset') { @{} } else { @{ type = $(if ($script:ReadinessFailure -eq 'platform-disconnected') { 'None' } else { 'AzMonitor' }) } })
                            knowledgeGraphConfiguration = @{
                                identity = $script:ReadinessIdentityId
                                managedResources = $managedResources
                            }
                        }
                    }; break
                }
                'containerapp show*' { @{ id = $appId; properties = @{ provisioningState = 'Succeeded'; runningStatus = 'Running'; template = @{ containers = @(@{ env = @(@{ name = 'SIMULATE_CRASH'; value = 'false' }) }) } } }; break }
                'containerapp revision list*' { ,@(@{ properties = @{ active = $true; healthState = 'Healthy'; replicas = 1; trafficWeight = 100 } }); break }
                'monitor metrics alert show*' { @{ id = '/unit-test/alert'; enabled = $true; severity = 2; scopes = @($appId) }; break }
                'connectedmachine show*' {
                    $index = [Array]::IndexOf($Arguments, '-n')
                    $machineName = $Arguments[$index + 1]
                    if ($script:ReadinessFailure -eq 'sql-target' -and $machineName -eq $script:ReadinessSkin.sre.sqlTargetArcMachine) { $machineName = 'wrong-host' }
                    @{ id = "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/$machineName"; status = $(if ($script:ReadinessFailure -eq 'arc') { 'Disconnected' } else { 'Connected' }) }; break
                }
                'resource show*scheduledQueryRules/al-*-sql-lock-timeout*' {
                    $query = Get-SreSqlAlertQuery -MachineResourceId "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/$($script:ReadinessSkin.sre.sqlTargetArcMachine)"
                    if ($script:ReadinessFailure -eq 'sql-query') { $query = $query.Replace('1222', '1205') }
                    @{
                        id = "$base/rg-arc-demo/providers/Microsoft.Insights/scheduledQueryRules/al-arc-demo-sql-lock-timeout"
                        tags = @{ managedBy = 'arc-demo-sql-incident'; workload = 'sql-lock-timeout' }
                        properties = @{
                            displayName = 'Arc SQL lock timeout - arc-demo'; enabled = $true; severity = 2
                            scopes = @("$base/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo")
                            evaluationFrequency = 'PT1M'; windowSize = 'PT15M'; autoMitigate = $true
                            actions = @{ actionGroups = @("$base/rg-arc-demo/providers/Microsoft.Insights/actionGroups/ag-arc-demo") }
                            criteria = @{ allOf = @(@{query=$query;timeAggregation='Count';operator='GreaterThan';threshold=0;failingPeriods=@{numberOfEvaluationPeriods=1;minFailingPeriodsToAlert=1}}) }
                        }
                    }; break
                }
                'resource show*scheduledQueryRules/*' { @{ properties = @{ enabled = $true; severity = 2; displayName = $script:ReadinessSkin.labels.lobAlertTitleContains } }; break }
                'role assignment list*' { ,@(Get-SreArmRoleAssignments | Where-Object { $_.scope -eq "/subscriptions/$SubscriptionId" -or $_.scope -eq $(if ($command -match 'rg-arc-demo-infra') { "$base/rg-arc-demo-infra" } else { "$base/rg-arc-demo" }) }); break }
                default { throw "Unexpected readiness request (all real Azure calls forbidden): $command" }
            }
            ConvertTo-Json -InputObject $value -Depth 30
        }
    } (Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant) $skin
    foreach ($state in @('Active', 'Ready')) {
        $healthyReadiness = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState $state
        Assert-True ($healthyReadiness.status -eq 'pass' -and $healthyReadiness.schemaVersion -eq 1) "$state passes when all verifiable required checks pass"
        $telemetry = @($healthyReadiness.checks | Where-Object id -eq 'telemetry-and-alerts')
        Assert-True ($telemetry.Count -eq 1 -and -not $telemetry[0].required -and $telemetry[0].status -eq 'skipped' -and $null -eq $telemetry[0].observed -and $telemetry[0].message -match 'Not evaluated') 'Rehearsal is advisory, explicitly unevaluated and never success-shaped'
        $platform = @($healthyReadiness.checks | Where-Object id -eq 'incident-platform')
        Assert-True ($platform.Count -eq 1 -and -not $platform[0].required -and $platform[0].status -eq 'pass' -and $platform[0].observed -ceq 'AzMonitor' -and $platform[0].message -match 'not scanner health or alert-delivery proof') 'ARM type alone reports configured platform without demanding connection fields or claiming delivery'
    }
    foreach ($case in @('platform-exact','platform-role','platform-scope','platform-principal','platform-duplicate','platform-disconnected','platform-unset','platform-missing')) {
        & $readinessModule { param($Case) $script:ReadinessFailure=$Case } $case
        $grantReport=Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Active
        Assert-True ($grantReport.status -eq $(if ($case -in @('platform-exact','platform-disconnected','platform-unset')) {'pass'} else {'fail'})) "Readiness preserves exact platform access independently of connectivity: $case; $($grantReport.checks | Where-Object status -eq 'fail' | ConvertTo-Json -Depth 10 -Compress)"
        if ($case -in @('platform-disconnected','platform-unset')) {
            Assert-True (@($grantReport.checks | Where-Object { $_.id -eq 'incident-platform' -and -not $_.required -and $_.status -eq 'pending' -and $_.message -match 'WARNING: ARM does not select Azure Monitor' -and $_.message -match 'portal fallback' }).Count -eq 1) 'Disconnected or unset incident platform is an explicit fallback warning, not a failure or proof of alert readiness'
        }
        if ($case -eq 'platform-missing') {
            Assert-True (@($grantReport.checks | Where-Object { $_.id -eq 'azure-monitor-alert-access' -and $_.required -and $_.status -eq 'fail' }).Count -eq 1) 'AzMonitor selection alone does not establish required scanner access'
        }
    }
    & $readinessModule { $script:ReadinessFailure='' }
    $isolatedFailures = @{
        'missing-app' = @('T09-resource-health')
        'missing-container-alert' = @('T09-alert')
        'missing-arc' = @('T11-resource-health')
        'missing-lob-alert' = @('T11-alert')
        'denied-lob-alert' = @('T11-alert')
    }
    foreach ($case in $isolatedFailures.Keys) {
        & $readinessModule { param($Case) $script:ReadinessFailure = $Case } $case
        $isolated = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant
        $failedChecks = @($isolated.checks | Where-Object { $_.required -and $_.status -eq 'fail' })
        Assert-True ($isolated.status -eq 'fail' -and $failedChecks.Count -eq 1 -and $failedChecks[0].id -eq $isolatedFailures[$case][0] -and $failedChecks[0].message -match 'Azure CLI failed') "Resource inspection failure stays explicit and isolated: $case"
        $laterChecks = @('handler-instructions','plan-status-review','plan-filters-handler','identity-grant-boundary','azure-monitor-alert-access','rbac-rg-arc-demo','rbac-rg-arc-demo-infra')
        Assert-True (@($isolated.checks | Where-Object { $_.id -in $laterChecks -and $_.status -eq 'pass' }).Count -eq $laterChecks.Count) "Data-plane and IAM checks still run after $case"
        Assert-True (@($isolated.checks | Where-Object id -EQ 'inspection-error').Count -eq 0) 'One missing prerequisite never collapses the report'
    }
    & $readinessModule { $script:ReadinessFailure='' }
    $sqlSkinPath = [IO.Path]::GetTempFileName()
    try {
        $sqlSkin = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
        $sqlSkin.sre.requiredScenarios += 'SQL'
        $sqlSkin | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $sqlSkinPath
        $sqlDesired = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath
        & $readinessModule { param($Desired, $Skin) $script:ReadinessDesired = $Desired; $script:ReadinessSkin = $Skin } $sqlDesired $sqlSkin
        $sqlReport = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath
        Assert-True ($sqlReport.status -eq 'pass' -and @($sqlReport.checks | Where-Object { $_.id -eq 'SQL-alert' -and $_.status -eq 'pass' }).Count -eq 1) 'SQL readiness wires exact optional alert/host/managed route checks'
        & $readinessModule { $script:ReadinessFailure='sql-group-covered' }
        $covered=Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath
        Assert-True ($covered.status -eq 'pass') 'Exact managed Arc group covers the verified SQL host without a parent update'
        $failures = @{ 'sql-scope'='managed-resources'; 'sql-target'='SQL-resource-health'; 'sql-query'='SQL-alert'; 'sql-filter'='plan-status-review'; 'sql-cooldown'='plan-filters-handler'; 'missing-sql-alert'='SQL-alert' }
        foreach ($failure in $failures.Keys) {
            & $readinessModule { param($Failure) $script:ReadinessFailure = $Failure } $failure
            $failedSql = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath
            Assert-True ($failedSql.status -eq 'fail' -and @($failedSql.checks | Where-Object { $_.id -eq $failures[$failure] -and $_.status -eq 'fail' }).Count -eq 1) "Required $failure is never hidden by skipped rehearsal"
        }
    } finally {
        Remove-Item -LiteralPath $sqlSkinPath -Force
        & $readinessModule { param($Desired, $Skin) $script:ReadinessDesired=$Desired; $script:ReadinessSkin=$Skin; $script:ReadinessFailure='' } (Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant) $skin
    }
    $actsSkinPath = [IO.Path]::GetTempFileName()
    try {
        $actsSkin = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
        $actsSkin.sre.requiredScenarios += @('ASK', 'MEMORY')
        $actsSkin | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $actsSkinPath
        $actsDesired = Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant -SkinPath $actsSkinPath
        & $readinessModule {
            param($Desired, $Skin)
            $script:ReadinessDesired = $Desired; $script:ReadinessSkin = $Skin
            function script:Get-SreActsDataChecks { @() }
        } $actsDesired $actsSkin
        $actsReport = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -SkinPath $actsSkinPath
        Assert-True (@($actsReport.checks | Where-Object { $_.id -match '^(ASK|MEMORY|PROACTIVE)-' }).Count -eq 0 -and @($actsReport.checks | Where-Object { $_.id -eq 'T11-resource-health' }).Count -eq 1) 'The ASK and MEMORY modules (and PROACTIVE) add no Arc resource-health rows of their own'
    } finally {
        Remove-Item -LiteralPath $actsSkinPath -Force
        & $readinessModule {
            param($Desired, $Skin)
            $script:ReadinessDesired = $Desired; $script:ReadinessSkin = $Skin; $script:ReadinessFailure = ''
            Remove-Item Function:\Get-SreActsDataChecks -ErrorAction SilentlyContinue
        } (Get-SreDesiredConfiguration -SubscriptionId $subscription -TenantId $tenant) $skin
    }
    foreach ($failure in @('parent', 'denied', 'arc')) {
        & $readinessModule { param($Failure) $script:ReadinessFailure = $Failure } $failure
        $failed = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Active
        $expected = if ($failure -eq 'arc') { 'pending' } else { 'fail' }
        Assert-True ($failed.status -eq $expected) "Advisory rehearsal does not hide required $failure $expected"
    }
} finally {
    & $readinessModule {
        Remove-Item Function:\Assert-SreContext,Function:\New-SreConfigurationSession,Function:\Get-SreConfigurationSnapshot,Function:\Get-SreArmRoleAssignments,Function:\Invoke-SreAz
        Remove-Variable ReadinessDesired,ReadinessSkin,ReadinessFailure,ReadinessBase,ReadinessAgentId,ReadinessIdentityId -Scope Script
    }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) "sre-readiness-cli-$([guid]::NewGuid())"
$fixtureModule = Join-Path $fixture 'lib'
$fixtureScript = Join-Path $fixture 'Test-SreReadiness.ps1'
$fixtureModuleFile = Join-Path $fixtureModule 'SreReadiness.psm1'
$fixtureReport = Join-Path $fixtureModule 'healthy.json'
try {
    New-Item -ItemType Directory -Path $fixtureModule -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Test-SreReadiness.ps1') -Destination $fixtureScript
    $healthyReadiness | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixtureReport
    @'
function Get-SreReadinessReport {
    param($SubscriptionId, $TenantId, $SkinPath, $DesiredState, $PreviousIdentityPrincipalId)
    Write-Warning 'Synthetic CLI diagnostic'
    $report = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'healthy.json') -Raw | ConvertFrom-Json -AsHashtable
    $report.desiredState = $DesiredState
    $report
}
Export-ModuleMember -Function Get-SreReadinessReport
'@ | Set-Content -LiteralPath $fixtureModuleFile
    foreach ($state in @('Active', 'Ready')) {
        $raw = & (Get-Command pwsh).Source -NoProfile -File $fixtureScript -SubscriptionId $subscription -TenantId $tenant -DesiredState $state -OutputFormat Json
        $readinessExit = $LASTEXITCODE
        $jsonReport = ($raw -join "`n") | ConvertFrom-Json
        Assert-True ($readinessExit -eq 0 -and $jsonReport.status -eq 'pass') "$state original CLI JSON/exit0 agrees with healthy report despite warning"
        Assert-True (@($jsonReport.checks | Where-Object { $_.id -eq 'telemetry-and-alerts' -and -not $_.required -and $_.status -eq 'skipped' }).Count -eq 1) 'CLI retains explicitly unevaluated advisory item'
        Assert-True ($jsonReport.checks[-1].id -eq 'inspection-warnings' -and $jsonReport.checks[-1].observed[0] -match 'Synthetic CLI diagnostic') 'Worker warning diagnostics are retained in machine-readable checks'
    }
} finally {
    foreach ($file in @($fixtureScript, $fixtureModuleFile, $fixtureReport)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    if (Test-Path -LiteralPath $fixtureModule) { Remove-Item -LiteralPath $fixtureModule -Force }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
}
$global:AzCalls.Clear()
& (Join-Path $root 'scripts\Hibernate-SreAgent.ps1') -SubscriptionId $subscription -TenantId $tenant -WhatIf
Assert-True (@($global:AzCalls | Where-Object { $_ -match 'delete|account set' }).Count -eq 0) 'Absent-state WhatIf has no mutation or context-selection side effects'
$outputPath = Join-Path ([IO.Path]::GetTempPath()) "sre-guest-test-$([guid]::NewGuid()).ps1"
& (Join-Path $root 'scripts\Invoke-LobArcAppOnArc.ps1') -SubscriptionId $subscription -TenantId $tenant -GuestScriptOutputPath $outputPath -WhatIf
Assert-True (-not (Test-Path $outputPath)) 'WhatIf does not write guest script output'
$global:AzCalls.Clear()
Assert-Throws { & (Join-Path $root 'scripts\Deploy-SreAgent.ps1') -SubscriptionId $subscription -TenantId $tenant } 'ParentOnly'
Assert-True ($global:AzCalls.Count -eq 0) 'Unavailable complete bootstrap fails before any Azure mutation'

# A live-shaped mock verifies legacy role adoption and repeatable WhatIf parameters.
$global:CapturedParameters = @()
$global:RetainedDiagnosticsFixture = $false
$global:DriftedDiagnosticsFixture = $false
$global:ExtraGrantFixture = $false
$global:SqlManagedTargetMismatch = $false
$global:PlatformGrantFixture = ''
$global:ExistingParentFixture = $false
$global:ParentSettingsFailure = ''
$global:AzResponder = {
    $command = $args -join ' '
    $base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups'
    if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"servicePrincipal"}}' }
    if ($command -like 'group exists*') { return 'true' }
    if ($command -like 'group show*') {
        if ($command -match 'rg-arc-demo-infra') { return "$base/rg-arc-demo-infra" }
        return "$base/rg-arc-demo"
    }
    if ($command -like 'identity list*') { return '[{"name":"sre-arc-demo-uami","principalId":"00000000-0000-0000-0000-000000000003"}]' }
    if ($command -like 'identity show*') { return @{ id="$base/rg-arc-demo-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami";principalId='00000000-0000-0000-0000-000000000003' } | ConvertTo-Json }
    if ($command -like 'resource list*') {
        if ($global:ExistingParentFixture) {
            return @(@{ id="$base/rg-arc-demo-sre/providers/Microsoft.App/agents/sre-arc-demo";type='Microsoft.App/agents';name='sre-arc-demo' }) | ConvertTo-Json -AsArray
        }
        if ($global:RetainedDiagnosticsFixture) {
            return @(
                @{ id = "$base/rg-arc-demo-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami"; type = 'Microsoft.ManagedIdentity/userAssignedIdentities'; name = 'sre-arc-demo-uami' }
                @{ id = "$base/rg-arc-demo-sre/providers/Microsoft.Insights/components/sre-arc-demo-appi"; type = 'Microsoft.Insights/components'; name = 'sre-arc-demo-appi' }
                @{ id = "$base/rg-arc-demo-sre/providers/Microsoft.Insights/actionGroups/Application Insights Smart Detection"; type = 'Microsoft.Insights/actionGroups'; name = 'Application Insights Smart Detection' }
            ) | ConvertTo-Json
        }
        return '[]'
    }
    if ($command -like 'resource show*') {
        if ($command -match 'Microsoft.App/agents/') {
            return @{ properties=@{ incidentManagementConfiguration=@{type=$(if($global:PlatformGrantFixture -eq 'disconnected'){'None'}else{'AzMonitor'})};knowledgeGraphConfiguration=@{managedResources=@()} } } | ConvertTo-Json -Depth 10
        }
        $workspace = if ($global:DriftedDiagnosticsFixture) { "$base/elsewhere/providers/Microsoft.OperationalInsights/workspaces/other" } else { "$base/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo" }
        return @{ location = 'australiaeast'; properties = @{ WorkspaceResourceId = $workspace } } | ConvertTo-Json
    }
    if ($command -like 'rest --method get*') {
        if ($command -match '/Microsoft.App/agents/') {
            if ($global:ParentSettingsFailure -eq 'denied') { $global:LASTEXITCODE = 13; return '' }
            $settings = Get-Content (Join-Path $root 'config\sre-parent-settings.json') -Raw | ConvertFrom-Json -AsHashtable
            $settings.provisioningState = 'Succeeded'
            if ($global:ParentSettingsFailure -eq 'limit') { $settings.monthlyAgentUnitLimit = 9999; $settings.provisioningState = 'Failed' }
            $agentId = "$base/rg-arc-demo-sre/providers/Microsoft.App/agents/sre-arc-demo"
            if ($global:ParentSettingsFailure -eq 'target') { $agentId += '-other' }
            return @{ id=$agentId; properties=$settings } | ConvertTo-Json -Depth 30
        }
        $value = @()
        foreach ($rg in @('rg-arc-demo', 'rg-arc-demo-infra')) {
            foreach ($role in @('acdd72a7-3385-48ef-bd42-f606fba81ae7', '92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'b24988ac-6180-42a0-ab88-20f7382dd24c')) {
                $scope = "$base/$rg"
                $value += @{ id = "$scope/providers/Microsoft.Authorization/roleAssignments/$role"; name = $role; properties = @{ principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = "/roles/$role" } }
            }
        }
        if ($global:ExtraGrantFixture) {
            $scope = '/subscriptions/00000000-0000-0000-0000-000000000001'
            $value += @{ id = "$scope/providers/Microsoft.Authorization/roleAssignments/extra"; name = 'extra'; properties = @{ principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c' } }
        }
        if ($global:PlatformGrantFixture) {
            $scope='/subscriptions/00000000-0000-0000-0000-000000000001'
            $grant=@{ id="$scope/providers/Microsoft.Authorization/roleAssignments/platform";name='platform';properties=@{principalId='00000000-0000-0000-0000-000000000003';scope=$scope;roleDefinitionId='/roles/749f88d5-cbae-40b8-bcfc-e573ddc772fa'} }
            switch($global:PlatformGrantFixture) {
                'role' { $grant.properties.roleDefinitionId='/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' }
                'principal' { $grant.properties.principalId='00000000-0000-0000-0000-000000000004' }
                'scope' { $grant.properties.scope="$scope/resourceGroups/unowned";$grant.id="$($grant.properties.scope)/providers/Microsoft.Authorization/roleAssignments/platform" }
                'duplicate' { $value+=@{id="$scope/providers/Microsoft.Authorization/roleAssignments/duplicate";name='duplicate';properties=$grant.properties.Clone()} }
            }
            $value+=$grant
        }
        return @{ value = $value } | ConvertTo-Json -Depth 20
    }
    if ($command -like 'role assignment list*') {
        $scope = if ($command -match 'rg-arc-demo-infra') { "$base/rg-arc-demo-infra" } else { "$base/rg-arc-demo" }
        $grants=@(
            @{ name = 'legacy-reader'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' }
            @{ name = 'legacy-la'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/92aaf0da-9dab-42b6-94a3-d43ce8d16293' }
            @{ name = 'legacy-contributor'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c' }
        )
        if ($global:PlatformGrantFixture -in @('exact','disconnected','absent')) {
            $grants+=@{name='platform';principalId='00000000-0000-0000-0000-000000000003';scope='/subscriptions/00000000-0000-0000-0000-000000000001';roleDefinitionId='/roles/749f88d5-cbae-40b8-bcfc-e573ddc772fa'}
        }
        return ($grants | ConvertTo-Json)
    }
    if ($command -like 'monitor log-analytics workspace show*') { return "$base/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo" }
    if ($command -like 'monitor action-group show*') { return "$base/rg-arc-demo/providers/Microsoft.Insights/actionGroups/ag-arc-demo" }
    if ($command -like 'containerapp show*') { return "$base/rg-arc-demo-infra/providers/Microsoft.App/containerApps/ca-arc-demo-fault" }
    if ($command -like 'connectedmachine show*') {
        $index = [Array]::IndexOf($args, '-n')
        $name = $args[$index + 1]
        if ($global:SqlManagedTargetMismatch -and $name -eq 'win-sql-01') { $name = 'other-sql' }
        return "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/$name"
    }
    if ($command -like 'bicep build*') { return '{}' }
    if ($command -like 'deployment sub what-if*') {
        $index = [Array]::IndexOf($args, '--parameters')
        $global:CapturedParameters += Get-Content -LiteralPath $args[$index + 1].TrimStart('@') -Raw
        return '{}'
    }
    if ($command -like 'deployment sub create*') {
        $values = @{
            managedIdentityPrincipalId = '00000000-0000-0000-0000-000000000003'
            agentName = 'sre-arc-demo'; agentPortalUrl = 'https://example.invalid/agent'
            managedIdentityId = "$base/rg-arc-demo-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/sre-arc-demo-uami"
            accessLevel = 'High'; managedResourceIds = @("$base/rg-arc-demo", "$base/rg-arc-demo-infra")
        }
        $outputs = @{}
        foreach ($key in $values.Keys) { $outputs[$key] = @{value=$values[$key]} }
        return @{properties=@{outputs=$outputs}} | ConvertTo-Json -Depth 20
    }
    throw "Unexpected mocked Azure call: $command"
}
$deploy = Join-Path $root 'scripts\Deploy-SreAgent.ps1'
& $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf
& $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf
Assert-True ($global:CapturedParameters.Count -eq 2) 'Both mocked previews completed'
$parameters = $global:CapturedParameters[0] | ConvertFrom-Json
Assert-True ($parameters.parameters.deployerPrincipalType.value -eq 'ServicePrincipal') 'SP and managed identity execution do not assume User'
Assert-True ($parameters.parameters.arcRoleAssignmentNames.value.'acdd72a7-3385-48ef-bd42-f606fba81ae7' -eq 'legacy-reader') 'Existing same-principal role names are adopted'
Assert-True ($parameters.parameters.additionalManagedResourceIds.value.Count -eq 2) 'Both required scenario resources are reconstructed'
Assert-True ($global:CapturedParameters[0] -eq $global:CapturedParameters[1]) 'Repeated preview produces identical deployment parameters'
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -AccessLevel Low -WhatIf } 'incompatible grant'
$global:RetainedDiagnosticsFixture = $true
& $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf
Assert-True ($global:CapturedParameters[0] -eq $global:CapturedParameters[2]) 'Wake safely reuses retained diagnostics/grants with identical IaC parameters; old UAMI-only state also reconstructs'
Assert-True (@($global:AzCalls | Where-Object { $_ -like 'role assignment list*' -and $_ -notmatch '--fill-principal-name false' }).Count -eq 0) 'Deployment never requests unnecessary Graph principal display names'
$global:DriftedDiagnosticsFixture = $true
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf } 'Retained Application Insights'
$global:DriftedDiagnosticsFixture = $false
$global:ExtraGrantFixture = $true
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf } 'incompatible grant scope/role'
$global:ExtraGrantFixture = $false

$beforePlatform=$global:CapturedParameters.Count
$global:PlatformGrantFixture='exact'
& $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf
Assert-True ($global:CapturedParameters.Count -eq $beforePlatform+1) 'Exact existing subscription Monitoring Contributor on retained UAMI passes parent preview'
Assert-True ($global:CapturedParameters[-1] -eq $global:CapturedParameters[0]) 'Platform prerequisite is not adopted into or created by RG role parameters'
$grantPreview = & $deploy -SubscriptionId $subscription -TenantId $tenant -GrantAzureMonitorAlertAccess -WhatIf
Assert-True ($grantPreview.status -eq 'existing' -and $grantPreview.principalId -eq '00000000-0000-0000-0000-000000000003') 'Deploy opt-in previews the verified live principal without granting access'
foreach($case in @('disconnected','absent')) {
    $global:PlatformGrantFixture=$case
    $beforeWake=$global:CapturedParameters.Count
    & $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf
    Assert-True ($global:CapturedParameters.Count -eq $beforeWake+1 -and $global:CapturedParameters[-1] -eq $global:CapturedParameters[0]) "Retained platform access does not block preview with disconnected or absent parent: $case"
}
foreach($case in @('role','scope','principal','duplicate')) {
    $global:PlatformGrantFixture=$case
    Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf } 'incompatible grant scope/role|Duplicate Azure Monitor'
}
$global:PlatformGrantFixture=''
$global:ExistingParentFixture = $true
$beforeGuard = $global:AzCalls.Count
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -WhatIf } 'Existing parent detected'
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -ParentOnly -ApproveParentCreation } 'Existing parent detected'
Assert-True (@($global:AzCalls | Select-Object -Skip $beforeGuard | Where-Object { $_ -like 'deployment sub*' -or $_ -like 'bicep build*' }).Count -eq 0) 'Existing parent guard stops before IaC preview or PUT can strip live properties'
$global:ExistingParentFixture = $false
Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -ParentOnly } 'AAU meter'
& $deploy -SubscriptionId $subscription -TenantId $tenant -ParentOnly -ApproveParentCreation
Assert-True (@($global:AzCalls | Where-Object { $_ -like 'rest --method get*' -and $_ -match '/Microsoft.App/agents/' }).Count -gt 0) 'New parent settings are verified through the pinned read-only ARM API'
foreach ($case in @('limit','target','denied')) {
    $global:ParentSettingsFailure = $case
    $beforeWrites = @($global:AzCalls | Where-Object { $_ -like 'deployment sub create*' }).Count
    Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -ParentOnly -ApproveParentCreation } 'unverified|different target|failed \(13\)'
    Assert-True (@($global:AzCalls | Where-Object { $_ -like 'deployment sub create*' }).Count -eq $beforeWrites + 1) "Failed settings verification never retries the parent deployment: $case"
}
$global:ParentSettingsFailure = ''

$sqlSkinPath = [IO.Path]::GetTempFileName()
try {
    $sqlSkin = Get-Content (Join-Path $root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
    $sqlSkin.sre.requiredScenarios += 'SQL'
    $sqlSkin | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $sqlSkinPath
    & $deploy -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath -WhatIf
    $sqlParameters = $global:CapturedParameters[-1] | ConvertFrom-Json
    $ids = @($sqlParameters.parameters.additionalManagedResourceIds.value)
    Assert-True ($ids.Count -eq 3 -and @($ids | Where-Object { $_ -like '*/machines/win-sql-01' }).Count -eq 1) 'SQL rebuild includes exactly the additional SQL host alongside T09/LOB resources'
    Assert-True (($sqlParameters.parameters.arcRoleAssignmentNames.value | ConvertTo-Json -Compress) -eq ($parameters.parameters.arcRoleAssignmentNames.value | ConvertTo-Json -Compress)) 'SQL uses the existing deterministic Arc group grants without widening IAM'
    $before = $global:CapturedParameters.Count
    $global:SqlManagedTargetMismatch = $true
    Assert-Throws { & $deploy -SubscriptionId $subscription -TenantId $tenant -SkinPath $sqlSkinPath -WhatIf } 'different host, group or subscription'
    Assert-True ($global:CapturedParameters.Count -eq $before) 'Wrong SQL target is rejected before deployment preview/write'
} finally {
    $global:SqlManagedTargetMismatch = $false
    Remove-Item -LiteralPath $sqlSkinPath -Force
}

& (Join-Path $PSScriptRoot 'Test-SreMonitorAccess.ps1')
& (Join-Path $PSScriptRoot 'Test-SreLifecycle.ps1')
& (Join-Path $PSScriptRoot 'Test-SreDemoRoute.ps1')
& (Join-Path $PSScriptRoot 'Test-SreRelease.ps1')
& (Join-Path $PSScriptRoot 'Test-SreReleaseExtras.ps1')
& (Join-Path $PSScriptRoot 'Test-FridayRelease.ps1')
& (Join-Path $PSScriptRoot 'Test-SreActs.ps1')
& (Join-Path $PSScriptRoot 'Test-DriftDemo.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Invoke-T10ArcFault.ps1'), [ref]$tokens, [ref]$errors)
$generator = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ScenarioScript' }, $true)
. ([scriptblock]::Create($generator.Extent.Text))
$ServiceName = 'Spooler'; $DiskFileSizeMB = 512; $MinimumFreeGB = 5; $CpuDurationSeconds = 300
foreach ($Scenario in @('StopService', 'DiskPressure', 'CpuPressure', 'WriteEvent')) {
    foreach ($Action in @('Induce', 'Reset', 'Status')) {
        $guest = Get-ScenarioScript
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseInput($guest, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) "Generated T10 $Scenario/$Action parses without executing it"
    }
}
Write-Host "$count assertions passed. All Azure calls were mocked; no cloud mutation occurred."
Write-Host 'ALL OFFLINE TEST SUITES PASSED. Any WARNING or What if lines above are expected mock output.'
} finally {
    if ($previousAz) { Set-Item Function:\global:az -Value $previousAz.ScriptBlock }
    else { Remove-Item Function:\az -ErrorAction SilentlyContinue }
    Remove-Variable -Scope Global -Name AzCalls, AzExitCode, AzResponder, CapturedParameters, RetainedDiagnosticsFixture, DriftedDiagnosticsFixture, ExtraGrantFixture, SqlManagedTargetMismatch, PlatformGrantFixture, ExistingParentFixture, ParentSettingsFailure -ErrorAction SilentlyContinue
}
