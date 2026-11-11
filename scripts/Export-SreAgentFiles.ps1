#Requires -Version 7.4
<#
.SYNOPSIS
    Lists or downloads files from the SRE agent's workspace: its notes (what it learned), or the files it built for one thread, such as the governance deck.

.DESCRIPTION
    -Source Notes    The agent's memory folder. Parking the agent (Hibernate-SreAgent.ps1) deletes the notes with it, so export them first if you want
                     to keep them. A later build can start from them: put the exported synthesizedKnowledge folder in memory.seedPath of your private
                     skin, and the apply seeds it into the new agent's empty notes folder (docs/it-remembers.md).
    -Source Thread   The files the agent saved for one thread (-ThreadId), for example governance-review.pptx.
    -List            Only lists what is there (path, size, modified). Nothing is written.

    Files are written under -OutputPath, which must be outside the repository: the notes name your resources. An existing file is never overwritten.
    The agent's file API can only list and read, so there is no clear or delete here: starting from empty notes means parking and rebuilding the agent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Notes', 'Thread')]
    [string]$Source,

    [ValidatePattern('^[A-Za-z0-9_.:-]+$')]
    [string]$ThreadId,

    [string]$OutputPath,

    [switch]$List,

    [string]$SkinPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreDataPlane.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreActsExtras.psm1') -Force

if ($Source -eq 'Thread' -and -not $ThreadId) { throw 'Say which thread with -ThreadId (a scheduled task run prints it).' }
if (-not $List -and -not $OutputPath) { throw 'Give -OutputPath (a folder outside the repository), or use -List.' }
$output = if ($List) { $null } else { Resolve-SreExportPath -OutputPath $OutputPath }

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$context = New-SreDataContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName "rg-$($skin.azure.namePrefix)-sre" -AgentName ([string]$skin.labels.agentName)
$folder = if ($Source -eq 'Notes') { "$(Get-SreWorkspaceRoot)/memories" } else { "$(Get-SreWorkspaceRoot)/tmp/ThreadFiles/$ThreadId" }
$result = Export-SreAgentFolder -Context $context -Folder $folder -OutputPath $output -List:$List
if (-not $result.exists) {
    Write-Host "Nothing to export: $(if ($Source -eq 'Notes') { 'the agent has no notes yet' } else { "thread $ThreadId has no files" })."
    return
}
if ($List) {
    foreach ($file in $result.files) { Write-Host ("{0,8} bytes  {1}  {2}" -f $file.size, $file.modified, $file.relativePath) }
    Write-Host "$($result.files.Count) file(s) under $Source."
    return $result.files
}
if (-not $result.files.Count) { Write-Host 'The folder exists but holds no files.'; return }
Write-Host "Exported $($result.written) file(s), $($result.bytes) bytes, to $output$(if ($result.skipped) { " ($($result.skipped) already there)" })."
