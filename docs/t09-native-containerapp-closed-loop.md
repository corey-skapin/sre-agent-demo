# T09 — Azure-native Container App closed-loop SRE runbook

Status: live lab validation complete for the Azure-native path. The Container App fault, automatic Azure Monitor incident handoff, SRE RCA, Review-mode approval, SRE-executed repair, recovery verification, and alert closure were exercised in Azure. Source-code repository connection remains optional and was not captured in this run.

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
  -AccessLevel High `
  -AdditionalManagedResourceIds @($containerAppId, $containerAlertId)
```

`High` access assigns Contributor to the agent identity on the existing `arc-demo` resource groups. The agent still runs in Review mode, so write actions require approval.

## 3. Connect code context

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Go to **Builder** > **Knowledge base**.
3. Select **Add repository**.
4. Choose GitHub or Azure DevOps authentication.
5. Add the `corey-skapin/arc-demo` repository.
6. Confirm the repository card shows **Connected**.

Expected RCA context: the agent should be able to point at the `SIMULATE_CRASH` startup script in `bicep/modules/container-apps.bicep` and the operator commands in `docs/container-app-fault.md`.

## 4. Create the Review-mode response plan

Preferred automation path, portal fallback, and optional browser-agent prompt are tracked in
[`sre-response-plan-automation.md`](sre-response-plan-automation.md). The short
version: create the parent SRE Agent through Bicep, try the MCP custom-agent
creation path, and if it times out use the SRE portal/Scout browser fallback to
create the custom handling agent. After the handler exists, create the response
plan with `sreagent_incidents_plans_create`.

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Go to **Build + setup** > **Agent Canvas**.
3. Create or verify a custom agent named `sre-arc-demo`:
   - Instructions: handle Azure Monitor incidents for `alert-arc-demo-containerapp-restarts`; investigate `ca-arc-demo-fault`, `RestartCount`, revision health, and the `SIMULATE_CRASH` environment variable.
   - Handoff description: `Handles Arc demo Azure Monitor Container App restart incidents in Review mode.`
   - Tools: leave empty to inherit the parent agent's global Azure tools, or explicitly select the Azure Monitor/Azure resource tools required by the environment.
4. Go to **Builder** > **Incident response plans**.
5. If the quickstart response plan would also match this alert, disable or delete it to avoid duplicate processing.
6. Create a response plan:
   - Platform: **Azure Monitor**
   - Name: `container-app-restart-review-v2`
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
  --tenant 4a2e6a7b-9d04-4e89-9d8b-01c75a2444c1 `
  --subscription 6ff7d039-8bfd-4cdb-8d74-f7a9f1eb9ff5 `
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

Current reproducible setup path: complete first-run onboarding if prompted,
create the custom agent in the SRE portal, then create the response plan either
in the portal or through MCP after the custom agent exists. Do not rely on
`sreagent_workflows_apply` until the data-plane schema issue is resolved.

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

Do not manually reset the app before the agent proposes a fix.

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
