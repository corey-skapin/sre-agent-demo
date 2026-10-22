#Requires -Version 7.4
<#
.SYNOPSIS
Explicitly removes the SRE-owned layer, including retained identity and known grants.
.DESCRIPTION
Uses the same target/ownership safeguards as Hibernate, with stricter full-removal
inventory. Shared Arc groups, workspace, alerts and private exports are never deleted.
Save the identity principal before removal for repeatable Removed verification.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$NamePrefix,
    [string]$SreResourceGroupName,
    [string]$AgentName,
    [string]$ArcResourceGroupName,
    [string]$InfraResourceGroupName,
    [string]$SkinPath,
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PreviousIdentityPrincipalId,
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Hibernate-SreAgent.ps1') @PSBoundParameters -DesiredState Removed
