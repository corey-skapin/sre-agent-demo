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
The renderer does not manage cooldown fields. Existing merge settings are
preserved; new filters receive service defaults. The validated live routes had
`mergeEnabled=true` and a three-hour window, not a repo-enforced universal default.
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
response fields and unreviewed enabled extra plans. Invalid active priorities,
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

Hibernation deletes the named SRE group: parent, UAMI, Application Insights and
the allowed service-created smart-detection Action Group if present. It removes
only known-role assignments for that UAMI at the subscription and existing
Arc/observability and infra group scopes. Other principals' external assignments
are not selected. Extra group resources, unexpected roles or out-of-scope grants
block cleanup; do not bypass the guard. Arc workloads remain untouched here.

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

Check each command's exit status before continuing. Group deletion uses
`--no-wait`: submission is not completion. Recheck Hibernated readiness within
a bounded observation window; stop/report failures or pending timeout rather
than resubmitting deletion blindly. A missing old principal leaves orphan-RBAC
verification pending. Only after SRE is verified off should the Arc owner park
Arc/networking. SRE deletion avoids the agent's always-on cost, not all remaining
storage, monitoring or Arc-service charges.

For the next demo, activate and verify Arc first. Deploy the SRE parent and new
identity, then render/Inspect/approve/Apply the versioned modern custom agent and
v3 filters with a new external backup, or use complete deployment above.
Old principal grants, retired v2 objects, learned memory and deleted history are
not restored. Do not replay an old full export as a PUT payload: it is reference
evidence, not a supported restore input. Optional repository authentication needs
explicit reauthorization. An in-place T09 repair proves neither a fresh bootstrap
nor a deletion-to-Ready round trip; those live lifecycle gates remain untested.

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
