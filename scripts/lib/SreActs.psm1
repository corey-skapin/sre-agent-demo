Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DemoSkin.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreRelease.psm1')

# Acts 1, 3, 4 and 6 of the demo, as four modules a skin turns on in sre.requiredScenarios:
#   ASK        a skill for open questions about the estate (Act 1)
#   MEMORY     a hand-written overview.md seeded into an empty notes folder (Act 3)
#   PROACTIVE  two read-only agents, three skills and three Review-mode scheduled tasks: health check, drift scan, governance deck (Act 4)
#   ARC        a skill that repairs the faulted Arc LOB app with one Run Command Review card, and the repair script it runs (Act 6)
# This module only renders them from config/acts and the skin; nothing here calls Azure. SreActsExtras.psm1 applies them.
$script:ActsModules = @('ASK', 'MEMORY', 'PROACTIVE', 'ARC')
$script:NotesBudget = 2000
$script:GitHubHost = 'github.com'
# The T11 default app folder (Invoke-LobArcAppOnArc.ps1 -AppRoot). The repair script sits beside the app, and the Run Command names it by path.
$script:ArcAppRoot = 'C:\ProgramData\ArcSreLobApp'
$script:ArcRepairFile = 'Repair-LobApp.ps1'

function Get-SreActsModules {
    param([Parameter(Mandatory)][object]$Skin)
    @(@(Get-DemoSkinValue -Skin $Skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11')) | Where-Object { $_ -in $script:ActsModules })
}

function Get-SreArcConfig {
    <#
    .SYNOPSIS
    The names the ARC module (Act 6) works with, from the skin: the LOB server, its app and scheduled task, and where the repair script lives on the server.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $prefix = [string]$Skin.azure.namePrefix
    $machine = [string]$Skin.sre.targetArcMachine
    $path = "$script:ArcAppRoot\$script:ArcRepairFile"
    [ordered]@{
        machineName = $machine; resourceGroup = "rg-$prefix"
        machineId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.HybridCompute/machines/$machine"
        workspaceName = "law-$prefix"
        workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.OperationalInsights/workspaces/law-$prefix"
        eventSource = [string]$Skin.labels.lobEventSource; taskName = [string]$Skin.labels.lobTaskName; alertTitle = [string]$Skin.labels.lobAlertTitleContains
        faultMode = [string]$Skin.sre.lobFaultMode; appRoot = $script:ArcAppRoot; repairFile = $script:ArcRepairFile; repairPath = $path
        # The agent names each run command with this prefix and a time stamp; the install marker keeps its own name, so Reset never removes it.
        runPrefix = 'sre-repair-lob-'; installName = 'arc-repair-install'; apiVersion = '2024-11-10-preview'; timeoutSeconds = 120
    }
}

function Get-SreActsSettings {
    <#
    .SYNOPSIS
    The names and flags the files in config/acts refer to, from the skin. Ticketing names exist only when the skin requires T12.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $scenarios = @(Get-DemoSkinValue -Skin $Skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
    $prefix = [string]$Skin.azure.namePrefix
    $tags = Get-SreReleaseDemoTags -Skin $Skin
    $tokens = @{
        customerName = [string]$Skin.customer.name
        arcGroup = "rg-$prefix"; infraGroup = "rg-$prefix-infra"; containerApp = "ca-$prefix-fault"
        arcWorkspaceName = "law-$prefix"
        arcWorkspaceId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix/providers/Microsoft.OperationalInsights/workspaces/law-$prefix"
        tagNames = (@($tags.Keys) -join ', ')
    }
    if ('ARC' -in $scenarios) {
        $arc = Get-SreArcConfig -Skin $Skin -SubscriptionId $SubscriptionId
        $tokens.arcMachineName = $arc.machineName; $tokens.arcMachineId = $arc.machineId
        $tokens.lobEventSource = $arc.eventSource; $tokens.lobTaskName = $arc.taskName; $tokens.lobAppRoot = $arc.appRoot
        $tokens.repairPath = $arc.repairPath; $tokens.repairPathJson = $arc.repairPath.Replace('\', '\\')
        $tokens.repairRunPrefix = $arc.runPrefix; $tokens.runCommandApi = $arc.apiVersion; $tokens.runCommandTimeout = [string]$arc.timeoutSeconds
    }
    $flags = @{ T09 = ('T09' -in $scenarios); T12 = ('T12' -in $scenarios) }
    if ($flags.T12) {
        $release = Get-SreReleaseSettings -Skin $Skin -SubscriptionId $SubscriptionId
        $tokens.appName = $release.appName
        $tokens.appGroup = $release.resourceGroup
        $tokens.groupId = $release.groupId
        $tokens.workspaceId = $release.workspaceId
        $tokens.alertName = $release.alertName
        $tokens.spareAlertName = $release.spareAlertName
        $tokens.planName = $release.planName
        $tokens.appSku = $release.sku
        $tokens.repository = $release.repository
        $tokens.releaseUrlPrefix = "https://$script:GitHubHost/$($release.repository)/releases/download/"
        $tokens.declaredTags = (@(@($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) + 'sreScenario=T12') -join ', ')
    }
    @{ tokens = $tokens; flags = $flags }
}

function Read-SreActsText {
    # Config text with LF line endings, the conditional blocks (<!-- NAME --> ... <!-- /NAME --> on their own lines) resolved and every token filled.
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][hashtable]$Settings)
    $path = Join-Path (Join-Path $PSScriptRoot '..\..\config\acts') $RelativePath
    $text = (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
    foreach ($name in @([regex]::Matches($text, '(?m)^<!-- /([A-Z0-9]+) -->$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
        if (-not $Settings.flags.ContainsKey($name)) { throw "Config file $RelativePath has a conditional block '$name' that nothing defines." }
        $text = [regex]::Replace($text, "(?ms)^<!-- $name -->\n(?<inner>.*?)^<!-- /$name -->\n?", $(if ($Settings.flags[$name]) { '${inner}' } else { '' }))
    }
    foreach ($key in $Settings.tokens.Keys) { $text = $text.Replace("{$key}", [string]$Settings.tokens[$key]) }
    $left = @([regex]::Matches($text, '\{[A-Za-z][A-Za-z0-9]*\}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($left.Count) { throw "Config file $RelativePath still has unfilled tokens: $($left -join ', ')." }
    return $text
}

function Get-SreActsFile {
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][hashtable]$Settings, [Parameter(Mandatory)][string[]]$Keys)
    $parsed = ConvertFrom-SreMarkdownConfig -Text (Read-SreActsText -RelativePath $RelativePath -Settings $Settings)
    foreach ($key in $Keys) { if (-not $parsed.meta[$key]) { throw "Config file $RelativePath needs a '$key' line in its front matter." } }
    if (-not $parsed.body) { throw "Config file $RelativePath has no body." }
    if ($parsed.meta['name'] -cne [IO.Path]::GetFileNameWithoutExtension($RelativePath)) { throw "Config file $RelativePath must have the name '$([IO.Path]::GetFileNameWithoutExtension($RelativePath))'." }
    return $parsed
}

function Get-SreActsSkill {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Settings)
    $parsed = Get-SreActsFile -RelativePath "$Folder\skills\$Name.md" -Settings $Settings -Keys @('name', 'description')
    [ordered]@{ name = $Name; description = [string]$parsed.meta['description']; content = $parsed.body }
}

function Get-SreActsAgent {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Settings)
    $parsed = Get-SreActsFile -RelativePath "proactive\agents\$Name.md" -Settings $Settings -Keys @('name', 'description', 'tools')
    $tools = @(([string]$parsed.meta['tools'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # No agent here may hold the Azure write tool or a GitHub tool: Review mode gates the write tool, and nothing in these acts needs either.
    $forbidden = @($tools | Where-Object { $_ -like 'RunAzCliWriteCommands' -or $_ -like '*Github*' })
    if ($forbidden.Count) { throw "Agent $Name must stay read-only but lists: $($forbidden -join ', ')." }
    @{
        name = $Name; type = 'ExtendedAgent'; tags = @()
        properties = @{
            instructions = $parsed.body; handoffDescription = [string]$parsed.meta['description']; handoffs = @()
            tools = $tools; enableSkills = $true
        }
    }
}

function Get-SreActsTask {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Settings)
    $parsed = Get-SreActsFile -RelativePath "proactive\tasks\$Name.md" -Settings $Settings -Keys @('name', 'description', 'cron', 'agent')
    $cron = [string]$parsed.meta['cron']
    if ($cron -notmatch '^\S+( \S+){4}$') { throw "Task $Name needs a five-field cron schedule, not '$cron'." }
    # Wanted Paused: a schedule that starts threads by itself spends AAUs. The platform ignores this flag and starts a new task Active, so
    # Invoke-SreActs pauses it right after the write. Run it by hand with Invoke-ScheduledTask.ps1, or resume it yourself.
    [ordered]@{
        name = $Name; description = [string]$parsed.meta['description']; cronExpression = $cron
        agent = [string]$parsed.meta['agent']; agentPrompt = $parsed.body; agentMode = 'Review'; enabled = $false
    }
}

function Get-SreActsSeed {
    <#
    .SYNOPSIS
    The notes to seed into an empty notes folder: the repo's overview.md, or the .md files of the private folder the skin names in memory.seedPath
    (for example an earlier export of the agent's notes).
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][hashtable]$Settings)
    $folder = [string](Get-DemoSkinValue -Skin $Skin -Path 'memory.seedPath' -Default '')
    $files = [ordered]@{}
    if (-not $folder) {
        $text = (Read-SreActsText -RelativePath 'memory\overview.md' -Settings $Settings).TrimEnd() + "`n"
        if ($text.Length -gt $script:NotesBudget) { throw "The seed overview.md is $($text.Length) characters; the agent loads about $script:NotesBudget of it. Shorten config/acts/memory/overview.md." }
        $files['overview.md'] = $text
        return [ordered]@{ source = 'repo'; folder = ''; files = $files }
    }
    if (-not [IO.Path]::IsPathFullyQualified($folder) -or -not (Test-Path -LiteralPath $folder -PathType Container)) { throw 'memory.seedPath must be an existing folder, given as a full path.' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($folder)
    if (($full + [IO.Path]::DirectorySeparatorChar).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'memory.seedPath holds the agent''s notes, which name your resources: keep the folder outside the repository.' }
    $found = @(Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.md' | Where-Object { $_.FullName.Substring($full.Length).TrimStart('\', '/') -notmatch '(^|[\\/])\.' })
    if (-not $found.Count -or $found.Count -gt 40) { throw "memory.seedPath must hold between 1 and 40 .md files; it holds $($found.Count)." }
    foreach ($file in ($found | Sort-Object FullName)) {
        if ($file.Length -gt 65536) { throw "Notes file '$($file.Name)' is over 64 KB." }
        $name = $file.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/'
        # The same rule New-SreNotesArchive applies when the notes are sent, checked here so a preview shows the problem before anything is written.
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$' -or $name.Length -gt 90) {
            throw "Notes file '$name' needs a plain name: letters, digits, '.', '_' and '-' only, in at most 90 characters."
        }
        $files[$name] = ([IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n")
    }
    [ordered]@{ source = 'private'; folder = $full; files = $files }
}

function Get-SreArcRepairScript {
    <#
    .SYNOPSIS
    The repair script the ARC module installs on the Arc server, rendered from config/acts/arc/repair-lob-app.ps1 with LF line endings, and its SHA-256.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $settings = Get-SreActsSettings -Skin $Skin -SubscriptionId $SubscriptionId
    $text = (Read-SreActsText -RelativePath 'arc\repair-lob-app.ps1' -Settings $settings).TrimEnd() + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{ text = $text; sha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant() }
}

function Get-SreActsDesired {
    <#
    .SYNOPSIS
    Everything the ASK, MEMORY, PROACTIVE and ARC modules put on the SRE agent, rendered from the skin and config/acts. $null when the skin turns none on.
    #>
    param([Parameter(Mandatory)][object]$Skin, [Parameter(Mandatory)][string]$SubscriptionId)
    $modules = @(Get-SreActsModules -Skin $Skin)
    if (-not $modules.Count) { return $null }
    if ('PROACTIVE' -in $modules -and -not (Test-SreReleaseScenario -Skin $Skin)) {
        throw 'PROACTIVE scans the ticketing workload, so the skin must also require T12 (docs/proactive-checks.md).'
    }
    if ('ARC' -in $modules) {
        if ('T11' -notin @(Get-DemoSkinValue -Skin $Skin -Path 'sre.requiredScenarios' -Default @())) {
            throw 'ARC repairs the LOB app on the Arc server, so the skin must also require T11 (docs/arc-server-room.md).'
        }
        if ([string]$Skin.sre.accessLevel -cne 'High') {
            throw 'ARC proposes a Run Command, which the agent can only create with the High access profile (Contributor on the Arc group): set sre.accessLevel to High (docs/arc-server-room.md).'
        }
    }
    $settings = Get-SreActsSettings -Skin $Skin -SubscriptionId $SubscriptionId
    $skills = [Collections.Generic.List[object]]::new()
    $agents = [Collections.Generic.List[object]]::new()
    $tasks = [Collections.Generic.List[object]]::new()
    if ('ASK' -in $modules -or 'PROACTIVE' -in $modules) { $skills.Add((Get-SreActsSkill -Folder 'ask' -Name 'estate-query' -Settings $settings)) }
    if ('ARC' -in $modules) { $skills.Add((Get-SreActsSkill -Folder 'arc' -Name 'arc-server-repair' -Settings $settings)) }
    if ('PROACTIVE' -in $modules) {
        foreach ($name in 'estate-health-check', 'bicep-drift-scan', 'governance-deck') { $skills.Add((Get-SreActsSkill -Folder 'proactive' -Name $name -Settings $settings)) }
        foreach ($name in 'estate-auditor', 'deck-builder') { $agents.Add((Get-SreActsAgent -Name $name -Settings $settings)) }
        foreach ($name in 'estate-health-check', 'bicep-drift-scan', 'governance-deck') {
            $task = Get-SreActsTask -Name $name -Settings $settings
            if ($task.agent -notin @($agents | ForEach-Object { $_.name })) { throw "Task $name names an agent ($($task.agent)) this module does not define." }
            $tasks.Add($task)
        }
    }
    [ordered]@{
        modules = $modules; skills = @($skills.ToArray()); agents = @($agents.ToArray()); tasks = @($tasks.ToArray())
        seed = $(if ('MEMORY' -in $modules) { Get-SreActsSeed -Skin $Skin -Settings $settings } else { $null })
        arc = $(if ('ARC' -in $modules) { $repair = Get-SreArcRepairScript -Skin $Skin -SubscriptionId $SubscriptionId; [ordered]@{ settings = (Get-SreArcConfig -Skin $Skin -SubscriptionId $SubscriptionId); repairScript = $repair.text; repairSha256 = $repair.sha256 } } else { $null })
    }
}

Export-ModuleMember -Function Get-SreActsModules, Get-SreActsSettings, Get-SreArcConfig, Get-SreArcRepairScript, Read-SreActsText, Get-SreActsDesired
