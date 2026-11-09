# T09: Azure-native Container App incident (the closed loop)

Run one incident and watch the agent work: a Container App crashes, Azure Monitor
alerts, the SRE agent investigates and proposes a fix, you approve it in the SRE
portal, and the app recovers. Present from the generated
`.local/presenter-runsheet.md`; this page is the runbook for the incident itself.
Ask your AI tool to run it for you, or follow it yourself. Either way, you click
**Approve** in the SRE portal (step 7).

**Already built the SRE layer?** If you built with the Arc build wrapper and this
repo's `Deploy-SreAgent.ps1` (with `-ConfigurationBackupPath`) and kept the default
`T09` scenario, steps 1 to 4 below are already done: the build needed the Container
App, created the agent, applied the Review plans and read them back, and step 3 is
optional. Don't repeat steps 1 and 2: the Arc estate already has the app, and Deploy
refuses an existing parent. Once `Test-SreReadiness.ps1 -DesiredState Active`
passes, start at step 5, which defines the variables the later steps use.

A 2026-10-20 retry showed the whole loop: a new Sev2 alert, an independent v3
Review investigation, your approval of the exact `SIMULATE_CRASH=false` card, and
the repair executed by the SRE managed identity (matching tool completion and Azure
Activity Log), with the app healthy afterwards (ready revision, one replica, 100%
traffic, HTTP 200) and no manual reset. Approval evidence for that run was the
report of clicking the card, because the bounded audit returned no independent
`ApprovalDecision` event. On the rebuilt agent (2026-11-05) the alert,
thread and Review card were confirmed, but a clean in-window repair is not yet
proven: see
[what the live proof established](sre-response-plan-automation.md#live-lifecycle-proof-2026-11-05).
Connecting a source-code repository is optional and was not captured.

## What it does

1. Deploy `arc-demo` with `-DeployContainerApps $true`.
2. Deploy this SRE Agent layer against the existing `arc-demo` resources.
3. Optionally connect your own code repository for RCA context.
4. Check the Review-mode response plan.
5. Induce the fault: enable `SIMULATE_CRASH=true` on the Container App.
6. Observe the investigation: the Azure Monitor `RestartCount` alert fires and Azure
   SRE Agent investigates and produces an RCA.
7. Approve the proposed Review-mode Azure fix.
8. Verify recovery.
9. Show the audit trail.

The numbers match the numbered steps below.

## Resource map

Default names assume `-NamePrefix arc-demo`.
For reskinned demos, keep `azure.namePrefix` aligned across both repos and pass
`-SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json`; see [`reskin-guide.md`](reskin-guide.md).

| Resource | Default name | Resource group | Purpose |
|---|---|---|---|
| Container App | `ca-arc-demo-fault` | `rg-arc-demo-infra` | Tiny HTTP app with `SIMULATE_CRASH` env-var fault |
| Container Apps environment | `cae-arc-demo` | `rg-arc-demo-infra` | Hosts the app |
| Metric alert | `alert-arc-demo-containerapp-restarts` | `rg-arc-demo-infra` | Fires when `RestartCount` total is greater than 0 in 5 minutes |
| Action Group | `ag-arc-demo` | `rg-arc-demo` | Existing alert seam consumed by SRE Agent |
| SRE Agent | `sre-arc-demo` | `rg-arc-demo-sre` | Review-mode agent with Azure Monitor incident source |

## Prerequisites

- Azure CLI 2.60+ signed in to your tenant and subscription; pass
  the subscription on every request rather than relying on ambient selection.
- The current companion Arc source with its optional Container App workload enabled,
  plus this SRE source.
- Permission to deploy `arc-demo`, deploy this SRE Agent layer, create role assignments, and approve SRE Agent actions.
- SRE Agent response plan set to **Review** mode. Review mode is required for the one-click **Approve** step.
- Optional: connect
  your own Arc companion repository as a source-code repository in the SRE Agent knowledge
  base (you sign in to the provider) so RCA can cite:
  - `bicep/modules/container-apps.bicep`
  - `docs/container-app-fault.md`

References used for this runbook: Azure SRE Agent overview, run modes, incident response, response plans, source-code connection, execute mitigations, Azure Container Apps environment variables, and Container Apps `RestartCount` metrics on Microsoft Learn.

## 1. Deploy arc-demo with the Container App workload

Sign in to your tenant yourself first with `az login --tenant <TENANT_ID>`. If an
AI tool is driving, it asks you to do this and waits rather than running it.

```powershell
# Run from the companion Arc checkout.

.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -DeployContainerApps $true
```

Capture the resource IDs for the SRE Agent knowledge graph:

```powershell
$subscriptionId = '<SUBSCRIPTION_ID>'
$tenantId = '<TENANT_ID>'
$namePrefix = 'arc-demo'
$arcRg = "rg-$namePrefix"
$infraRg = "rg-$namePrefix-infra"
$containerAppName = "ca-$namePrefix-fault"
$alertName = "alert-$namePrefix-containerapp-restarts"

$containerAppId = az containerapp show `
  --subscription $subscriptionId `
  --resource-group $infraRg `
  --name $containerAppName `
  --query id `
  --output tsv

$containerAlertId = az monitor metrics alert show `
  --subscription $subscriptionId `
  --resource-group $infraRg `
  --name $alertName `
  --query id `
  --output tsv
```

## 2. Deploy the SRE Agent layer

```powershell
# Run from the SRE checkout.

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -ParentOnly `
  -ApproveParentCreation `
  -GrantAzureMonitorAlertAccess `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($containerAppId, $containerAlertId)
```

`High` access assigns Contributor to the agent identity on the existing `arc-demo` resource groups. The agent still runs in Review mode, so write actions need your approval. `-ParentOnly` means this deploy doesn't complete the data-plane setup below; `-ApproveParentCreation` confirms you want to start the paid AAU meter; `-GrantAzureMonitorAlertAccess` confirms the one subscription role assignment the agent needs to read Azure Monitor alerts, and readiness fails without it. For a demo that is already running, don't redeploy: run readiness and check the existing configuration first.

## 3. Connect code context (optional)

This needs you to sign in to the repository provider. The current
[source-code connection guide](https://learn.microsoft.com/azure/sre-agent/connect-source-code)
documents the existing-agent path below; authenticated controls were not observed
in this documentation review. Skip this entirely for the default local-sample demo.

1. Open `sre-arc-demo`.
2. If the documented layout is visible, go to **Builder** > **Knowledge base**.
3. Select the **Add repository** action card.
4. Choose GitHub or Azure DevOps authentication.
5. Add your own Arc companion repository URL.
6. Confirm the repository card shows **Connected**.

Expected RCA context: the agent should be able to point at the `SIMULATE_CRASH` startup script in `bicep/modules/container-apps.bicep` and the manual commands in `docs/container-app-fault.md`.

## 4. Check the Review-mode response plan

The supported pinned automation path and its capability boundaries are tracked in
[`sre-response-plan-automation.md`](sre-response-plan-automation.md). The short
version: render desired configuration with `Initialize-SreConfiguration.ps1`;
list and inspect existing plans and the custom handler first. Create only when
absence is verified. After an ambiguous timeout read back before retrying.
The initializer uses pinned Microsoft IaC template protocols for full handler and
plan reads/upserts. Do not use legacy MCP `severity: high`: it creates invalid
AzMonitor P1/P2 and response-level instructions, and an `OR` expression is
literal title text. Existing legacy configuration
is refused rather than migrated; use the automation doc's supported fallback.
Use backup/preview/apply/verify for fresh or existing modern configuration.

Use the supported initializer, not a guessed create wizard, for configuration.
The required read-back is the skin-rendered custom agent with its explicit four
built-in tools, and `container-app-restart-review-v3`: Azure Monitor, Sev2, literal
`containerapp-restarts`, intended handling agent, On, Review and enabled
three-hour cooldown. No duplicate quickstart match or active legacy handler is
allowed. If you find a conflict, resolve it before changing anything else.

For read-only presentation, the [SRE guide source](delivery-runsheet.md) describes
the documented response-plan view and keeps navigation read-only. It does not
claim every authenticated layout was observed. Don't create, save or toggle a
plan merely to rehearse or replace a missing investigation.

The current reproducible setup path: render and inspect with
`Initialize-SreConfiguration.ps1`, read its exact changes, then apply with a new
external backup path. For legacy state stop and use the canonical supported
fallback. Verify the full read-back before you run an incident. Portal operation
is optional, not the only automation path.

## 5. Induce the fault

Define the variables that steps 5 to 9 use, then use the helper script to create a
new crashing revision. If your shell doesn't keep variables between commands,
define them again before each later block.

```powershell
# Run from the SRE checkout.
$subscriptionId = '<SUBSCRIPTION_ID>'
$tenantId = '<TENANT_ID>'
$containerAppId = az containerapp show `
  --subscription $subscriptionId `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --query id `
  --output tsv

.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -State Break `
  -ShowMetrics
```

Equivalent raw command:

```powershell
az containerapp update `
  --subscription $subscriptionId `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=true
```

Wait 5-10 minutes. The alert evaluates every 5 minutes over a 5-minute window and fires when `RestartCount` total is greater than 0.

## 6. Observe the SRE investigation

Expected SRE Agent thread evidence:

- Incident source is Azure Monitor.
- Alert/resource is `alert-arc-demo-containerapp-restarts` on `ca-arc-demo-fault`.
- `RestartCount` is elevated.
- The latest revision contains `SIMULATE_CRASH=true`.
- RCA identifies the startup script intentionally exits when the env var is true.
- If code context is connected, RCA includes file references to the fault mechanism and/or runbook.

Decide up front how long you will wait. A 20-minute deadline after the fault
worked (the Review card appears about 7 to 10 minutes after the fault). If
nothing is approved by then, or on any error or timeout, reset the app yourself
with `Invoke-NativeContainerAppFault.ps1 -State Repair` (see step 7) and call it a
manual reset, not agent repair. Don't extend the deadline while waiting for the
agent, and don't fire the fault again to make up for a missed approval.

For a repeat run, first check the actual plan's **Reinvestigation
cooldown**. Enabled cooldown merges recurring fires into the existing
investigation and reopens resolved threads during the configured window; a
resolved alert does not guarantee a new thread or approval card. The current
demo plan uses the three-hour window. Don't change this setting or replay an
old request merely to obtain a fresh approval. If you change it temporarily, back
up its state first and restore it exactly.
See [Azure Monitor reinvestigation cooldown](https://learn.microsoft.com/azure/sre-agent/response-plan).

## 7. Approve the governed fix

Before you fire the fault, sign in to `https://sre.azure.com`, select the
configured agent and open it once, letting its welcome thread finish: the first
visit to a fresh agent starts that thread and spends agent usage, and it should
not run beside the incident. Then be ready to open the new incident investigation.
Expand the actual Azure infrastructure operation card, not just the RCA prose.

Observed path on the rebuilt agent: choose **Incidents** in the left sidebar. Its
**Incidents** tab shows **Azure Monitor is connected**, and its **Agent status**
column and tiles summarize each incident (including **Pending user input**; that
a waiting Review card shows there was not captured). Select the alert title link
to open the thread, where the proposed change is an **Updating Azure resource**
card with a risk label and the full command. From Learn, not captured before the
click: Azure infrastructure operations show **Approve** and **Deny** to an SRE
Agent Administrator, and the thread's **...** menu has **Copy link to thread**.
If the live controls differ, use what is visible and do not guess.

The proposed write is also visible without the portal: it is a thread message
whose `azCliExecution.status` is `Pending`, while the approvals endpoint can stay
empty for this card type.
[The presenter guide's optional incident step](delivery-runsheet.md#6-optional-one-live-incident)
needs the current run's exact card.
An Azure Monitor alert state or chat message cannot approve that card.
Confirm the current thread, affected app, resource group, subscription and
complete command before you click. Narration such as "approved" or "applying" is
not an approval record. If there is no actual card, don't send an approval message
or enable Autonomous mode as a substitute.

In the SRE Agent thread, the desired Review-mode action is:

```powershell
az containerapp update `
  --subscription $subscriptionId `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

Select **Approve** only for that reset on the current run's operation card. Only an
SRE Agent Administrator can approve the action. If the agent proposes a different
write, don't approve it.

If you would rather not wait, or SRE remediation isn't available, reset the app
yourself:

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -State Repair `
  -ShowMetrics
```

If you do this, call it a "manual reset"; don't claim closed-loop SRE remediation.
Don't approve the old pending repair card afterwards. It stays Pending and
approvable: in the first rebuilt run it was approved 21 minutes after the manual
reset and the agent's write ran as a no-op on the already repaired app, but the
same click on a non-idempotent proposal would change Azure after you had already
acted. Deny the obsolete card at once, or leave it alone. Don't infer action-card
status from thread narration.

## 8. Verify recovery

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -State Status `
  -ShowMetrics

$fqdn = az containerapp show `
  --subscription $subscriptionId `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --query properties.configuration.ingress.fqdn `
  --output tsv

curl.exe "https://$fqdn"
```

Expected result:

- `SIMULATE_CRASH=false`
- new revision becomes healthy
- app endpoint returns HTTP 200
- `RestartCount` stops increasing
- Azure Monitor condition resolves after its healthy evaluation window; read it
  separately from app recovery and alert workflow state. This run took about
  17 minutes after the SRE write, not one immediate evaluation. Do not force-close
  an alert or change its rule just to manufacture a pass.

Don't infer an outage from zero request-volume metrics alone: use revision and log
evidence for the crash and an actual HTTP probe for availability.

## 9. Show the audit trail

Use three evidence points:

1. SRE Agent investigation thread: RCA, proposed command, **Approve** action, execution result, verification.
2. Azure Activity Log for the Container App write:

   ```powershell
   az monitor activity-log list `
     --subscription $subscriptionId `
     --resource-id $containerAppId `
     --offset 2h `
     --query "[?operationName.value=='Microsoft.App/containerApps/write'].{time:eventTimestamp,caller:caller,status:status.value,operation:operationName.value}" `
     --output table
   ```

3. Azure Monitor alert history showing fired and resolved states for `alert-arc-demo-containerapp-restarts`.

For independent supported tool and routing evidence, open the agent's
**Monitor > Logs** and query its Application Insights resource:

```kusto
customEvents
| where timestamp > ago(2h)
| where tostring(customDimensions.ThreadId) == "<CURRENT_THREAD_ID>"
| where name in ("AgentToolExecution", "ApprovalDecision",
    "AgentAzCliExecution", "IncidentActivitySnapshot")
| project timestamp, name, customDimensions
| order by timestamp asc
```

`ToolStart` confirms a request and its exact input, not completed execution.
Correlate its `CallId` with `ToolEnd`, any `ApprovalDecision`, the actual Azure
write caller and recovery. On the rebuilt agent no `ApprovalDecision` appeared, but
the Azure CLI execution record (`AgentAzCliExecution`) of the approved command
carried a `User` matching the portal user, which attributes the approver. `IncidentActivitySnapshot` records the
`ResponsePlanId`, mode and assisted/mitigated outcome. Absence of an event in a
bounded query is not authoritative current approval-card state.
See [Audit agent actions](https://learn.microsoft.com/azure/sre-agent/audit-agent-actions).
