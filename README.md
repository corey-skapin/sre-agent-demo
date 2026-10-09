# Azure SRE Agent layer for arc-demo

This repository is the optional **Azure SRE Agent** layer for the separate `arc-demo` repository at `C:\src\arc-demo`. It keeps concerns split: `arc-demo` builds the Arc + Azure Monitor estate and remains fully standalone; this repo attaches an SRE Agent to an already-deployed `arc-demo` environment without redeploying or modifying it.

Customer-specific values live in [`config\demo-skin.json`](config/demo-skin.json). Keep `azure.namePrefix` aligned with the Arc repo's skin, then use `-SkinPath` on the scripts; see [`docs\reskin-guide.md`](docs/reskin-guide.md).

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
samples/
  lob-arc-app/               # T11 sample app to publish as its own code repo for RCA context
scripts/
  Deploy-SreAgent.ps1        # discovers arc-demo IDs and deploys this layer
  Invoke-LobArcAppOnArc.ps1  # deploys/operates the T11 LOB app on a Windows Arc server
  New-LobArcAppMonitorAlert.ps1 # creates or prints the T11 log alert signal
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

The defaults above are read from the skin file unless a script parameter overrides them.

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
  -SkinPath .\config\demo-skin.json `
  -WhatIf
```

Deploy:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
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

## Off state / reactivate

Azure SRE Agent currently has no stopped/deallocated state. Because the agent has
an always-on charge, the off-state for this optional repo removes only the SRE
Agent resource group and its RBAC grants on the Arc demo resource groups. The
Arc demo estate stays intact.

```powershell
# After a demo — removes the optional SRE layer only
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json

# Before the next demo — recreate the optional SRE layer
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
```

## Scenario runbooks

- `docs\delivery-runsheet.md` - Three-act Arc + Monitor + SRE delivery storyboard across both repos.
- `docs\t09-native-containerapp-closed-loop.md` - Azure-native Container App loop.
- `docs\t10-sre-on-arc-experiment.md` - Arc-server investigation/remediation experiment.
- `docs\t11-lob-app-on-arc-bridge.md` - LOB app running on an Arc server with its own code context.
- `docs\reskin-guide.md` - Skin variables schema, swap-list, and retargeting steps.

## Left for later tasks

- **Live lab validation:** Do not promise live SRE remediation for T09-T11 until lab evidence is captured.
- **T14:** EDE PoC datasheet remains deferred.
