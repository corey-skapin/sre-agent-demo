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
| `bicep/Apply-Extras.ps1`, legacy handler section | Named handler PUT on `/api/v1/incidentPlayground/handlers/{id}` with the existing ID, filter ID, descriptive fields, instructions, tools, steps and incidents |
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
only the verified-absent named custom agent and filters. It does not create legacy
response handlers. For an existing deployment, it updates those same objects.
`-AllowLegacyMigration` is not needed for clean current-schema state, and is not
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
The custom agent investigates T09 and proposes only the expected app repair.
T10/T11 remain hybrid evidence plus **operator** Arc Run Command recovery.
Do not claim reliable T11 RCA or autonomous Arc repair.

## Existing legacy-plan migration: no parent deletion needed

User-observed portal errors on 2026-10-19 established two independent faults:
`P1/P2` are invalid priorities for `AzMonitor`, and legacy response-level
instructions/tools must move onto the handling custom agent. Title-only edits
cannot fix these errors. Full supported read-back confirmed the same faults.

The safest proposed migration reuses the existing parent, identity, custom agent,
both filter IDs and both response-handler IDs:

1. Back up all observed subagents, filters and legacy response handlers before
   any PUT. Refuse unreviewed enabled extra plans, duplicate handlers or an
   instruction override. Review exact old/new objects from `-Inspect`.
2. Update the existing handling custom agent with the rendered instructions and
   explicit tools first. T09 and hybrid recovery steps now live there.
3. On each existing legacy response handler, clear `customInstructions`, `tools`
   and `incidentProcessingGuide`. Preserve its ID, name, description, filter ID
   and incident associations. Do not create a second handler.
4. Update the same filter to `Sev2`, the single keyword, intended handling agent,
   enabled state and `Review`. Preserve unrelated fields such as merge window.
5. Immediately read back after each PUT, then verify the complete desired state.
   A concurrent change detected before a write stops the operation. A timeout is
   read back before any retry; only transient failures are retried, at most three
   attempts. A 400/401/403 is never bypassed or retried.

This is not an atomic multi-object transaction. Retain the backup and inspect
partial state if any step fails. Do not automatically restore invalid P1/P2
payloads, delete plans, or claim a failed legacy rollback succeeded.
Changing a plan beyond the old title-only approval needs fresh scoped approval.
No agent replacement, new identity, role change or history deletion is necessary
for this proposed migration.

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
AzMonitor/Sev2/title/handler/service mapping, legacy response fields and unreviewed
enabled extra plans. Invalid priorities or retained legacy settings are **fail**,
not merely unknown/pending. Missing/denied reads fail explicitly.
Fresh telemetry/alert-to-thread/RCA/approval/recovery remains **pending** until
a separately authorized rehearsal supplies evidence. No read-only preflight
injects a fault or certifies a new closed loop.

The Arc/SRE readiness JSON contract remains schemaVersion 1; status is
`pass|fail|pending|skipped`, exits 0 pass, 1 fail/error, 2 pending. The desired
configuration format is separately versioned.

For separately authorized hibernation, export incident/thread/audit evidence and
save the user-assigned identity principal ID first. Deletion loses custom agents,
plans, incidents/threads, memory and connector state. Arc workspace records follow
its own retention. Verify Hibernated using the saved principal ID. Re-enable Arc,
then parent, current-schema custom agent/plans, read-back and rehearsal.
Repository authentication remains a separate opt-in authorization.

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
