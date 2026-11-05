# T09 — Azure-native Container App closed-loop SRE runbook

**Operator reference, not the presenter script.** Start with
[the docs map](README.md), then use the generated `.local/presenter-runsheet.md`.
The historical 2026-10-20 instance validated v3 Review routing and the
alert/RCA/approval/repair/recovery path. The replacement instance's reconstructed
configuration was verified, but a new end-to-end rehearsal was not performed.
Nothing below authorizes a new fault or certifies current readiness.
Source-code repository connection is optional and was not captured.

For AI-led preparation after activation, the SRE-owning assistant follows
[the once-only conversational incident offer](ai-deploy-handbook.md#post-activation-incident-offer).
After your scoped yes, it runs this existing procedure and recovery fallback
for you; only the actual SRE Review operation requires your separate human
approval in its supported UI. A no skips the incident without changing activation.

Latest current-schema retry (2026-10-20): a separately authorized fault generated
a new Sev2 alert and independent v3 Review investigation. The user reported
approving the exact new `SIMULATE_CRASH=false` card. Matching tool completion and
Azure Activity Log prove that the SRE managed identity, not the operator,
executed the repair. Revision `0000028` became healthy/ready with one replica,
100% traffic and HTTP 200; the guard issued no operator reset. Its temporary
cooldown disable was restored to the original three-hour setting.
MonitorCondition resolved at 01:45:58 UTC, observed at 01:46:38 UTC; the separate
alert workflow state remained Acknowledged.

The earlier run used an operator fallback and is a separate outcome. The bounded
audit did not return an independent `ApprovalDecision` event, so approval evidence
is the user's actual portal report, not a fabricated telemetry record or the
agent's narration. Read actual MonitorCondition recovery separately from alert
workflow closure. Do not infer an outage from zero request-volume metrics alone;
use revision/log evidence for the crash and an actual HTTP probe for availability.

This runbook demonstrates the Azure-native "wow" loop on the optional `arc-demo` Container App workload:

1. deploy `arc-demo` with `-DeployContainerApps $true`
2. deploy this SRE Agent layer against the existing `arc-demo` resources
3. enable `SIMULATE_CRASH=true` on the Container App
4. let the Azure Monitor `RestartCount` alert fire
5. let Azure SRE Agent investigate and produce RCA
6. approve the proposed Review-mode Azure fix
7. verify recovery and show the audit trail

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

- Azure CLI 2.60+ authenticated to the explicit target tenant/subscription; pass
  the subscription on every request rather than relying on ambient selection.
- Current companion Arc source with its optional Container App workload enabled,
  plus this SRE source, not historical task-number release prerequisites.
- Permission to deploy `arc-demo`, deploy this SRE Agent layer, create role assignments, and approve SRE Agent actions.
- SRE Agent response plan set to **Review** mode. Review mode is required for the one-click **Approve** step.
- Optional, after separate explicit authentication/consent: connect
  your own Arc companion repository as a source-code repository in the SRE Agent knowledge
  base so RCA can cite:
  - `bicep/modules/container-apps.bicep`
  - `docs/container-app-fault.md`

References used for this runbook: Azure SRE Agent overview, run modes, incident response, response plans, source-code connection, execute mitigations, Azure Container Apps environment variables, and Container Apps `RestartCount` metrics on Microsoft Learn.

## 1. Deploy arc-demo with the Container App workload

```powershell
# Run from the companion Arc checkout.

az login --tenant <TENANT_ID>

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
  -AccessLevel High `
  -AdditionalManagedResourceIds @($containerAppId, $containerAlertId)
```

`High` access assigns Contributor to the agent identity on the existing `arc-demo` resource groups. The agent still runs in Review mode, so write actions require approval. `-ParentOnly` explicitly acknowledges that this deploy does not complete the data-plane setup below; `-ApproveParentCreation` acknowledges that creation starts the paid AAU meter. For an already running demo, do not redeploy merely to rehearse: use read-only readiness and verify the existing configuration first.

## 3. Connect code context

Optional setup only, after separate authentication/connector authorization.
The current [source-code connection guide](https://learn.microsoft.com/azure/sre-agent/connect-source-code)
documents the existing-agent path below; authenticated controls were not observed
in this documentation review. Skip this entirely for the default local-sample demo.

1. Open `sre-arc-demo`.
2. If the documented layout is visible, go to **Builder** > **Knowledge base**.
3. Select the **Add repository** action card.
4. Choose GitHub or Azure DevOps authentication.
5. Only after explicit authorization, add your own Arc companion repository URL.
6. Confirm the repository card shows **Connected**.

Expected RCA context: the agent should be able to point at the `SIMULATE_CRASH` startup script in `bicep/modules/container-apps.bicep` and the operator commands in `docs/container-app-fault.md`.

## 4. Create the Review-mode response plan

The supported pinned automation path and its capability boundaries are tracked in
[`sre-response-plan-automation.md`](sre-response-plan-automation.md). The short
version: render desired configuration with `Initialize-SreConfiguration.ps1`;
list and inspect existing plans and the custom handler first. Create only when
absence is verified. After an ambiguous timeout read back before retrying.
The initializer uses pinned Microsoft IaC template protocols for full handler and
plan reads/upserts. Do not use legacy MCP `severity: high`: it creates invalid
AzMonitor P1/P2 and response-level instructions. Existing legacy configuration
is refused rather than migrated; use the automation doc's supported fallback.
Use backup/preview/apply/verify for fresh or existing modern configuration.

Use the supported initializer, not a guessed create wizard, for configuration.
The required read-back is the skin-rendered custom agent with its explicit four
built-in tools, and `container-app-restart-review-v3`: Azure Monitor, Sev2, literal
`containerapp-restarts`, intended handling agent, On, Review and enabled
three-hour cooldown. No duplicate quickstart match or active legacy handler is
allowed. Report conflicts and obtain scoped authorization before changes.

For read-only presentation, the [SRE guide source](delivery-runsheet.md) describes
the documented response-plan view and keeps navigation read-only. It does not
claim every authenticated layout was observed. Do not create, save or toggle a
plan merely to rehearse or replace a missing investigation.

### Historical F04 setup status - not a deployment recipe

Validated state on 2026-10-12:

- `sre-arc-demo` was running in `rg-arc-demo-sre` with Review mode and High access.
- The required custom handling agent could not be created through MCP during the first pass, but portal creation through **Builder** > **Agent Canvas** succeeded.
- After the portal custom agent existed, the response plan `container-app-restart-review-v2` was enabled and automatic Azure Monitor handoff worked.
- The historical transcript captured alert payload, RCA, approved Azure CLI
  remediation, execution and recovery. Runtime thread/alert IDs stay private.

The historical MCP workflow YAML validated but its apply failed server-side;
plan-create also failed before the custom handler existed. That interface is
**not a deploy recipe**: `high` can produce invalid AzMonitor P1/P2 and legacy
response fields, while an `OR` expression is literal title text.
Use the current initializer's `AzMonitor`/`["Sev2"]` schema and single keyword
`containerapp-restarts`. Read existing plans before creating; never replay a
timed-out non-idempotent create. Run the read-only
readiness command and separately verify pending service gates before inducing.

Current reproducible setup path: render/inspect `Initialize-SreConfiguration.ps1`,
approve its exact changes, then apply with a new external backup path. For legacy
state stop and use the canonical supported fallback. Verify full read-back,
then separately authorize a bounded incident/recovery rehearsal. Portal operation
is optional, not the only automation path.

## 5. Induce the fault

Use the helper script to create a new crashing revision:

```powershell
# Run from the SRE checkout.

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

Before starting, assign a recovery owner and a hard observation deadline with
best-effort reset to false on any error, timeout or unavailable approval.
Normally wait for the agent's proposal, but never extend a safety deadline while
waiting for it. Restore through the operator helper at the deadline and label
that outcome as fallback. Do not repeat the fault to compensate for a missed
approval without a new authorization.

For a repeat rehearsal, first check the actual plan's **Reinvestigation
cooldown**. Enabled cooldown merges recurring fires into the existing
investigation and reopens resolved threads during the configured window; a
resolved alert does not guarantee a new thread or approval card. The current
demo plan uses the three-hour window. Do not change this setting or replay an
old request merely to obtain a fresh approval. Any temporary change needs
separate scoped authorization, a before-state backup and exact restoration.
See [Azure Monitor reinvestigation cooldown](https://learn.microsoft.com/azure/sre-agent/response-plan).

## 7. Approve the governed fix

Before the authorized fault, sign in to `https://sre.azure.com`, select the
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
The [SRE guide's optional incident step](delivery-runsheet.md#6-optional-one-approved-live-incident)
requires the current run's exact card and separate fault consent.
An Azure Monitor alert state or chat message cannot approve that card.
Confirm the current thread, affected app, resource group, subscription and
complete command. Narration such as "approved" or "applying" is not an approval
record. If there is no actual card, do not send an approval message or enable
Autonomous mode as a substitute.

In the SRE Agent thread, the desired Review-mode action is:

```powershell
az containerapp update `
  --subscription $subscriptionId `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

Select **Approve** only for the authorized reset on the current run's operation
card. Only an SRE Agent Administrator can approve the action. If the agent
proposes a different write, do not approve it; obtain a scoped decision before
denying, cancelling or requesting another operation.

Manual recovery fallback, only if live SRE remediation is unavailable:

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -State Repair `
  -ShowMetrics
```

If this fallback is used, label the demo as "manual reset fallback"; do not claim closed-loop SRE remediation.
After fallback, do not approve a stale pending repair card. The card stays Pending
and approvable: in the first rebuilt run it was approved 21 minutes after the
fallback and the agent's write ran as a no-op on the already repaired app, but the
same click on a non-idempotent proposal would change Azure after the operator had
acted. Agree before the fault that the signed-in administrator may Deny the
obsolete card at once; otherwise tell them not to click it and leave it unmodified.
Inspect current state and obtain scoped authorization before any other
cancellation. Do not infer action-card status from thread narration.

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

## Recorded evidence and future capture checklist

### Current-schema retry - 2026-10-20

| Evidence | Recorded result |
|---|---|
| Routing | New v3 Review investigation; old v2 routes remained disabled. |
| Alert / investigation / RCA | Fired 01:20:55 UTC; independent thread 01:22:23; concrete crash-loop RCA and exact false-reset request 01:23:36. |
| Approval | User reported clicking that exact new portal card; no independent ApprovalDecision event returned. |
| Actual executor | Matching ToolEnd 01:28:35 plus Activity Log attribute the write to SRE UAMI; zero operator repair writes. |
| App recovery | Revision28 healthy/ready, one replica/100% traffic and HTTP200; rechecked 01:47:47. |
| Monitor recovery | Actual MonitorCondition resolved 01:45:58; separate workflow state remained Acknowledged; SRE thread Closed. |
| Safety / preservation | Original enabled three-hour cooldown restored; all agent/filter/handler definitions unchanged apart from server metadata. |
| Limits | Earlier run used operator fallback; last lifecycle snapshot predating closure is not current status. No destructive deletion-to-Ready or optional connector test. |

Keep raw exports and runtime IDs private. Capture the same evidence for a
separately authorized future run; this table does not certify its fresh state.

### Historical F04 ledger - 2026-10-12, not current configuration

| Evidence | Captured? | Notes |
|---|---:|---|
| Arc-demo Container App deployed | Yes | Historical lab; active healthy revision after the recorded repair. Runtime revision IDs retained privately. |
| SRE Agent deployed with Container App and alert IDs in managed resources | Yes | `sre-arc-demo` deployed in `rg-arc-demo-sre`; Container App included in managed resources |
| Code repository connected | No | Pending live lab |
| Review-mode response plan enabled | Yes | Created through SRE portal after creating custom subagent `sre-arc-demo`; MCP `incidents_plans_list` shows `container-app-restart-review-v2` enabled, Sev2, mode `review` |
| `SIMULATE_CRASH=true` induced | Yes | Faulted revision became unhealthy with `RestartCount` > 0 |
| Azure Monitor alert fired | Yes | Historical thread/alert IDs retained privately; fired at `2026-10-12T01:38:34Z`. |
| SRE Agent RCA produced | Yes | RCA identified `SIMULATE_CRASH=true`, entrypoint exit code 1, restart onset and the prior healthy revision. |
| Review-mode action approved | Yes | Historical portal card requested the exact Container App false reset in the confirmed lab subscription. |
| Agent reset `SIMULATE_CRASH=false` | Yes | SRE Agent reported the flag reset and a new revision; runtime identifiers retained privately. |
| App recovered and alert resolved | Yes | Revision `ca-arc-demo-fault--0000012` became ready, RestartCount returned to 0, and SRE Agent closed the Sev2 alert |
| Audit trail captured | Yes | Historical transcript includes alert payload, RCA, approved Azure CLI action, execution, recovery and closure. It is not the current retry's independent write-actor evidence. |

## Local validation completed for this task

- `az bicep build --file .\infra\main.bicep`
- PowerShell parser validation for `Deploy-SreAgent.ps1` and `Invoke-NativeContainerAppFault.ps1`
- `git diff --check`
