# Reconstructing current-schema SRE handler and Review response plans

**Deployment/lifecycle operator reference.** For an already provisioned demo,
present from [the canonical guide](delivery-runsheet.md), not the setup
commands below. [The docs map](README.md) explains the minimum reading path.

## Supported path and protocol pin

Use Microsoft's [IaC deployment guidance](https://learn.microsoft.com/azure/sre-agent/deploy-iac),
which links the public `microsoft/sre-agent` templates. This repo implements only
the narrow handler/filter subset needed by this demo, without installing or
executing remote scripts. Protocol provenance is pinned to
[`ff317310cca5894fcd42ccc32f5452c3f408cc3c`](https://github.com/microsoft/sre-agent/tree/ff317310cca5894fcd42ccc32f5452c3f408cc3c/sreagent-templates).
Do not replace that pin or request schema speculatively.

The earlier Azure MCP plan-create interface is **not suitable for rebuilding
these Azure Monitor plans**: `severity: high` produced invalid `P1/P2` and legacy
response-level instructions. It is not equivalent to `Sev2`. Do not replay it.
MCP plan summaries remain useful evidence, but do not establish current schema.

The pinned sources establish these contracts:

| Public source | Contract used here |
|---|---|
| `bicep/Apply-Extras.ps1`, incidentFilters and subagents sections | Named PUT envelopes `{name,type,tags,properties}` to `/api/v2/extendedAgent/incidentFilters/{name}` and `/api/v2/extendedAgent/agents/{name}` |
| `bin/ps/Export-Agent.ps1`, filters/subagents/handlers sections | Full GET lists on those v2 collections and `/api/v1/incidentPlayground/handlers` |
| `recipes/azmon-lawappinsights` | `incidentPlatform: AzMonitor`, `Sev*` priorities, handling custom agent and built-in tool identifiers |
| Parent readiness lookup in `SreConfiguration.psm1` | ARM `Microsoft.App/agents`, `api-version=2025-05-01-preview`; endpoint from the exact parent, never a guessed host |

The current official templates route children through the data plane because ARM
child-resource availability is tenant/region dependent. This differs from the
article's high-level ARM description. We follow the pinned implementation, not
invented portal endpoints or the old MCP payload.

Authentication is the explicitly validated subscription's token for
`https://azuresre.dev`; the HTTPS endpoint is read from the named parent ARM
resource. Tokens remain in memory and are never exported. Authentication or
permission failures stop; setup does not switch accounts or grant access.

### Maintaining the coupling and handling service changes

This is the canonical coupling reference, not a stable public data-plane SDK
promise. Keep the revision above, the parent preview API version, exact list/PUT
envelopes and `https://azuresre.dev` token audience under review together.
The v1 handler collection is **GET-only**: it detects active legacy overrides
that could undermine modern routing; no handler creation/update is supported.

To re-pin, compare the selected upstream revision's `Apply-Extras.ps1`,
`Export-Agent.ps1` and AzMonitor recipe with the adapter and fixtures. Review
routes, envelopes, casing, token audience and the parent schema before changing
`TemplateRevision`; update this reference and mocked success/failure tests in the
same PR. Run local tests and Bicep compilation. Propose any live validation
separately; a pin update or mocked pass does not authorize a service call.
Do not download/execute upstream scripts or silently follow a movable branch.

On authentication/denial, malformed/empty/paginated reads, unsupported legacy
state or schema drift, **stop explicitly**. Do not infer absence, guess POST,
fall back to another endpoint/account, grant permissions, delete the parent or
claim partial setup is ready. Apply backs up before writes; a later failure can
leave partial changes, so retain the backup and inspect before resuming. An
ambiguous PUT is read back before retry; denied/invalid writes are not retried.

If the contract changes, use the supported SRE portal following current
[subagent guidance](https://learn.microsoft.com/azure/sre-agent/create-subagent)
and [response-plan guidance](https://learn.microsoft.com/azure/sre-agent/response-plan).
Configure only the approved rendered handler and Review plans; require a signed-in
browser capability and inspect actual visible controls rather than inventing
clicks. If that capability is unavailable, report the requirement and stop.
Manual setup is not a verified automated bootstrap: report the remaining
read-back blocker until supported inspection works. Rebuilding a legacy parent
requires separate deletion authorization and evidence export; it is never a
failure fallback.

## Render, inspect, approve, apply

```powershell
# Local deterministic render: no cloud requests.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json

# Supported read-only export plus exact in-place change preview.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Inspect

# Only after approving that exact change scope:
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Apply `
  -BackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json> -WhatIf

# Remove -WhatIf only when the full proposed scope is authorized.
```

`schemaVersion: 2` desired configuration is not the old MCP request format.
Keep exports/previews outside git; they contain runtime IDs and full instructions.
`-Inspect` has no write or backup side effects. `-Apply` requires a new backup
filename in an existing directory outside the repo. It refuses to overwrite a
backup. An already-correct repeat run performs no PUT.

For clean reconstruction after an authorized parent deployment, `-Apply` creates
only the verified-absent named custom agent and current filters. It does not
create legacy response handlers. For existing modern state it updates the same
objects, preserving unrelated fields. It does not migrate old instances.

## Exact desired demo configuration

The versioned `config\sre-handler.instructions.txt` is rendered using the skin.
Instructions and tools belong to the **handling custom agent**, not the response
plan. Built-in tools are explicitly `RunAzCliReadCommands`,
`RunAzCliWriteCommands`, `QueryLogAnalyticsByWorkspaceId`, and `SearchMemory`.
Write capability remains governed by parent and response-plan **Review**, scoped
RBAC and human approval. No connector or new RBAC grant is created.

| Scenario | Skin plan label | Platform / priorities | Title contains | Handling agent / autonomy |
|---|---|---|---|---|
| T09 | `labels.containerResponsePlan` | `AzMonitor` / `["Sev2"]` | `containerapp-restarts` | `labels.agentName` / `Review` |
| T11 | `labels.lobResponsePlan` | `AzMonitor` / `["Sev2"]` | `labels.lobAlertTitleContains` | `labels.agentName` / `Review` |

Filters are enabled. The literal title is one keyword, never an `OR` expression.
The default impacted services remain `Azure Container Apps` and `Azure Arc`;
verify actual incident matching in the separately authorized rehearsal.
The renderer explicitly sets `mergeEnabled=true` and `mergeWindowHours=3` on
both modern routes, for fresh creation and reconciliation. This matches the
validated live settings; they are no longer left to service defaults.
Inspect actual cooldown before a repeat: a recurring fire can merge into/reopen
an existing thread. Any temporary disable and exact restoration need scoped
approval; neither closing a thread nor a resolved alert guarantees a fresh one.
The custom agent investigates T09 and proposes only the expected app repair.
T10/T11 remain hybrid evidence plus **operator** Arc Run Command recovery.
Do not claim reliable T11 RCA or autonomous Arc repair.

## Fresh bootstrap and existing-state boundary

Default v3 filters route directly to the handling custom agent. A fresh bootstrap
creates one agent and two filters; a repeated bootstrap is no-op. Modern drift
uses named in-place PUT with backup, concurrent-edit detection and read-back.
Keep these fresh/reused-instance safeguards; they are not migration machinery.

The pre-current-schema instance's staged v2-to-v3 cutover, priority normalization,
legacy-handler cleanup, retired-name skin option and migration switch have been
removed. Remove the obsolete retired-name property from private skins as well.
Old names have no special ownership exemption: enabled unowned plans block apply;
disabled historical objects may remain. Invalid legacy priorities and active
response-level instructions/tools/steps are refused before any write, rather
than partially rewritten. The v1 read guard remains because service-created or
reused handlers cannot safely be assumed absent. Existing same-principal RBAC
adoption also remains necessary for retained-identity wake, not just old routing.

Use the fallback above for unsupported existing state. Historical cutover and
T09 evidence is in the [non-presenter engineering ledger](t10-sre-on-arc-experiment.md#historical-sre-configuration-and-t09-evidence).

## Deployment, readiness and lifecycle

For a new/rebuilt layer, complete deployment can chain parent plus configuration:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -ConfigurationBackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>
```

Use `-ParentOnly` explicitly if only the parent is intended. It is not Ready.
Do not redeploy the running parent merely to repair modern plans: inspect/apply
configuration directly. Full deployment follows skin resource names; custom
parent overrides require explicit reskinning or parent-only intent.

```powershell
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Ready `
  -OutputFormat Json -TimeoutSeconds 180
```

Readiness now uses full supported reads for instructions/tools, On/Review,
AzMonitor/Sev2/title/handler/service mapping, active legacy response fields,
enabled three-hour cooldown and unreviewed enabled extra plans. Invalid active priorities,
active legacy settings or enabled unowned routes are **fail**, not merely
unknown/pending. Retained disabled history is allowed. Missing/denied reads fail explicitly.
The Ready command does not ingest external rehearsal artifacts, so
`telemetry-and-alerts` is optional (`required=false`), **skipped / not evaluated**
with no observed proof. Active/Ready passes when all required checks pass;
a separately authorized run supplies incident evidence, not a prerequisite to
clear this advisory item. No read-only preflight certifies a new closed loop.

The Arc/SRE readiness JSON contract remains schemaVersion 1; status is
`pass|fail|pending|skipped`, exits 0 pass, 1 fail/error, 2 pending. The desired
configuration format is separately versioned. Desired states are `Active`,
`Hibernated` and `Removed`; `Ready` remains the compatible Active alias/default,
not a fourth lifecycle state. Preserve required failures/pending outcomes;
the optional rehearsal item does not affect the overall status.
Worker warnings are captured before job remoting and included as optional
`inspection-warnings` data, never printed ahead of the JSON document. They do not
hide required failures or change a required check's outcome.

### Approved hibernation and later reactivation

Normal hibernation **retains the dedicated SRE group, SRE-only UAMI, existing
workload grants, workspace Application Insights and owned Smart Detection Action
Group**. It deletes only the named paid parent. The deployer's parent-scoped SRE
Administrator assignment belongs to the deleted parent, not the stable identity;
any stale free entry is reported for reconciliation before Active or Removed.
Unrelated IAM/resource drift is reported, never silently deleted and never
a reason to strand the known paid parent. Failed inspection, wrong target or
identity mismatch still stops execution. Arc workloads remain untouched.
Unknown retained resources may still incur charges; the Hibernated result proves
the known SRE parent is absent, not that every resource in the group is free.

The retained identity is created by `infra\modules\sre-identity.bicep` in the same
SRE group; the parent module references it as existing. Incremental deployment
reuses its deterministic ARM ID and principal. RBAC names include scope, seed,
principal and role; the same retained principal restores the same six assignment
IDs instead of accumulating principals/grants. Existing same-principal legacy
assignment names are still adopted while present.
The validated `SystemAssigned,UserAssigned` parent shape is preserved, per the
[published schema](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents).
Only the UAMI survives parent deletion; the system principal still rotates and
receives no external workload grants from this repo. UserAssigned-only service
operation has not been validated here and is not silently enabled.

Managed identities have [no extra cost](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
Normal parking now also retains its external Contributor access. Restrict who
can attach/use the identity; free permissions still carry a security tradeoff.
Before Active, deployment/readiness reject excessive or inherited assignments
outside the requested profile at the two workload groups, including old
subscription Monitoring Contributor. Reconciliation requires separate scope
approval, not implicit revocation. Wake adopts existing direct grant names,
creates missing grants and avoids unnecessary Graph principal-name lookups.
Retained Application Insights must match the requested workspace/location; it
is not silently relocated. Full identity/group deletion uses the explicit
Removed path below. Historical whole-group hibernation deleted
its UAMI; that old principal cannot be restored, so the next first deployment
must create one replacement before future cycles can retain it.

Before deletion, save the live UAMI principal and full Inspect output, plus any
needed incident/tool/Activity Log evidence outside git. The narrow Inspect
export contains custom agents, filters and legacy handlers; it does **not**
export learned memory, thread history or connector credentials. Tokens are never
exported. Use a new filename in an existing private directory:

```powershell
az identity show --subscription <SUBSCRIPTION_ID> `
  --resource-group rg-<PREFIX>-sre --name <AGENT_NAME>-uami `
  --query principalId --output tsv --only-show-errors
# Record that value privately as <SAVED_PRINCIPAL_ID>; do not infer a deleted ID.

.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Inspect |
  Out-File -LiteralPath <NEW_PRIVATE_EXPORT_PATH.json> -Encoding utf8 -NoClobber

.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -WhatIf

# Only after authorizing the exact preview:
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID>

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Hibernated `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> `
  -OutputFormat Json -TimeoutSeconds 180
```

Check each exit status. Resource removal is sequential with bounded observation
(`Hibernate-SreAgent.ps1 -TimeoutSeconds 300` by default), not a hard cancellation
deadline on each Azure CLI call. Read-before-write verifies target and retained
principal; stop on failed reads/writes without blind retries. Recheck Hibernated
readiness separately before parking Arc. Its required checks are the exact retained
UAMI/group and absent paid parent. Diagnostics, workload grants, stale parent
grants and drift are explicit optional wake diagnostics; failures there do not
change the cost-state result. Actual inspection denial still fails the report.
An old UAMI-only parked state is accepted: Hibernate does not create diagnostics
or permissions, and authorized wake rebuilds missing state through the same IaC.
Principal-filtered ARM inventory includes below/above-subscription scopes and
reports unknown scopes instead of missing them. Direct SRE-group ARM reads
distinguish deployer parent grants from UAMI workload permissions.
The documented [ARM assignment-list API](https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope?view=rest-authorization-2022-04-01)
is used with bounded, validated pagination, not Microsoft Graph or guessed SRE routes.
Absent/partial state can be inspected without mutation, but a missing UAMI fails
normal Hibernated even with a saved old principal. Only after SRE is verified
parked should Arc/networking be parked. Parent deletion avoids its always-on
cost, not all remaining storage, monitoring or Arc-service charges.

For the next demo, activate and verify Arc first. Deploy the SRE parent using the
retained identity, then render/Inspect/approve/Apply the versioned modern custom agent and
v3 filters with a new external backup, or use complete deployment above.
Retired v2 objects, learned memory and deleted history are not restored. The
modern v3 filters explicitly restore enabled three-hour cooldown and Review/Sev2.
Do not replay an old full export as a PUT payload: it is reference
evidence, not a supported restore input. Optional repository authentication needs
explicit reauthorization. An in-place T09 repair proves neither a fresh bootstrap
nor a retained-identity park/wake round trip; that live lifecycle gate remains untested.

After AI-led combined activation/SRE reactivation completes, the SRE-owning
assistant must [offer one optional T09 incident in conversation](ai-deploy-handbook.md#post-activation-incident-offer),
once after the Arc readiness handoff and SRE health/configuration checks.
Require all required checks to pass; do not rewrite the readiness report or
bypass failures. A yes lets the AI run the existing
T09 procedure with its agreed recovery fallback and genuine human Review
approval; a no leaves the activated lab running. Parent-only and Arc-only
activation do not trigger this offer. This is not automatic fault injection or
restoration of deleted incident history.

### Explicit Removed convergence

Removed is separate destructive intent, not an automatic step after Hibernate.
Save the live UAMI principal and necessary Inspect/audit evidence privately first.
Use the same explicit subscription/tenant/skin as deployment:

```powershell
.\scripts\Remove-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -WhatIf
# Only after approving that exact preview, rerun without -WhatIf.

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Removed `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -OutputFormat Json
```

The shared lifecycle implementation deletes only inventoried known identity-owned
grants at the known subscription/workload scopes, verified parent administrator
grants, named parent/diagnostics and UAMI. It deletes the dedicated group only
after resources/grants are absent. Unknown resources, IAM roles/scopes or other
SRE-group assignments block the full-removal preview; obtain ownership reconciliation,
not broad group deletion. Other principals' workload grants, shared Arc/Monitor
resources and private exports are outside the removal boundary.

Already absent or partially removed state converges directly; no intermediate
Hibernated requirement or identity recreation. Save the principal before deleting
it: if both live identity and saved principal are unavailable, removal stops and
Removed readiness reports external-grant verification pending. Failed reads are
failures, never interpreted as absence. Pending deletion is observed within the
deadline, not blindly resubmitted. Parent-lifetime cascade may remove its grants;
already absent exact targets are skipped. Local mocks cover these contracts;
this revised three-state lifecycle has not been exercised against the live estate.

## Evidence boundaries

Local tests cover fresh/reused bootstrap and refusal/failure shapes, not live
service reliability, a destructive lifecycle or a new incident. Preserve actual
approval/executor evidence separately; never treat narration as approval, use
unrestricted approval to bridge a missing capability, or delete the parent as a
configuration-repair shortcut. Historical results do not certify today's instance.
