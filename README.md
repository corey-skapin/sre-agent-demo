# Azure SRE Agent layer for arc-demo

This repository is the optional **Azure SRE Agent** layer for the separate `arc-demo` repository at `C:\src\arc-demo`. It keeps concerns split: `arc-demo` builds the Arc + Azure Monitor estate and remains fully standalone; this repo attaches an SRE Agent to an already-deployed `arc-demo` environment without redeploying or modifying it.

Customer-specific values live in [`config\demo-skin.json`](config/demo-skin.json). Keep `azure.namePrefix` aligned with the Arc repo's skin, then use `-SkinPath` on the scripts; see [`docs\reskin-guide.md`](docs/reskin-guide.md).

## Start here

- **AI coding assistants:** read [`AGENTS.md`](AGENTS.md) first.
- **Presenter runthrough:** use [`docs\delivery-runsheet.md`](docs/delivery-runsheet.md), then branch to the scenario docs it names.
- **Setup/repair SRE response plans:** use [`docs\sre-response-plan-automation.md`](docs/sre-response-plan-automation.md).
- **Do not use every doc as a presenter script.** Several files under `docs\` are engineering evidence or historical runbooks.

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
  lob-arc-app/               # Local copy of the T11 app; public source context lives in arc-demo samples/lob-arc-app
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
- `docs\ai-deploy-handbook.md` - Prompt and checklist for AI-assisted deployment by another SE.
- `docs\sre-sales-rollout-guidance.md` - Internal sales, PoC and rollout guidance for SRE Agent conversations.
- `docs\clean-room-shareability-test-2026-10-12.md` - No-cost clean-room preview result across both repos.
- `docs\t09-native-containerapp-closed-loop.md` - Azure-native Container App loop.
- `docs\sre-response-plan-automation.md` - Decision record for automating custom agents and response plans.
- `docs\t10-sre-on-arc-experiment.md` - Arc-server assisted diagnostics and operator remediation experiment.
- `docs\t11-hybrid-diagnostics-wow.md` - Customer-facing hybrid diagnostics wow scene for LOB-on-Arc.
- `docs\t11-lob-app-on-arc-bridge.md` - Engineering evidence ledger for the LOB app running on an Arc server; not the current presenter source-of-truth.
- `docs\reskin-guide.md` - Skin variables schema, swap-list, and retargeting steps.

## Current validation stance

- **T09 Container App:** live validated end to end with Azure Monitor handoff, SRE RCA, Review approval, SRE-executed repair, recovery, and alert closure.
- **T10 Arc server:** live validated for SRE-assisted diagnosis and Arc Run Command viability. Autonomous / SRE-executed Arc server repair is **not currently demo-ready**; treat it as possible future capability.
- **T11 LOB app on Arc:** live validated for Arc app fault signal, Log Analytics Event ID `4100`, Azure Monitor alerting, SRE incident creation, and operator Arc Run Command recovery. In the latest run, SRE RCA generation stalled before final diagnostic output, so do not present T11 as a proven SRE RCA or autonomous Arc app repair path. Public code context now lives in `corey-skapin/arc-demo`.
