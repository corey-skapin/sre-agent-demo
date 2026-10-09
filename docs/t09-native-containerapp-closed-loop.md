# T09 — Azure-native Container App closed-loop SRE runbook

Status: local artifact validation complete; live Azure alert/SRE execution is pending because this task was authored without subscription or portal access.

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

| Resource | Default name | Resource group | Purpose |
|---|---|---|---|
| Container App | `ca-arc-demo-fault` | `rg-arc-demo-infra` | Tiny HTTP app with `SIMULATE_CRASH` env-var fault |
| Container Apps environment | `cae-arc-demo` | `rg-arc-demo-infra` | Hosts the app |
| Metric alert | `alert-arc-demo-containerapp-restarts` | `rg-arc-demo-infra` | Fires when `RestartCount` total is greater than 3 in 5 minutes |
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
  -AdminEmail you@contoso.com `
  -NamePrefix arc-demo `
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
  -NamePrefix $namePrefix `
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

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Go to **Builder** > **Incident response plans**.
3. If the quickstart response plan would also match this alert, disable or delete it to avoid duplicate processing.
4. Create a response plan:
   - Platform: **Azure Monitor**
   - Name: `container-app-restart-review`
   - Severity: `Sev2`
   - Title contains: `containerapp-restarts`
   - Response custom agent: the default/custom agent used for this demo
   - Agent autonomy level: **Review**
   - Reinvestigation cooldown: enabled, 3 hours
5. Save and enable the plan.

## 5. Induce the fault

Use the helper script to create a new crashing revision:

```powershell
cd C:\src\sre-agent

.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -NamePrefix $namePrefix `
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

Wait 5-10 minutes. The alert evaluates every 5 minutes over a 5-minute window and fires when `RestartCount` total is greater than 3.

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
  -NamePrefix $namePrefix `
  -State Repair `
  -ShowMetrics
```

If this fallback is used, label the demo as "manual reset fallback"; do not claim closed-loop SRE remediation.

## 8. Verify recovery

```powershell
.\scripts\Invoke-NativeContainerAppFault.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -NamePrefix $namePrefix `
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
| Arc-demo Container App deployed | No | Pending live lab |
| SRE Agent deployed with Container App and alert IDs in managed resources | No | Pending live lab |
| Code repository connected | No | Pending live lab |
| Review-mode response plan enabled | No | Pending live lab |
| `SIMULATE_CRASH=true` induced | No | Pending live lab |
| Azure Monitor alert fired | No | Pending live lab |
| SRE Agent RCA produced | No | Pending live lab |
| Review-mode action approved | No | Pending live lab |
| Agent reset `SIMULATE_CRASH=false` | No | Pending live lab |
| App recovered and alert resolved | No | Pending live lab |
| Audit trail captured | No | Pending live lab |

## Local validation completed for this task

- `az bicep build --file .\infra\main.bicep`
- PowerShell parser validation for `Deploy-SreAgent.ps1` and `Invoke-NativeContainerAppFault.ps1`
- `git diff --check`
