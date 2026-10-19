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
Assert-Throws { & $initialize -SubscriptionId $subscription -TenantId $tenant -Apply } 'BackupPath'
$second = & $initialize -SubscriptionId $subscription -TenantId $tenant
Assert-True (($desired | ConvertTo-Json -Depth 30 -Compress) -eq (($second | ConvertFrom-Json) | ConvertTo-Json -Depth 30 -Compress)) 'Repeated desired-state rendering is deterministic'
& (Join-Path $PSScriptRoot 'Test-SreConfiguration.ps1')

Import-Module (Join-Path $root 'scripts\lib\SreReadiness.psm1') -Force
$hibernated = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated
Assert-True ($hibernated.status -eq 'pending') 'Absent identity does not falsely certify orphan-grant cleanup'
$hibernatedKnown = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant -DesiredState Hibernated -PreviousIdentityPrincipalId '00000000-0000-0000-0000-000000000003'
Assert-True ($hibernatedKnown.status -eq 'pass') 'Known old identity and absent groups/grants verify Hibernated'
$ready = Get-SreReadinessReport -SubscriptionId $subscription -TenantId $tenant
Assert-True ($ready.status -eq 'fail') 'Absent parent never becomes Ready'
Assert-True ($ready.checks[0].id -eq 'parent') 'Machine-readable readiness identifies missing parent'
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

$global:AzCalls.Clear()
$global:AzResponder = {
    $command = $args -join ' '
    $base = '/subscriptions/00000000-0000-0000-0000-000000000001'
    $principal = '00000000-0000-0000-0000-000000000003'
    if ($command -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"00000000-0000-0000-0000-000000000002","state":"Enabled","user":{"type":"user"}}' }
    if ($command -like 'group exists*') { return 'true' }
    if ($command -like 'resource list*') { return '[{"name":"sre-arc-demo","type":"Microsoft.App/agents"},{"name":"sre-arc-demo-uami","type":"Microsoft.ManagedIdentity/userAssignedIdentities"}]' }
    if ($command -like 'identity list*') { return '[{"name":"sre-arc-demo-uami","principalId":"00000000-0000-0000-0000-000000000003"}]' }
    if ($command -like 'role assignment list*') {
        $items = @(@{ id = "$base/providers/Microsoft.Authorization/roleAssignments/inherited-monitoring"; name = 'inherited-monitoring'; principalId = $principal; scope = $base; roleDefinitionId = '/roles/749f88d5-cbae-40b8-bcfc-e573ddc772fa' })
        if ($command -match '/resourceGroups/(rg-arc-demo(?:-infra)?) ') {
            $scope = "$base/resourceGroups/$($Matches[1])"
            $items += @{ id = "$scope/providers/Microsoft.Authorization/roleAssignments/scoped-reader"; name = 'scoped-reader'; principalId = $principal; scope = $scope; roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7' }
        }
        return ConvertTo-Json -InputObject $items
    }
    if ($command -like 'role assignment delete*' -or $command -like 'group delete*') { return '' }
    throw "Unexpected mocked Azure call: $command"
}
& (Join-Path $root 'scripts\Hibernate-SreAgent.ps1') -SubscriptionId $subscription -TenantId $tenant -Confirm:$false
$deletes = @($global:AzCalls | Where-Object { $_ -like 'role assignment delete*' })
Assert-True ($deletes.Count -eq 3) 'Cleanup deduplicates inherited grant and removes only two known scoped grants'
Assert-True (@($deletes | Where-Object { $_ -match 'inherited-monitoring' }).Count -eq 1) 'Subscription compatibility grant is cleaned up once'
Assert-True (@($global:AzCalls | Where-Object { $_ -like 'group delete*' -and $_ -match 'rg-arc-demo-sre' }).Count -eq 1) 'Only optional SRE group deletion is submitted'
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
