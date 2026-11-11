#Requires -Version 7.4
# Offline checks for Invoke-DriftDemo.ps1: the three demo drifts (Benign, Risky, Critical) on the ticketing web app and the reset. The real script runs
# against a mocked az, so nothing here reaches Azure. What matters: it changes only the web app the repo created (the sreScenario=T12 tag), only the
# three settings it names, never under -WhatIf, and Reset removes exactly what Start added.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $root 'scripts\lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $root 'scripts\lib\SreRelease.psm1') -Force
$subscription = '00000000-0000-0000-0000-000000000001'
$tenant = '00000000-0000-0000-0000-000000000002'
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Drift demo assertion failed: $Message" }
    $script:count++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Expected /$Pattern/, got: $($_.Exception.Message)"; return }
    throw "Expected failure matching /$Pattern/."
}
function Get-HostText($Output) { (@($Output | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n") }

$driftScript = Join-Path $root 'scripts\Invoke-DriftDemo.ps1'
$previousResponder = $global:AzResponder
$files = [Collections.Generic.List[string]]::new()
try {
    $skinPath = New-TestT12SkinFile -Root $root -Scenarios @('T12', 'PROACTIVE')
    $files.Add($skinPath)
    $skin = Get-DemoSkin -Path $skinPath -RepoRoot $root
    $release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $subscription
    $declaredTags = [ordered]@{}
    foreach ($tag in (Get-SreReleaseDemoTags -Skin $skin).GetEnumerator()) { $declaredTags[$tag.Key] = [string]$tag.Value }
    $declaredTags['sreScenario'] = 'T12'

    function Reset-Drift { $global:DriftState = @{ tags = [ordered]@{} + $declaredTags; httpsOnly = $true; ftps = 'Disabled'; ignoreHttps = $false; accountId = $subscription; writes = [Collections.Generic.List[string]]::new() } }
    Reset-Drift
    $global:AzExitCode = 0
    $global:AzResponder = {
        $command = $args -join ' '
        $s = $global:DriftState
        if ($command -like 'account show*') { return (@{ id = $s.accountId; tenantId = '00000000-0000-0000-0000-000000000002'; state = 'Enabled'; user = @{ type = 'user' } } | ConvertTo-Json) }
        if ($command -like 'resource show --ids *') { return (@{ tags = $s.tags; properties = @{ httpsOnly = $s.httpsOnly } } | ConvertTo-Json -Depth 5) }
        if ($command -like 'webapp config show *') { return (@{ ftpsState = $s.ftps } | ConvertTo-Json) }
        if ($command -like 'tag update *') {
            $s.writes.Add($command)
            $operation = [string]$args[[Array]::IndexOf($args, '--operation') + 1]
            for ($i = [Array]::IndexOf($args, '--tags') + 1; $i -lt $args.Count -and -not ([string]$args[$i]).StartsWith('-'); $i++) {
                $key, $value = ([string]$args[$i]) -split '=', 2
                if ($operation -ceq 'Merge') { $s.tags[$key] = $value } else { $s.tags.Remove($key) }
            }
            return ''
        }
        if ($command -like 'webapp config set *') { $s.writes.Add($command); $s.ftps = [string]$args[[Array]::IndexOf($args, '--ftps-state') + 1]; return '' }
        if ($command -like 'webapp update *') {
            $s.writes.Add($command)
            if (-not $s.ignoreHttps) { $s.httpsOnly = ([string]$args[[Array]::IndexOf($args, '--https-only') + 1]) -ceq 'true' }
            return ''
        }
        throw "Unexpected mocked call: $command"
    }
    function Invoke-Drift([string]$Action, [switch]$WhatIf, [string]$Skin = $skinPath) {
        $arguments = @{ SubscriptionId = $subscription; TenantId = $tenant; Action = $Action; SkinPath = $Skin }
        if ($WhatIf) { $arguments.WhatIf = $true }
        @(& $driftScript @arguments 6>&1)
    }
    $s = $global:DriftState

    # --- Status ------------------------------------------------------------------------------------------------------------------------
    $global:AzCalls.Clear()
    $text = Get-HostText (Invoke-Drift 'Status')
    Check (@($text -split "`n" | Where-Object { $_ -match 'as declared$' }).Count -eq 3 -and $text -notmatch 'DRIFT') 'Status shows the three settings as declared on a clean web app'
    Check ($text -match 'Tags \(Benign\)' -and $text -match 'FTP state \(Risky\)' -and $text -match 'HTTPS only \(Critical\)') 'Each setting is named with its grade'
    Check ($s.writes.Count -eq 0) 'Status writes nothing'

    # --- Start ---------------------------------------------------------------------------------------------------------------------------
    $null = Invoke-Drift 'Start' -WhatIf
    Check ($s.writes.Count -eq 0 -and $s.httpsOnly -and $s.ftps -ceq 'Disabled' -and -not $s.tags.Contains('manual_update')) 'Start under WhatIf changes nothing'
    $text = Get-HostText (Invoke-Drift 'Start')
    Check ($s.writes.Count -eq 3 -and $s.writes[0] -like 'tag update --resource-id * --operation Merge --tags manual_update=true changed_by=portal_user -o none*' -and $s.writes[1] -like "webapp config set -g $($release.resourceGroup) -n $($release.appName) --ftps-state FtpsOnly -o none*" -and $s.writes[2] -like "webapp update -g $($release.resourceGroup) -n $($release.appName) --https-only false -o none*") 'Start is three writes: the two tags merged, FTP state FtpsOnly, HTTPS only off'
    Check ($s.tags['manual_update'] -ceq 'true' -and $s.tags['changed_by'] -ceq 'portal_user' -and $s.ftps -ceq 'FtpsOnly' -and -not $s.httpsOnly) 'The web app now has one Benign, one Risky and one Critical drift'
    Check (@($declaredTags.Keys | Where-Object { $s.tags[$_] -cne $declaredTags[$_] }).Count -eq 0) 'The declared tags are untouched'
    Check (@($text -split "`n" | Where-Object { $_ -match 'DRIFT$' }).Count -eq 3 -and $text -match 'extra: manual_update, changed_by' -and $text -match 'Invoke-ScheduledTask\.ps1 -Action Run -Name bicep-drift-scan -Wait') 'Start shows the three differences and says how to run the drift scan'
    $text = Get-HostText (Invoke-Drift 'Status')
    Check (@($text -split "`n" | Where-Object { $_ -match 'DRIFT$' }).Count -eq 3) 'Status after Start shows all three as drift'

    # --- Reset ---------------------------------------------------------------------------------------------------------------------------
    $s.writes.Clear()
    $null = Invoke-Drift 'Reset' -WhatIf
    Check ($s.writes.Count -eq 0 -and -not $s.httpsOnly) 'Reset under WhatIf changes nothing'
    $text = Get-HostText (Invoke-Drift 'Reset')
    Check ($s.writes.Count -eq 3 -and $s.writes[0] -like 'tag update --resource-id * --operation Delete --tags manual_update=true changed_by=portal_user -o none*' -and $s.writes[1] -like '*--ftps-state Disabled -o none*' -and $s.writes[2] -like '*--https-only true -o none*') 'Reset removes exactly the two tags, then puts FTP state and HTTPS only back'
    Check (@($declaredTags.Keys | Where-Object { $s.tags[$_] -cne $declaredTags[$_] }).Count -eq 0 -and $s.tags.Count -eq $declaredTags.Count -and $s.httpsOnly -and $s.ftps -ceq 'Disabled' -and $text -match 'matches the Bicep again') 'The web app is back to the Bicep and Reset says so'
    $s.writes.Clear()
    $null = Invoke-Drift 'Reset'
    Check ($s.writes.Count -eq 0) 'Reset on a clean web app writes nothing'
    $null = Invoke-Drift 'Start'
    $s.writes.Clear()
    $s.tags['team'] = 'mine'
    Throws { Invoke-Drift 'Reset' } 'still differs from the Bicep after Reset'
    Check ($s.tags.Contains('team') -and -not $s.tags.Contains('manual_update') -and -not $s.tags.Contains('changed_by') -and $s.writes[0] -like '*--operation Delete --tags manual_update=true changed_by=portal_user -o none*' -and $s.httpsOnly -and $s.ftps -ceq 'Disabled') 'A tag of your own is never removed: Reset takes back only what Start added, and then says the web app still differs'
    Reset-Drift
    $s = $global:DriftState
    $null = Invoke-Drift 'Start'
    $s.ignoreHttps = $true
    Throws { Invoke-Drift 'Reset' } 'still differs from the Bicep after Reset'
    $s.ignoreHttps = $false

    # --- It only touches the web app the repo created ------------------------------------------------------------------------------------
    Reset-Drift
    $s = $global:DriftState
    $null = $s.tags.Remove('sreScenario')
    $global:AzCalls.Clear()
    Check ((Get-HostText (Invoke-Drift 'Status')) -match 'as declared|DRIFT') 'Status still reads a web app that is not owned'
    Throws { Invoke-Drift 'Start' } 'does not carry the tag sreScenario=T12'
    Throws { Invoke-Drift 'Reset' } 'does not carry the tag sreScenario=T12'
    $s.tags['sreScenario'] = 't12'
    Throws { Invoke-Drift 'Start' } 'does not carry the tag sreScenario=T12'
    Check ($s.writes.Count -eq 0) 'A web app without the exact sreScenario=T12 tag is never changed'
    Reset-Drift
    $s = $global:DriftState
    $global:AzCalls.Clear()
    $null = Invoke-Drift 'Start'
    $null = Invoke-Drift 'Reset'
    $groups = @($global:AzCalls | ForEach-Object { if ($_ -match ' -g (\S+)') { $Matches[1] } } | Select-Object -Unique)
    $ids = @($global:AzCalls | ForEach-Object { if ($_ -match '--(?:ids|resource-id) (\S+)') { $Matches[1] } } | Select-Object -Unique)
    Check ($groups.Count -eq 1 -and $groups[0] -ceq $release.resourceGroup -and $ids.Count -eq 1 -and $ids[0] -ceq $release.appId -and @($global:AzCalls | Where-Object { $_ -like '*--subscription*' -and $_ -notlike "*--subscription $subscription*" }).Count -eq 0) 'Every call names the ticketing group and the one web app, with the explicit subscription'
    Check (@($global:AzCalls | Where-Object { $_ -match 'account set|account clear|\blogin\b|\blogout\b' }).Count -eq 0) 'The script never switches the account or the subscription'

    # --- Guards ----------------------------------------------------------------------------------------------------------------------------
    Reset-Drift
    $s = $global:DriftState
    $s.accountId = '00000000-0000-0000-0000-000000000099'
    Throws { Invoke-Drift 'Start' } 'Azure context does not match'
    Check ($s.writes.Count -eq 0) 'Another signed-in subscription stops the script before it changes anything'
    $withoutT12 = New-TestT12SkinFile -Root $root -Scenarios @('T09')
    $files.Add($withoutT12)
    Throws { Invoke-Drift 'Start' -Skin $withoutT12 } 'does not require T12'
    Throws { & $driftScript -SubscriptionId $subscription -TenantId $tenant -Action Break -SkinPath $skinPath } 'does not belong to the set|ValidateSet|Break'
} finally {
    foreach ($path in $files) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    Remove-Variable -Scope Global -Name DriftState -ErrorAction SilentlyContinue
    $global:AzResponder = $previousResponder
}
Write-Host "$count drift demo assertions passed. az was mocked; nothing reached Azure."
