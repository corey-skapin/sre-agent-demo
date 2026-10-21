# Reskin guide — SRE Agent layer

This repo layers Azure SRE Agent on an existing `arc-demo` environment. Keep the **spine** (agent Bicep, Review mode, Azure Monitor incident source, helper scripts) constant and supply customer values through a private skin outside git. The tracked skins use fictional Contoso/Fabrikam examples, generic resource names and no external repository, subscription, tenant or contact values.

## Variable surface

| Path | Purpose | Default |
|---|---|---|
| `customer.*` | Fictional organization and scenario labels; override privately for a real audience. | Contoso / Hybrid Operations Readiness |
| `azure.namePrefix` | Prefix of the existing Arc demo to discover (`rg-<prefix>`, `law-<prefix>`, `ag-<prefix>`). | `arc-demo` |
| `azure.location` | Azure region for the SRE Agent resource group. | `australiaeast` |
| `sre.accessLevel` | RBAC profile for the SRE Agent identity. | `High` |
| `sre.targetArcMachine` | Default Arc machine for T10/T11 helpers. | `win-app-01` |
| `sre.requiredScenarios` | Required baseline/resource/plan gates; not a fault trigger. | `T09`, `T11` |
| `sre.retiredResponsePlanNames` | Explicitly owned old filter IDs to disable only during approved cutover; never inferred by prefix. | two v2 demo routes |
| `sre.*Scenario` / `sre.*Fault*` | Default helper scenario and fault modes. | Heartbeat / CrashOnProcessing |
| `labels.*` | Agent name, response-plan labels, LOB app event source/task/app names. | Generic Arc demo labels |
| `codeContext.*` | Optional repository URL and commit stamped into guest config/events, plus local source path. | Empty URL/commit; local sample path |
| `tags.*` | Tags on the SRE Agent resources. | demo tags |

## Swap list

Change per customer:
- Match `azure.namePrefix` and `azure.location` to the Arc repo's skin.
- Update `labels.agentName` if the prefix changes.
- Leave `codeContext.lobRepositoryUrl` and `codeContext.lobSourceCommit` empty
  for a local-sample/telemetry-only demo, or supply your own HTTPS repository URL
  and commit together. Set `codeContext.lobSourcePath` to its source path.
  A URL is optional evidence context, not connector authentication or proof of
  repository access. The handler explicitly reports when none is configured.
- Pick the T10/T11 target Arc machine if the fleet mix changes.

Keep constant:
- Review-mode stance, AzMonitor incident source, knowledge-graph resource discovery, and the separation from `arc-demo`.
- The helper scripts' fault mechanics unless a later task adds new scenarios.

## Retarget steps

1. Reskin and deploy `C:\src\arc-demo` first.
2. Copy `config\demo-skin.json` or `config\dummy-customer.demo-skin.json` to a
   private location outside the checkout; do not commit real customer/context values.
3. Keep `azure.namePrefix` in sync with the Arc repo.
4. Run SRE scripts using the skin:
   ```powershell
   .\scripts\Deploy-SreAgent.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -ParentOnly `
     -SkinPath .\config\demo-skin.json
   ```
5. Parent-only is not Ready. Render, inspect and approve/apply the current-schema
   configuration using `sre-response-plan-automation.md`, with a new external
   backup. Run readiness and pair its static pending telemetry gate with separately
   recorded rehearsal evidence. Do not induce a fault to answer preflight.
6. Use the same skin for scenario helpers; guest deployment/fault/reset actions
   need their own approval. Status/ShowQuery are the non-disruptive examples:
   ```powershell
   .\scripts\Invoke-NativeContainerAppFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
   .\scripts\Invoke-T10ArcFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
   .\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action Status
   .\scripts\New-LobArcAppMonitorAlert.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action ShowQuery
   ```

## Off state vs cleanup

The optional SRE layer has a different off-state from `arc-demo` because Azure
SRE Agent has no stopped/deallocated state. To avoid the always-on agent charge,
run:

```powershell
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
```

Preview with `-WhatIf` first. This retains `rg-<prefix>-sre` and `<AGENT_NAME>-uami`,
removes only the parent/known diagnostics, known UAMI workload assignments and
the single direct parent administrator grant. Unexpected resources/grants stop
deletion. Full group/identity deletion is separate cleanup. It does not delete
or redeploy the Arc estate. Save its identity principal ID, Inspect export and
incident/audit evidence first, then verify asynchronous deletion with Hibernated
readiness and that saved principal. Finish SRE before Arc hibernation.
Recreate the parent with `Deploy-SreAgent.ps1 -ParentOnly` using the retained UAMI, then render
`Initialize-SreConfiguration.ps1`, inspect and apply the pinned current-schema
configuration with a new external backup path, then run readiness. Existing
legacy plans require separately approved migration, not MCP `high`/P1/P2 creates.
Parent creation alone does not restore custom handlers, plans or
repository authorization. Keep the requested Ready demo running unless cleanup
is explicitly requested.
Wake Arc before SRE. Rebuilding recreates the modern custom agent and v3 filters,
not retired v2 history or learned memory. The saved export is a reference, not
an automatic restore input. Filters explicitly enforce enabled three-hour cooldown,
Sev2 and Review. First deployment creates the UAMI through the same IaC; normal
park/wake retains its principal and deterministic grant IDs. The system-assigned
parent principal still changes on parent recreation. A missing UAMI fails normal
Hibernated readiness; do not mistake historical whole-group deletion for retention.
The retained-identity park/wake round trip has not been live-tested here.
Residual Arc/storage/monitoring services can still incur charges.

Skins are validated against `config\demo-skin.schema.json`; missing files, unknown
fields, unsafe names and invalid enum values fail explicitly. Fault helper
defaults cannot silently induce a Container App fault (the default is `Status`).
`labels.containerResponsePlan`, `labels.lobResponsePlan` and
`labels.lobAlertTitleContains` drive the generated desired state. The LOB alert
display name includes that exact keyword; its region is discovered from the
workspace unless explicitly supplied. Recheck existing plan filters when reskinning.

## Examples

Default synthetic example: `config\demo-skin.json` uses fictional Contoso with the generic `arc-demo` prefix. Provide subscription/tenant at runtime and keep live values in a private skin.

Alternative synthetic example: `config\dummy-customer.demo-skin.json` uses fictional Fabrikam, prefix `fabrikam-arc`, agent `sre-fabrikam-arc` and corresponding labels. Both examples leave external repository URL/commit empty. Configure your own source only when needed and separately authorize any connector.

## Remaining constants

Repo names, SRE Agent Review mode, AzMonitor incident management, fault flag names (`SIMULATE_CRASH`, `FaultMode`), and sample host names stay as reusable demo mechanics. Customer-specific names, labels, target machine defaults, repository URL, and tags now live in the skin file.
