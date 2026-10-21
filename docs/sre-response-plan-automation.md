# Reconstructing current-schema SRE handler and Review response plans

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
| `bicep/Apply-Extras.ps1`, legacy handler section | Optional legacy handler creation only when `customInstructions` is nonempty; not needed by modern filters |
| `recipes/azmon-lawappinsights` | `incidentPlatform: AzMonitor`, `Sev*` priorities, handling custom agent and built-in tool identifiers |

The current official templates route children through the data plane because ARM
child-resource availability is tenant/region dependent. This differs from the
article's high-level ARM description. We follow the pinned implementation, not
invented portal endpoints or the old MCP payload.

Authentication is the explicitly validated subscription's token for
`https://azuresre.dev`; the HTTPS endpoint is read from the named parent ARM
resource. Tokens remain in memory and are never exported. Authentication or
permission failures stop; setup does not switch accounts or grant access.

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

# Only after approving that exact migration/change scope:
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Apply `
  -BackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json> `
  -AllowLegacyMigration -WhatIf

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
objects; configured old routing is retired through the staged cutover below.
`-AllowLegacyMigration` is not needed for clean current-schema state and is not
itself user authorization.

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

## Legacy routing replacement: no parent deletion or legacy-handler update

User-observed portal errors on 2026-10-19 established two independent faults:
`P1/P2` are invalid priorities for `AzMonitor`, and legacy response-level
instructions/tools must move onto the handling custom agent. Title-only edits
cannot fix these errors. Full supported read-back confirmed the same faults.

An approved in-place attempt verified the custom-agent update, then stopped when
the service rejected PUT on an existing legacy handler: "same ID already exists;
use POST to update." Both pinned Microsoft templates and public Azure MCP source
show PUT, not a verified existing-handler POST contract. Do not infer or invent
POST from the error. The adapter now blocks such an entire plan before any write
with `SRE_EXISTING_HANDLER_UPDATE_UNVERIFIED`; it never retries that collision.

Modern filters route directly to `handlingAgent` without those legacy handlers:
the official AzMonitor recipe has no `customInstructions`, and the official
apply script creates a legacy handler only when that optional field is nonempty.
Default skins therefore use deterministic `container-app-restart-review-v3`
and `lob-arc-app-review-v3`. `sre.retiredResponsePlanNames` explicitly owns the
two v2 filters for retirement; never infer ownership from a name prefix.

The exact supported replacement preview preserves parent, identity, verified
custom agent, old filters/handlers and incident history:

1. Back up full objects before any PUT. Refuse unreviewed enabled extra plans,
   duplicate handlers, instruction overrides or an already-overlapping cutover.
2. Create/verify both new v3 filters **disabled**, with AzMonitor, Sev2, exact
   keywords, same custom handling agent and Review. No v1 handler is created.
3. Disable the explicitly retired v2 filters via the supported v2 filter PUT.
   Normalize invalid P1/P2 to Sev2 so the filter validates even while disabling.
   Preserve old titles, merge settings and all other unrelated fields. Never
   modify their legacy response handlers or delete their history.
4. Only after both old routes are verified off, enable the verified modern
   filters. There is a short routing gap, not duplicate routing or workload
   downtime; do not induce a fault during cutover.
5. Read back every operation and the complete final state. Each write compares
   the latest object against the expected backup/prior read-back, preserving
   server defaults for a newly staged object. Recheck for unowned enabled routes
   before every write and confirm retired routes remain off before each modern
   enable. Stop on concurrent target or routing changes.
   Read back an ambiguous timeout before retrying. At most three transient
   attempts; never bypass/retry 400/401/403.

This is not an atomic multi-object transaction. On failure stop with the backup
and staged/retired objects retained; rerun inspection before a separately approved
resume. Supported rollback can disable the modern filters, but does not certify
reactivation of legacy instructions. Never automatically restore invalid P1/P2
payloads, delete plans, or claim legacy rollback is functional. Replacement IDs
and retirement changes need approval distinct from the earlier same-ID/title
approval. No agent replacement, identity/role change or history deletion is needed.

The approved six-write cutover was verified live on 2026-10-19 through these
published v2 contracts: both modern filters enabled in Review/Sev2, both retired
filters disabled, and old handlers/history retained. This validates configuration
reconciliation, not a fresh incident/recovery rehearsal or destructive rebuild.
The first 2026-10-20 rehearsal verified alert/incident/RCA and operator fallback.
A separately authorized fresh retry then verified an independent v3 Review
investigation and actual SRE-managed-identity repair, matching tool completion,
healthy ready revision, full traffic and HTTP 200 with no operator reset.
The user reported approving the exact new portal card. No independent
`ApprovalDecision` event was returned in the bounded official audit query.
Only T09 cooldown was temporarily disabled to avoid configured thread merging;
the independent new thread was verified. The original enabled three-hour value
and Review mode were read-back restored.
Actual MonitorCondition resolved at 01:45:58 UTC, independently read back;
alert workflow state remained Acknowledged. This is separate from closing an incident.
Supported MCP thread reads expose narration, not an actionable approval
contract. Never use unrestricted approval/yolo to bridge that capability gap,
and never treat the agent saying "approved" as proof of approval or execution.

## Deployment, readiness and lifecycle

For a new/rebuilt layer, complete deployment can chain parent plus configuration:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -ConfigurationBackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>
```

Use `-ParentOnly` explicitly if only the parent is intended. It is not Ready.
Do not redeploy the running parent merely to repair legacy plans: inspect/apply
configuration directly. Full deployment follows skin resource names; custom
parent overrides require explicit reskinning or parent-only intent.

```powershell
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Ready `
  -OutputFormat Json -TimeoutSeconds 180
```

Readiness now uses full supported reads for instructions/tools, On/Review,
AzMonitor/Sev2/title/handler/service mapping, retired routing, active legacy
response fields, enabled three-hour cooldown and unreviewed enabled extra plans. Invalid active priorities,
active legacy settings or still-enabled retired routes are **fail**, not merely
unknown/pending. Retained disabled history is allowed. Missing/denied reads fail explicitly.
The Ready command does not ingest external rehearsal artifacts, so
`telemetry-and-alerts` always remains **pending** in that report, including after
the successful recorded retry. Pair its JSON/exit 2 with the separately authorized
run's actual evidence; do not fabricate exit 0 or rerun a fault to clear this
static gate. No read-only preflight certifies a new closed loop.

The Arc/SRE readiness JSON contract remains schemaVersion 1; status is
`pass|fail|pending|skipped`, exits 0 pass, 1 fail/error, 2 pending. The desired
configuration format is separately versioned.
Worker warnings are captured before job remoting and included as optional
`inspection-warnings` data, never printed ahead of the JSON document. They do not
hide required failures or change a required check's outcome.

### Approved hibernation and later reactivation

Normal hibernation **retains the dedicated SRE group and SRE-only UAMI**. It
deletes only the named parent, Application Insights and allowed service-created
Smart Detection Action Group, if present. It removes the six High-profile
external grants (or the Low-profile grants), known historical compatibility
grants if present, and the single direct parent SRE Agent Administrator assignment.
Other principals' external assignments are not selected. Extra resources,
unexpected roles/scopes or additional parent grants block the entire preview;
do not bypass the guard. Arc workloads remain untouched.

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
Retaining that object does not retain its external Contributor access. Normal
parking revokes grants; wake restores them through the same IaC and authorization
boundary. Full identity/group deletion is separately authorized cleanup, not a
switch on the normal parking script. Historical whole-group hibernation deleted
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
deadline on each Azure CLI call. Read-before-write compares remaining resource
and grant IDs and the retained principal; stop on drift or failed writes without
blind retries. Recheck Hibernated readiness separately before parking Arc.
It requires the exact retained UAMI, no parent/diagnostics, no external grants
and no direct parent administrator assignment. Principal-filtered ARM role
inventory includes below/above-subscription scopes; unknown scopes fail rather
than being missed. Direct SRE-group ARM assignment reads verify parent grants
after parent deletion; resource/ARG absence alone is insufficient.
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

## Evidence boundaries

Previously approved parent managed-resource append and T11 display-name-only
correction were read-back verified without changing parent Review, identity,
permissions, alert ID/location/query/actions or workload state.
Full read-back subsequently revealed the legacy-plan faults described above;
the earlier ARM-only pending report must not be presented as current routing
success. No current-schema migration or fresh closed-loop test is implied by
code, mocked tests or a preview. Do not delete the existing agent merely because
the user is willing to replace it: first establish and verify the repeatable
configuration path.
