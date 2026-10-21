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
$skin = Get-DemoSkin -RepoRoot $root
& (Join-Path $PSScriptRoot 'Test-HandoffDefaults.ps1')
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
Assert-True ($desired.handler.properties.instructions -match 'operator Arc Run Command') 'Handler preserves hybrid operator boundary'
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
$second = & $initialize -SubscriptionId $subscription -TenantId $tenant
Assert-True (($desired | ConvertTo-Json -Depth 30 -Compress) -eq (($second | ConvertFrom-Json) | ConvertTo-Json -Depth 30 -Compress)) 'Repeated desired-state rendering is deterministic'
& (Join-Path $PSScriptRoot 'Test-SreConfiguration.ps1')

Import-Module (Join-Path $root 'scripts\lib\SreReadiness.psm1') -Force
$hibernated = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
Assert-True ($hibernated.status -eq 'fail') 'Absent identity does not certify normal retained-identity Hibernated'
$hibernatedKnown = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId '00000000-0000-0000-0000-000000000003'
Assert-True ($hibernatedKnown.status -eq 'fail') 'Legacy whole-group deletion is not normal identity-retained Hibernated'
$ready = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant
Assert-True ($ready.status -eq 'fail') 'Absent parent never becomes Ready'
Assert-True ($ready.checks[0].id -eq 'parent') 'Machine-readable readiness identifies missing parent'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "sre-readiness-cli-$([guid]::NewGuid())"
$fixtureModule = Join-Path $fixture 'lib'
$fixtureScript = Join-Path $fixture 'Test-SreReadiness.ps1'
$fixtureModuleFile = Join-Path $fixtureModule 'SreReadiness.psm1'
try {
    New-Item -ItemType Directory -Path $fixtureModule -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Test-SreReadiness.ps1') -Destination $fixtureScript
    @'
function Get-SreReadinessReport {
    param($SubscriptionId, $TenantId, $SkinPath, $DesiredState, $PreviousIdentityPrincipalId)
    Write-Warning 'Synthetic CLI diagnostic'
    @{
        schemaVersion = 1; workload = 'sre-agent'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceGroups = @()
        desiredState = $DesiredState; status = 'pass'; checks = @()
    }
}
Export-ModuleMember -Function Get-SreReadinessReport
'@ | Set-Content -LiteralPath $fixtureModuleFile
    $raw = & (Get-Command pwsh).Source -NoProfile -File $fixtureScript -SubscriptionId $subscription -TenantId $tenant -OutputFormat Json
    $readinessExit = $LASTEXITCODE
    $jsonReport = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($readinessExit -eq 0 -and $jsonReport.status -eq 'pass') 'Worker warnings never corrupt CLI JSON or change required-check status'
    Assert-True ($jsonReport.checks[-1].id -eq 'inspection-warnings' -and $jsonReport.checks[-1].observed[0] -match 'Synthetic CLI diagnostic') 'Worker warning diagnostics are retained in machine-readable checks'
} finally {
    foreach ($file in @($fixtureScript, $fixtureModuleFile)) {
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
    if ($command -like 'resource list*') { return '[]' }
    if ($command -like 'role assignment list*') {
        $scope = if ($command -match 'rg-arc-demo-infra') { "$base/rg-arc-demo-infra" } else { "$base/rg-arc-demo" }
        return (@(
            @{ name = 'legacy-reader'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' }
            @{ name = 'legacy-la'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/92aaf0da-9dab-42b6-94a3-d43ce8d16293' }
            @{ name = 'legacy-contributor'; principalId = '00000000-0000-0000-0000-000000000003'; scope = $scope; roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c' }
        ) | ConvertTo-Json)
    }
    if ($command -like 'monitor log-analytics workspace show*') { return "$base/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-arc-demo" }
    if ($command -like 'monitor action-group show*') { return "$base/rg-arc-demo/providers/Microsoft.Insights/actionGroups/ag-arc-demo" }
    if ($command -like 'containerapp show*') { return "$base/rg-arc-demo-infra/providers/Microsoft.App/containerApps/ca-arc-demo-fault" }
    if ($command -like 'connectedmachine show*') { return "$base/rg-arc-demo/providers/Microsoft.HybridCompute/machines/win-app-01" }
    if ($command -like 'bicep build*') { return '{}' }
    if ($command -like 'deployment sub what-if*') {
        $index = [Array]::IndexOf($args, '--parameters')
        $global:CapturedParameters += Get-Content -LiteralPath $args[$index + 1].TrimStart('@') -Raw
        return '{}'
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

& (Join-Path $PSScriptRoot 'Test-SreLifecycle.ps1')
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
} finally {
    if ($previousAz) { Set-Item Function:\global:az -Value $previousAz.ScriptBlock }
    else { Remove-Item Function:\az -ErrorAction SilentlyContinue }
    Remove-Variable -Scope Global -Name AzCalls, AzExitCode, AzResponder, CapturedParameters -ErrorAction SilentlyContinue
}
