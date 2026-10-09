# Azure SRE Agent layer for arc-demo

This repository is the optional **Azure SRE Agent** layer for the separate `arc-demo` repository at `C:\src\arc-demo`. It keeps concerns split: `arc-demo` builds the Arc + Azure Monitor estate and remains fully standalone; this repo attaches an SRE Agent to an already-deployed `arc-demo` environment without redeploying or modifying it.

## What it deploys

- `Microsoft.App/agents` SRE Agent in **Review** mode.
- `incidentManagementConfiguration.type = AzMonitor` so Azure Monitor alerts are the incident source.
- User-assigned managed identity for the agent action and knowledge graph paths.
- Workspace-based Application Insights component for agent diagnostics, linked to the existing arc-demo Log Analytics workspace.
- RBAC on the existing arc-demo Arc/observability and infra resource groups:
  - `High` access (default): Reader + Log Analytics Reader + Contributor for governed Review-mode remediation.
  - `Low` access: Reader + Log Analytics Reader for observe-only demos.

The Bicep follows the `matthansen0/azure-sre-agent-sandbox` `infra/bicep/modules/sre-agent.bicep` pattern and uses the current Microsoft.App/agents Bicep schema.

## Repo layout

```text
infra/
  main.bicep                 # subscription-scope composition and RBAC over existing arc-demo RGs
  modules/sre-agent.bicep    # SRE Agent, identity, and App Insights resources
  modules/role-assignments.bicep # RG-scoped RBAC for the agent identity
scripts/
  Deploy-SreAgent.ps1        # discovers arc-demo IDs and deploys this layer
```

## Prerequisites

1. Existing `arc-demo` deployment from `C:\src\arc-demo` (T07 or later).
2. Same tenant and subscription selected for the lab.
3. Azure CLI 2.60+ and Bicep CLI (`az bicep install`).
4. Permission to create a resource group, managed identity, Application Insights component, `Microsoft.App/agents` resource, and role assignments on the existing arc-demo resource groups.

Default arc-demo names discovered by the script:

| Input | Default discovery |
|---|---|
| Arc/observability RG | `rg-<NamePrefix>` |
| Infra/workload RG | `rg-<NamePrefix>-infra` |
| Log Analytics workspace | `law-<NamePrefix>` in the Arc RG |
| Action Group | `ag-<NamePrefix>` in the Arc RG |
| SRE RG | `rg-<NamePrefix>-sre` |
| Agent name | `sre-<NamePrefix>` sanitized to the SRE Agent naming rules |

## Validate locally

```powershell
cd C:\src\sre-agent
az bicep build --file .\infra\main.bicep
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\scripts\Deploy-SreAgent.ps1', [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

## Deploy against an existing arc-demo environment

Preview first:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -NamePrefix arc-demo `
  -WhatIf
```

Deploy:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -NamePrefix arc-demo
```

If your arc-demo names differ, pass explicit IDs/names instead of relying on discovery:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -ArcResourceGroupName rg-my-arc `
  -InfraResourceGroupName rg-my-arc-infra `
  -LogAnalyticsWorkspaceId /subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/law-my-arc `
  -ActionGroupId /subscriptions/.../providers/Microsoft.Insights/actionGroups/ag-my-arc `
  -AdditionalManagedResourceIds /subscriptions/.../providers/Microsoft.App/containerApps/ca-arc-demo-fault
```

## How it consumes arc-demo

This layer reads the existing arc-demo resource group IDs, Log Analytics workspace ID, and Action Group ID. Those IDs become SRE Agent knowledge graph managed resources. The agent identity receives RBAC on the existing Arc/observability RG (`rg-arc-demo`) and backing workload RG (`rg-arc-demo-infra`) so later scenarios can investigate Azure Monitor alerts and, in Review mode, propose controlled fixes.

No files or resources in `C:\src\arc-demo` are changed by this repo.

## Left for later tasks

- **T09:** pick the Azure-native Container App/AKS alert, connect code context, run the governed closed-loop demo, and capture evidence.
- **T10:** empirically test what SRE Agent can investigate/remediate on Arc-enabled servers via ARM/Arc run-command. Do not promise Arc-server remediation until validated.
