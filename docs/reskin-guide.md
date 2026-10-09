# Reskin guide — SRE Agent layer

This repo layers Azure SRE Agent on an existing `arc-demo` environment. Keep the **spine** (agent Bicep, Review mode, Azure Monitor incident source, helper scripts) constant and swap customer values through `config\demo-skin.json`. Defaults align with the DTF baseline and contain no private subscription, tenant, or mailbox values.

## Variable surface

| Path | Purpose | Default |
|---|---|---|
| `customer.*` | Customer name, short name, and scenario label for docs/talk track. | SA DTF / DTF / Infrastructure Modernisation Program |
| `azure.namePrefix` | Prefix of the existing Arc demo to discover (`rg-<prefix>`, `law-<prefix>`, `ag-<prefix>`). | `arc-demo` |
| `azure.location` | Azure region for the SRE Agent resource group. | `australiaeast` |
| `sre.accessLevel` | RBAC profile for the SRE Agent identity. | `High` |
| `sre.targetArcMachine` | Default Arc machine for T10/T11 helpers. | `win-app-01` |
| `sre.*Scenario` / `sre.*Fault*` | Default helper scenario and fault modes. | Heartbeat / CrashOnProcessing |
| `labels.*` | Agent name, response-plan labels, LOB app event source/task/app names. | DTF baseline labels |
| `codeContext.*` | LOB app repository URL, commit, and source path stamped into guest config/events. | Placeholder repo/commit |
| `tags.*` | Tags on the SRE Agent resources. | demo tags |

## Swap list

Change per customer:
- Match `azure.namePrefix` and `azure.location` to the Arc repo's skin.
- Update `labels.agentName` if the prefix changes.
- Update `codeContext.lobRepositoryUrl` and `codeContext.lobSourceCommit` after publishing the customer-facing LOB app repo.
- Pick the T10/T11 target Arc machine if the fleet mix changes.

Keep constant:
- Review-mode stance, AzMonitor incident source, knowledge-graph resource discovery, and the separation from `arc-demo`.
- The helper scripts' fault mechanics unless a later task adds new scenarios.

## Retarget steps

1. Reskin and deploy `C:\src\arc-demo` first.
2. Copy this repo's `config\demo-skin.json` or start from `config\dummy-customer.demo-skin.json`.
3. Keep `azure.namePrefix` in sync with the Arc repo.
4. Run SRE scripts using the skin:
   ```powershell
   .\scripts\Deploy-SreAgent.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath .\config\demo-skin.json
   ```
5. Use the same skin for scenario helpers:
   ```powershell
   .\scripts\Invoke-NativeContainerAppFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
   .\scripts\Invoke-T10ArcFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
   .\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action Deploy
   .\scripts\New-LobArcAppMonitorAlert.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action ShowQuery
   ```

## Examples

DTF/default: use `config\demo-skin.json`, then provide only subscription/tenant and any live `AdditionalManagedResourceIds`.

Dummy customer: `config\dummy-customer.demo-skin.json` changes the prefix to `contoso-arc`, agent name to `sre-contoso-arc`, LOB labels to Contoso, and code context to `https://github.com/contoso/lob-arc-app-demo`.

## Remaining constants

Repo names, SRE Agent Review mode, AzMonitor incident management, fault flag names (`SIMULATE_CRASH`, `FaultMode`), and sample host names stay as reusable demo mechanics. Customer-specific names, labels, target machine defaults, repository URL, and tags now live in the skin file.
