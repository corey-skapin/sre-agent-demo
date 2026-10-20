# T09 — Azure-native Container App closed-loop SRE runbook

Status: historically live validated for the Azure-native path. The Container App fault, automatic Azure Monitor incident handoff, SRE RCA, Review-mode approval, SRE-executed repair, recovery verification, and alert closure were exercised in Azure. This is not certification of the current deployment: verify current handler instructions, existing plan title filters, Review mode and routing before a new rehearsal. Source-code repository connection remains optional and was not captured in the historical run.

Latest current-schema rehearsal (2026-10-20): v3 Review routing generated a fired
Sev2 alert, automatic SRE incident and concrete crash-loop RCA. No SRE write was
verified during the bounded approval window; the authorized operator fallback
reset the flag and verified a new healthy revision, full traffic and HTTP 200.
Do not call this latest run SRE-executed repair or infer approval from the agent's
own narration. Historical end-to-end proof remains distinct. Monitor alert
recovery must be read back separately from app recovery.

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
`-SkinPath .\config\demo-skin.json`; see [`reskin-guide.md`](reskin-guide.md).

| Resource | Default name | Resource group | Purpose |
|---|---|---|---|
| Container App | `ca-arc-demo-fault` | `rg-arc-demo-infra` | Tiny HTTP app with `SIMULATE_CRASH` env-var fault |
| Container Apps environment | `cae-arc-demo` | `rg-arc-demo-infra` | Hosts the app |
| Metric alert | `alert-arc-demo-containerapp-restarts` | `rg-arc-demo-infra` | Fires when `RestartCount` total is greater than 0 in 5 minutes |
| Action Group | `ag-arc-demo` | `rg-arc-demo` | Existing alert seam consumed by SRE Agent |
| SRE Agent | `sre-arc-demo` | `rg-arc-demo-sre` | Review-mode agent with Azure Monitor incident source |

## Prerequisites

- Azure CLI 2.60+ with the target tenant/subscription selected.
- `C:\src\arc-demo` at T05 or later and `C:\src\sre-agent` at T08 or later.
- Permission to deploy `arc-demo`, deploy this SRE Agent layer, create role assignments, and approve SRE Agent actions.
- SRE Agent response plan set to **Review** mode. Review mode is required for the one-click **Approve** step.
- Optional but recommended: connect `corey-skapin/arc-demo` as a source-code repository in the SRE Agent knowledge base so RCA can cite:
  - `bicep/modules/container-apps.bicep`
  - `docs/container-app-fault.md`

References used for this runbook: Azure SRE Agent overview, run modes, incident response, response plans, source-code connection, execute mitigations, Azure Container Apps environment variables, and Container Apps `RestartCount` metrics on Microsoft Learn.

## 1. Deploy arc-demo with the Container App workload

```powershell
cd C:\src\arc-demo

az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

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
  --resource-group $infraRg `
  --name $containerAppName `
  --query id `
  --output tsv

$containerAlertId = az monitor metrics alert show `
  --resource-group $infraRg `
  --name $alertName `
  --query id `
  --output tsv
```

## 2. Deploy the SRE Agent layer

```powershell
cd C:\src\sre-agent

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -ParentOnly `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($containerAppId, $containerAlertId)
```

`High` access assigns Contributor to the agent identity on the existing `arc-demo` resource groups. The agent still runs in Review mode, so write actions require approval. `-ParentOnly` explicitly acknowledges that this deploy does not complete the data-plane setup below. For an already running demo, do not redeploy merely to rehearse: use read-only readiness and verify the existing configuration first.

## 3. Connect code context

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Go to **Builder** > **Knowledge sources**.
3. Select **Add repository**.
4. Choose GitHub or Azure DevOps authentication.
5. Only after explicit authorization, add the `corey-skapin/arc-demo` repository.
6. Confirm the repository card shows **Connected**.

Expected RCA context: the agent should be able to point at the `SIMULATE_CRASH` startup script in `bicep/modules/container-apps.bicep` and the operator commands in `docs/container-app-fault.md`.

## 4. Create the Review-mode response plan

Preferred automation path, portal fallback, and optional browser-agent prompt are tracked in
[`sre-response-plan-automation.md`](sre-response-plan-automation.md). The short
version: render desired configuration with `Initialize-SreConfiguration.ps1`;
list and inspect existing plans and the custom handler first. Create only when
absence is verified. After an ambiguous timeout read back before retrying.
The initializer uses pinned Microsoft IaC template protocols for full handler and
plan reads/upserts. Do not use legacy MCP `severity: high`: it creates invalid
AzMonitor P1/P2 and response-level instructions. Existing legacy configuration
requires approved migration to exact Sev2 and handler-owned instructions/tools,
not just a title edit. See the automation doc for backup/preview/apply/verify.

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Go to **Builder** > **Agent Canvas**.
3. Create or verify a custom agent named `sre-arc-demo`:
   - Instructions: handle Azure Monitor incidents for `alert-arc-demo-containerapp-restarts`; investigate `ca-arc-demo-fault`, `RestartCount`, revision health, and the `SIMULATE_CRASH` environment variable.
   - Handoff description: `Handles Arc demo Azure Monitor Container App restart incidents in Review mode.`
   - Tools: use the rendered explicit built-in tool selection on this custom agent; keep the plan in Review. Do not configure legacy response-level tools or instructions.
4. Go to **Builder** > **Incident response plans**.
5. If quickstart also matches, report the conflict and obtain scoped authorization before narrowing/disabling/deleting another plan.
6. Verify the existing response plan; create only if its absence is verified:
   - Platform: **Azure Monitor**
   - Name: `container-app-restart-review-v3` (skin-driven current route; retain old v2 disabled during approved cutover)
   - Severity: `Sev2`
   - Title contains: `containerapp-restarts`
   - Response custom agent: `sre-arc-demo`
   - Agent autonomy level: **Review**
   - Reinvestigation cooldown: enabled, 3 hours
7. Save and enable the plan.

### F04 live setup status

Validated state on 2026-10-12:

- `sre-arc-demo` was running in `rg-arc-demo-sre` with Review mode and High access.
- The required custom handling agent could not be created through MCP during the first pass, but portal creation through **Builder** > **Agent Canvas** succeeded.
- After the portal custom agent existed, the response plan `container-app-restart-review-v2` was enabled and automatic Azure Monitor handoff worked.
- Thread `e604887e-51c0-4249-9ffd-7bc6af6d82dd` captured alert payload, RCA, approved Azure CLI remediation, successful execution, recovery confirmation, and alert closure.

Historical MCP setup attempt:

```powershell
# Handler YAML validation passed.
sreagent_workflows_validate `
  --yaml-content <ExtendedAgent YAML with metadata.name sre-arc-demo>

# Applying the same YAML failed in the SRE Agent data plane.
sreagent_workflows_apply `
  --tenant <TENANT_ID> `
  --subscription <SUBSCRIPTION_ID> `
  --resource-group rg-arc-demo-sre `
  --agent sre-arc-demo `
  --yaml-content <ExtendedAgent YAML>
# 400 from /api/v2/extendedAgent/agents/sre-arc-demo:
# The JSON value could not be converted ...; request field is required.

# Creating the response plan still fails until the custom handling agent exists.
sreagent_incidents_plans_create `
  --name container-app-restart-review-v2 `
  --severity high `
  --trigger-condition "alert-arc-demo-containerapp-restarts OR containerapp-restarts" `
  --services Azure Container Apps,ca-arc-demo-fault,rg-arc-demo-infra `
  --agent-mode review `
  --agent sre-arc-demo
# 400 from /api/v1/incidentplayground/filters/container-app-restart-review:
# "Handling agent 'sre-arc-demo' does not exist."
```

The historical MCP command above is **not a deploy recipe**: `high` can produce
invalid AzMonitor P1/P2 and legacy response fields, while `OR` is literal text.
Use the current initializer's `AzMonitor`/`["Sev2"]` schema and single keyword
`containerapp-restarts`. Read existing plans before creating; never replay a
timed-out non-idempotent create. Run the read-only
readiness command and separately verify pending service gates before inducing.

Current reproducible setup path: render/inspect `Initialize-SreConfiguration.ps1`,
approve its exact changes, then apply with a new external backup path. For legacy
state use separately authorized `-AllowLegacyMigration`. Verify full read-back,
then separately authorize a bounded incident/recovery rehearsal. Portal operation
is optional, not the only automation path.

## 5. Induce the fault

Use the helper script to create a new crashing revision:

```powershell
cd C:\src\sre-agent

.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -State Break `
  -ShowMetrics
```

Equivalent raw command:

```powershell
az containerapp update `
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

## 7. Approve the governed fix

In the SRE Agent thread, the desired Review-mode action is:

```powershell
az containerapp update `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

Select **Approve** on the Azure infrastructure operation card. Only an SRE Agent Administrator can approve the action. If the agent proposes a different write action, deny it and ask it to reset only `SIMULATE_CRASH=false` on the affected Container App.

Manual recovery fallback, only if live SRE remediation is unavailable:

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -State Repair `
  -ShowMetrics
```

If this fallback is used, label the demo as "manual reset fallback"; do not claim closed-loop SRE remediation.
After fallback, do not approve a stale pending repair card. Inspect current state
and have the signed-in administrator deny/dismiss an obsolete request if present.

## 8. Verify recovery

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -State Status `
  -ShowMetrics

$fqdn = az containerapp show `
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
- Azure Monitor alert resolves after the next evaluation cycle

## 9. Show the audit trail

Use three evidence points:

1. SRE Agent investigation thread: RCA, proposed command, **Approve** action, execution result, verification.
2. Azure Activity Log for the Container App write:

   ```powershell
   az monitor activity-log list `
     --resource-id $containerAppId `
     --offset 2h `
     --query "[?operationName.value=='Microsoft.App/containerApps/write'].{time:eventTimestamp,caller:caller,status:status.value,operation:operationName.value}" `
     --output table
   ```

3. Azure Monitor alert history showing fired and resolved states for `alert-arc-demo-containerapp-restarts`.

## Evidence capture checklist

| Evidence | Captured? | Notes |
|---|---:|---|
| Arc-demo Container App deployed | Yes | Validated in subscription `6ff7d039-8bfd-4cdb-8d74-f7a9f1eb9ff5`; active healthy revision after SRE repair: `ca-arc-demo-fault--0000012` |
| SRE Agent deployed with Container App and alert IDs in managed resources | Yes | `sre-arc-demo` deployed in `rg-arc-demo-sre`; Container App included in managed resources |
| Code repository connected | No | Pending live lab |
| Review-mode response plan enabled | Yes | Created through SRE portal after creating custom subagent `sre-arc-demo`; MCP `incidents_plans_list` shows `container-app-restart-review-v2` enabled, Sev2, mode `review` |
| `SIMULATE_CRASH=true` induced | Yes | Faulted revision `ca-arc-demo-fault--0000011` became unhealthy with `RestartCount` > 0 |
| Azure Monitor alert fired | Yes | Alert thread `e604887e-51c0-4249-9ffd-7bc6af6d82dd`, alert ID `56ca7acd-84ad-4ff0-b660-26647566f000`, fired at `2026-10-12T01:38:34Z` |
| SRE Agent RCA produced | Yes | RCA identified `SIMULATE_CRASH=true`, entrypoint exits with code 1, RestartCount starts at `01:36 UTC`, and previous revision `--0000010` was last healthy |
| Review-mode action approved | Yes | Portal approval card executed `az containerapp update --name ca-arc-demo-fault --resource-group rg-arc-demo-infra --subscription 6ff7d039-8bfd-4cdb-8d74-f7a9f1eb9ff5 --set-env-vars SIMULATE_CRASH=false` |
| Agent reset `SIMULATE_CRASH=false` | Yes | SRE Agent reported `SIMULATE_CRASH=false` applied and created revision `ca-arc-demo-fault--0000012` |
| App recovered and alert resolved | Yes | Revision `ca-arc-demo-fault--0000012` became ready, RestartCount returned to 0, and SRE Agent closed the Sev2 alert |
| Audit trail captured | Yes | Thread `e604887e-51c0-4249-9ffd-7bc6af6d82dd` includes alert payload, RCA, approved Azure CLI action, execution completion, recovery confirmation, and alert closure |

## Local validation completed for this task

- `az bicep build --file .\infra\main.bicep`
- PowerShell parser validation for `Deploy-SreAgent.ps1` and `Invoke-NativeContainerAppFault.ps1`
- `git diff --check`
