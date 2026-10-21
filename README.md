# Azure SRE Agent layer for arc-demo

This repository is the optional **Azure SRE Agent** layer for the separate `arc-demo` repository at `C:\src\arc-demo`. It keeps concerns split: `arc-demo` builds the Arc + Azure Monitor estate and remains fully standalone; this repo attaches an SRE Agent to an already-deployed `arc-demo` environment without redeploying or modifying it.

The tracked [`config\demo-skin.json`](config/demo-skin.json) and alternative example use fictional organizations. Put real customer/context values in a private skin outside the repo and pass `-SkinPath`; keep `azure.namePrefix` aligned with the Arc skin. Subscription and tenant remain required runtime inputs. External repository context is blank by default; see [`docs\reskin-guide.md`](docs/reskin-guide.md).

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
  - `High` access (default): Reader + Log Analytics Contributor + Contributor, preserving the existing lab profile for governed Review-mode remediation.
  - `Low` access: Reader + Log Analytics Reader for observe-only demos.

The Bicep uses the published [Microsoft.App/agents schema](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents).

## Repo layout

```text
infra/
  main.bicep                 # subscription-scope composition and RBAC over existing arc-demo RGs
  modules/sre-identity.bicep # retained SRE-only user-assigned identity
  modules/sre-agent.bicep    # disposable parent and App Insights, referencing retained identity
  modules/role-assignments.bicep # RG-scoped RBAC for the agent identity
samples/
  lob-arc-app/               # Local T11 app; optional operator-supplied repository context
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

The defaults above are read from the schema-validated skin unless a script parameter
overrides them. Missing or invalid skins fail, rather than silently using another
customer's defaults. Subscription and tenant GUIDs are required on cloud helpers;
requests pass explicit subscription context without changing the global CLI account.
Names are validated rather than silently sanitized when explicitly supplied.

## Handoff safety

Keep tracked examples fictional and real skins/evidence outside the checkout.
Optional source URL/revision must be supplied together; a local-sample demo
requires neither a repository connection nor a fabricated source URL.
`tests\Invoke-Tests.ps1` includes handoff checks for non-example UUIDs, contact
emails, personal home paths and unreviewed repository-owner links. Public Azure
role IDs and synthetic test IDs are deliberately retained.
These checks are not a complete detector of customer context or secrets.
Review all tracked changes and perform a bounded secret check before sharing.
Current-tree cleanup does not rewrite Git history, author metadata, hosting
ownership or prior PR content; those remain separate from the sanitized files.

## Validate locally

```powershell
cd C:\src\sre-agent
.\tests\Invoke-Tests.ps1
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
  -ParentOnly `
  -SkinPath .\config\demo-skin.json
```

If your arc-demo names differ, pass explicit IDs/names instead of relying on discovery:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -ParentOnly `
  -ArcResourceGroupName rg-my-arc `
  -InfraResourceGroupName rg-my-arc-infra `
  -LogAnalyticsWorkspaceId /subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/law-my-arc `
  -ActionGroupId /subscriptions/.../providers/Microsoft.Insights/actionGroups/ag-my-arc `
  -AdditionalManagedResourceIds /subscriptions/.../providers/Microsoft.App/containerApps/ca-arc-demo-fault
```

## How it consumes arc-demo

This layer reads the existing arc-demo resource group IDs, Log Analytics workspace ID, and Action Group ID. Those IDs become SRE Agent knowledge graph managed resources. The agent identity receives RBAC on the existing Arc/observability RG (`rg-arc-demo`) and backing workload RG (`rg-arc-demo-infra`) so later scenarios can investigate Azure Monitor alerts and, in Review mode, propose controlled fixes.

No files or resources in `C:\src\arc-demo` are changed by this repo.

### Complete Ready state

`-ParentOnly` explicitly acknowledges that Bicep deploys only the control plane.
For complete parent-plus-configuration deployment supply a new
`-ConfigurationBackupPath` outside git. For an already running parent, use
`Initialize-SreConfiguration.ps1 -Inspect`, then separately authorized `-Apply
-BackupPath <NEW_PATH>`; existing legacy plans also require `-AllowLegacyMigration`.
The [current-schema procedure](docs/sre-response-plan-automation.md) uses pinned
Microsoft IaC template protocols for full reads, named upserts and verification.
Do not use the legacy MCP `severity: high` recipe: it creates invalid AzMonitor
P1/P2 and response-level settings. Current plans use exact Sev2, explicit Review,
and instructions/tools on the handling custom agent. No parent deletion is needed.
Default v3 routes are staged disabled before explicitly retired v2 routes are
disabled; only then are v3 routes enabled. Old objects/history remain. The
unsupported existing legacy-handler update path is blocked before any write.

Run `Test-SreReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
-SkinPath .\config\demo-skin.json -DesiredState Ready -OutputFormat Json`.
It is read-only and bounded (`-TimeoutSeconds`, default 180). The common Arc/SRE
contract uses `pass|fail|pending|skipped`, with exit 0 pass, 1 fail/error, 2 pending.
It checks parent/Review/identity/RBAC/managed resources/scenario resource health
and reads full handler/plan/legacy-settings/routing configuration. Invalid
priorities or legacy settings fail explicitly. The command does not ingest
external rehearsal evidence: `telemetry-and-alerts` always remains pending in
Ready mode, even after a separately proven run. Pair the JSON/exit 2 with that
run's evidence; do not modify the report to manufacture exit 0.
Parent success is never a routing-readiness certificate.

Required scenarios come from `sre.requiredScenarios` (default T09/T11). Deployment
adds their explicit Container App/Arc IDs to managed resources. Bicep role names
include the identity principal; existing same-principal names are adopted.
Incremental deployments cannot revoke permissions: a Low downgrade with an
existing incompatible write grant fails until a separately approved cleanup.
An existing Monitoring Contributor grant is tolerated in High for demo compatibility,
not created by the standard profile. Low uses the actual Log Analytics Reader ID;
the previous template mislabeled Log Analytics Contributor as Reader.
User, service-principal and managed-identity deployers are supported through
`-DeployerPrincipalType` inference/override.

## Off state / reactivate

Azure SRE Agent currently has no stopped/deallocated state. Because the agent has
an always-on charge, normal parking removes the parent and known diagnostics,
but **retains the dedicated SRE group and its SRE-only UAMI**. Known UAMI workload
grants and the direct parent administrator grant are removed. Other identities'
external grants and the Arc estate stay intact. Unexpected resources or grants
block deletion; normal parking never deletes the group or UAMI.

```powershell
# Only after approved parent removal; export configuration/evidence and
# save the live identity principal first. See the complete lifecycle procedure:
# docs\sre-response-plan-automation.md
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -WhatIf

# Execute only the approved preview.
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json

# Submission is asynchronous; repeat this read-only check within a bounded
# observation window until pass, or report pending/failure without resubmitting.
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Hibernated `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -OutputFormat Json

# Before the next demo — rebuild the parent using the retained identity
# First reactivate and verify Arc through its own repo.
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -ParentOnly `
  -SkinPath .\config\demo-skin.json
```

Verify SRE hibernation before parking Arc; wake Arc before reconstructing SRE.
Reactivation also requires modern handler/v3-plan ensure and verification above,
with a new external backup path and approval for actual changes.
Deletion loses custom agents, response plans, thread/incident history, memory and
connector state. Code-repository authorization is optional and must be explicitly
re-established; a URL in the skin is not authentication. Save the retained identity
principal and use readiness `-DesiredState Hibernated
-PreviousIdentityPrincipalId <ID>` to verify external grant cleanup. Missing
identity/partial state is safe to inspect, but an absent UAMI (including historical
whole-group deletion) fails the new identity-retained Hibernated contract.
WhatIf never selects a global account, revokes grants or writes a
guest script.
The saved Inspect export is a reference, not a replayable history/connector
backup. The retained UAMI principal and deterministic workload assignment IDs
are reused on wake; deployment creates it only on the first deployment or after
separate full deletion. The parent keeps its validated combined identity shape:
its system-assigned principal still changes when the parent is recreated and is
not granted these external workload roles. Never reactivate retired legacy v2 handlers.
Versioned filters explicitly restore enabled three-hour cooldown and Review/Sev2.
A fresh retained-identity park/wake round trip has not been live-tested by the
T09 rehearsal. Residual Arc/storage/monitoring
charges remain until their own lifecycle actions; this is not a zero-cost claim.

The [managed identity itself has no extra cost](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
Retaining an identity is not retaining Contributor access: normal parking revokes
its grants, then incremental IaC restores the same deterministic IDs on wake.
The separate identity module owns it in the same SRE group, so first creation and
future reuse follow identical IaC without an extra identity group or manual identity.
Full removal of the retained group/identity requires separate explicit approval;
`Hibernate-SreAgent.ps1` deliberately has no group/identity deletion path.

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

The approved current-schema cutover was read-back verified: modern v3 routes
enabled with Review/Sev2, old v2 routes disabled, handlers/history retained, and
repeat inspection reporting zero changes. Title-only edits were insufficient.
The separately authorized fresh T09 retry on 2026-10-20 verified the restart
metric, new Azure Monitor alert, independent v3 Review investigation, concrete
RCA and **SRE-executed repair**. The user reported approving the exact new reset
card; the matching tool completion and Activity Log independently attribute the
write to the SRE managed identity. The app recovered to a healthy ready revision,
100% traffic and HTTP 200 with **zero operator fallback writes**. The original
cooldown was restored. The earlier rehearsal's operator fallback is a distinct
outcome, not the repair evidence for this retry.
Actual MonitorCondition resolved at 01:45:58 UTC; the separate alert workflow
state remained Acknowledged.

The bounded audit did not return an independent `ApprovalDecision` event; retain
that evidence limit rather than inventing one. Read actual MonitorCondition
recovery separately from the agent closing an alert. Do not infer approval or
execution from narration, approve an old card, or repeat a consumed one-shot
fault authorization.

- **T09 Container App:** live validated end to end with Azure Monitor handoff, SRE RCA, Review approval, SRE-executed repair, app recovery and actual MonitorCondition recovery.
- **T10 Arc server:** live validated for SRE-assisted diagnosis and Arc Run Command viability. Autonomous / SRE-executed Arc server repair is **not currently demo-ready**; treat it as possible future capability.
- **T11 LOB app on Arc:** live validated for Arc app fault signal, Log Analytics Event ID `4100`, Azure Monitor alerting, SRE incident creation, and operator Arc Run Command recovery. In the latest run, SRE RCA generation stalled before final diagnostic output, so do not present T11 as a proven SRE RCA or autonomous Arc app repair path. The sample is local; optionally provide your own source repository and commit.
