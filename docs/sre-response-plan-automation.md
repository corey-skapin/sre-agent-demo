# Reconstructing current-schema SRE handler and Review response plans

**Deployment and lifecycle reference.** To present a demo that is already set up,
open the generated `.local/presenter-runsheet.md` (built from
[the SRE guide source](delivery-runsheet.md)); you don't need the setup commands
below. [The docs map](README.md) has the reading order.

## Setup path at a glance

Build, verify, present, park, wake and remove, in that order. Each row links to
the section holding its commands and rules.

**Before you start.** Every input is explicit; nothing comes from the ambient
`az` login.

- PowerShell 7.4+, Azure CLI 2.60+ with Bicep, and the `containerapp` and
  `connectedmachine` CLI extensions installed in advance. The scripts neither
  install nor check extensions, so a missing one surfaces as an Azure CLI
  "not a valid command" error.
- The subscription and tenant GUIDs and one validated private skin kept outside
  git ([rebuild prerequisites](../README.md#rebuild-prerequisites)). Validate the
  skin offline: `Initialize-SreConfiguration.ps1` with only the target and
  `-SkinPath` checks it against the schema and renders the desired configuration
  without any cloud request.
- The companion Arc estate is Active and its readiness check passes.
- The scenario prerequisites. They write to the Arc estate, so preview each with
  `-WhatIf` where it has one: the T09 Container App and restart alert (from the
  Arc repo); for T11, `New-LobArcAppMonitorAlert.ps1 -Action Create` and
  `Invoke-LobArcAppOnArc.ps1 -Action Deploy` (same explicit target and private
  skin); for the optional SQL route, the Arc estate's SQL engine and alert plus
  `SQL` in the private skin ([enable SQL](#optional-sql-scenario)). A missing alert
  surfaces only later as a failed `T11-alert` or `SQL-alert` readiness check,
  after the paid parent exists, and readiness does not check that the LOB app
  itself is installed.

| Step | Do this | Details |
| --- | --- | --- |
| Build | Read the offline render first: on a fresh parent it is the exact handler and plan set Deploy applies, while `-Inspect` needs an existing parent. Then `Deploy-SreAgent.ps1 ... -WhatIf`, then the same command with `-ApproveParentCreation -ConfigurationBackupPath <NEW_PATH_OUTSIDE_REPO.json>`, which applies the configuration straight after creating the parent. Add `-GrantAzureMonitorAlertAccess` to create the one required subscription grant, unless the retained identity already holds it | [Deployment, readiness and lifecycle](#deployment-readiness-and-lifecycle); expected previews and durations in [what to expect](#what-to-expect-previews-and-durations) |
| Verify | `Test-SreReadiness.ps1 ... -DesiredState Active`; every required check must pass | [Deployment, readiness and lifecycle](#deployment-readiness-and-lifecycle) |
| Present | Generate `.local/presenter-runsheet.md` ([handbook](ai-deploy-handbook.md#your-presenter-guide)). Before a fresh live fault run `Invoke-SreDemoRoute.ps1 -Scenario <SQL\|LOB\|ContainerApp> -Action Prepare`, afterwards `-Action Restore` | [Reset between demo runs](#reset-between-demo-runs) |
| Park | `Hibernate-SreAgent.ps1 ... -WhatIf`, then run it, then `Test-SreReadiness.ps1 -DesiredState Hibernated -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID>` | [Hibernation and later reactivation](#hibernation-and-later-reactivation) |
| Wake | Wake Arc first, then repeat Build and Verify; the retained identity and its grants are reused | [Hibernation and later reactivation](#hibernation-and-later-reactivation) |
| Remove | `Remove-SreAgent.ps1 ... -WhatIf`, then run it, then `Test-SreReadiness.ps1 -DesiredState Removed -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID>` | [Explicit Removed convergence](#explicit-removed-convergence) |

Change only configuration on a running parent with
`Initialize-SreConfiguration.ps1` (render, `-Inspect`, then
`-Apply -BackupPath <NEW_PATH>`); Deploy refuses an existing parent. See
[Render, inspect and apply](#render-inspect-and-apply). To see the closed loop after
setup, run one T09 incident
([handbook](ai-deploy-handbook.md#run-one-incident-after-setup-optional)).

On any denial, failed read or ambiguous write, stop and report it. A configuration
PUT is sent once and verified by read-only polling, never replayed
([troubleshooting](#post-write-visibility-and-troubleshooting)). Re-pin the
upstream protocol only through
[maintaining the coupling](#maintaining-the-coupling-and-handling-service-changes).

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
same PR. Run local tests and Bicep compilation. A pin update or a mocked pass
doesn't prove the live service accepts it, so test live separately.
Do not download/execute upstream scripts or silently follow a movable branch.

On authentication/denial, malformed/empty/paginated reads, unsupported legacy
state or schema drift, **stop explicitly**. Do not infer absence, guess POST,
fall back to another endpoint/account, grant permissions, delete the parent or
claim partial setup is ready. Apply backs up before writes; a later failure can
leave partial changes, so retain the backup and inspect before resuming. An
ambiguous PUT is verified by read-only polling, never replayed.

### Post-write visibility and troubleshooting

The service can accept a PUT before list reads expose the new properties.
Configuration apply sends each PUT **once**, then polls the supported read-only
collections with 2, 4, 8, 16 and capped 20-second backoff. Per-object and final
whole-configuration verification use the same pattern, for up to five minutes
without extending the existing overall `-TimeoutSeconds` deadline (default
180 seconds, maximum 600). Use an explicitly longer timeout when you need a longer
verification budget; no background verification continues after exit.

A timeout or transport error after PUT is an ambiguous outcome, not permission
to replay it. Read-only polling can establish that the write committed.
Denied/invalid writes or denied reads fail explicitly; unsupported routing,
foreign edits and partial target changes stop rather than being overwritten.
If the deadline expires, report **unverified**, retain the external backup and
Inspect again before reviewing any new apply. Do not retry the PUT to cure a
stale read. After fresh readback proves a completed step, resume only genuinely
unperformed operations within the same scope.

This delay occurred during both the one-time SQL cooldown reduction and its
restoration. Fresh reads proved the writes committed; neither PUT was repeated.
The helper now polls instead of treating the first stale read as failure.
The representative SQL preparation also exposed service `properties.etag`
rotation while property visibility caught up. Verification excludes that
post-write version token, but the pre-write concurrency comparison still checks
it. A changed token alone after our PUT is not a partial configuration change;
actual foreign property/routing changes still stop. Regression cases cover
both delayed visibility with rotated etags and an etag-only concurrent edit
before PUT. The successful cooldown write was not replayed.

If the contract changes, use the supported SRE portal following current
[subagent guidance](https://learn.microsoft.com/azure/sre-agent/create-subagent)
and [response-plan guidance](https://learn.microsoft.com/azure/sre-agent/response-plan).
Configure only the rendered handler and Review plans. You need a signed-in browser,
and your AI tool should inspect the actual visible controls rather than inventing
clicks. If that isn't available, say what is needed and stop.
Manual setup is not a verified automated bootstrap: report the remaining
read-back blocker until supported inspection works. Rebuilding a legacy parent
means deleting it and exporting its evidence first, and is never a failure fallback.

## Render, inspect and apply

```powershell
# Local deterministic render: no cloud requests. Also validates the skin.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json

# Supported read-only export plus exact in-place change preview.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Inspect

# Once you have read that exact change scope:
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Apply `
  -BackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json> -WhatIf

# Remove -WhatIf to apply it for real once you have read the proposed scope.
```

`<PRIVATE_LAB_FOLDER>\sre-skin.json` is your private skin, kept outside git. The
tracked `config\demo-skin.json` is only the fictional starting point and test
fixture: running an example with it silently applies its defaults (SQL off).
On a fresh parent the render is the full preview, because it is exactly what the
first `-Apply` creates; `-Inspect` needs an existing parent, so the complete
Deploy path reads the render before creation and applies right after it.

`schemaVersion: 2` desired configuration is not the old MCP request format.
Keep exports/previews outside git; they contain runtime IDs and full instructions.
`-Inspect` has no write or backup side effects. `-Apply` requires a new backup
filename in an existing directory outside the repo. It refuses to overwrite a
backup. An already-correct repeat run performs no PUT.

For clean reconstruction after a parent deployment, `-Apply` creates
only the verified-absent named custom agent and current filters. It does not
create legacy response handlers. For existing modern state it updates the same
objects, preserving unrelated fields. It does not migrate old instances.

## Exact desired demo configuration

The versioned `config\sre-handler.instructions.txt` is rendered using the skin.
Instructions and tools belong to the **handling custom agent**, not the response
plan. Built-in tools are explicitly `RunAzCliReadCommands`,
`RunAzCliWriteCommands`, `QueryLogAnalyticsByWorkspaceId`, and `SearchMemory`.
Write capability remains governed by parent and response-plan **Review**, scoped
RBAC and your approval in the SRE portal. No connector or new RBAC grant is created.

| Scenario | Skin plan label | Platform / priorities | Title contains | Handling agent / autonomy |
|---|---|---|---|---|
| T09 | `labels.containerResponsePlan` | `AzMonitor` / `["Sev2"]` | `containerapp-restarts` | `labels.agentName` / `Review` |
| T11 | `labels.lobResponsePlan` | `AzMonitor` / `["Sev2"]` | `labels.lobAlertTitleContains` | `labels.agentName` / `Review` |
| SQL (opt-in) | `labels.sqlResponsePlan` | `AzMonitor` / `["Sev2"]` | exact `Arc SQL lock timeout` | `labels.agentName` / `Review` |

Filters are enabled. The literal title is one keyword, never an `OR` expression.
The default impacted services remain `Azure Container Apps` and `Azure Arc`;
verify actual incident matching when you run an incident.
The renderer explicitly sets `mergeEnabled=true` and `mergeWindowHours=3` on
all configured modern routes, for fresh creation and reconciliation. This matches the
validated live settings; they are no longer left to service defaults.
Inspect actual cooldown before a repeat. Azure Monitor's scanner also
[merges firings from the same rule with a seven-day lookback](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts).
That scanner rule identity is separate from the filter's three-hour cooldown:
shortening the latter alone does not guarantee a fresh investigation. If you
override the cooldown temporarily, restore the exact original value afterwards;
neither closing a thread nor a resolved alert is a documented fresh-thread reset.
The custom agent investigates T09 and proposes only the expected app repair.
T10/T11 remain hybrid evidence plus Arc Run Command recovery that you run.
Do not claim reliable T11 RCA or autonomous Arc repair.

### Representative investigation instructions

The shared handler separates environment context, an evidence-led
investigation method and governance. Context supplies exact hosts/workspace,
Event/Perf/Heartbeat sources, event meanings and configured counter semantics.
Business criticality, customer impact and application-to-SQL topology are
explicitly unknown until evidence establishes them. The method builds a timeline
and blast radius, correlates available change evidence, ranks hypotheses with
supporting/contradicting evidence and confidence, and gives next checks you can run.
Durations, sessions, affected objects, wait resources and recovery are derived
from actual records, never prescribed by the incident-generation mechanism.

SQL and Windows application investigations remain diagnostic-only. The separate
Container App policy retains its existing flag-reset proposal, your specific Review
approval in the SRE portal and post-change health verification. The earlier SQL and
LOB rehearsals that motivated this wording are summarized in
[evidence boundaries](#earlier-sql-and-lob-rehearsals).

### Optional SQL scenario

SQL is enabled only by adding `SQL` to `sre.requiredScenarios` with an explicit
`sre.sqlTargetArcMachine` and the three SQL labels. SQL-disabled inputs need no
SQL fields; the example values are dormant, not deployment or readiness proof.
The renderer appends `config\sre-sql.instructions.txt` only when SQL is enabled.
It binds the exact SQL host/workspace and existing Event/Perf tools to real
`ArcSqlEngineDemo` 6201/6001 evidence and recommendations for you to act on, not
SQL execution, session termination or Arc repair. No connector or extra role is
created. All configured plan names and title keywords must be nonoverlapping.

The Arc estate supplies `al-<prefix>-sql-lock-timeout`, exact display name
`Arc SQL lock timeout - <prefix>`, existing LAW/Action Group and its canonical
host/source/JSON query. SRE readiness compares that frozen predicate, including
schemaVersion 2, detected state, Event6201 and actual error1222,
plus enabled Sev2, one-minute evaluation, fifteen-minute lookback, autoMitigate
and Count greater than zero for one of one evaluations. It checks the rule's
tags and exact IDs without running KQL or SQL. Guest engine, DCR collection,
cleanup and actual alert/SRE completion only show up when you run the SQL incident.
The self-recovered lock may no longer exist when the alert arrives.

The SQL event JSON is schema version 2. Its fields are `schemaVersion`,
`incidentId`, `state`, `instance`, `database`, `blockerSessionId`,
`victimSessionId`, `waitType`, `waitResource`, `sqlErrorNumber`, `lockTimeoutMs`
and `observedAtUtc`. The timeout setting must be observed from SQL, not inserted
as a predetermined event value. The owned row is `dbo.OrderProcessingCheckpoint`
(renamed from `dbo.IncidentProbe`), and `ARCDEMO` and `ArcDemoOrders` remain actual
evidence identities. The alert description is neutral and its title is unchanged.

## Reset between demo runs

The normal configuration remains Review with enabled three-hour cooldown.
First inspect the actual alert condition, previous investigation, last routing
time and current filter. An old Complete/Idle thread, a closed alert workflow,
and resolved MonitorCondition are different facts. Reuse an existing thread
for an evidence walkthrough when a genuinely fresh automatic run is unnecessary.

Live demo: a same-rule firing within seven days can reuse an old thread; use a fresh copy.
`Invoke-SreDemoRoute.ps1` has two actions; supply the explicit subscription, tenant and private skin.
Choose `-Scenario SQL`, `LOB` or `ContainerApp` (T09); the script handles log and metric alerts.
Run `-Action Prepare` shortly before the demo; it generates a unique name and disables the canonical.
The copy retains the same criteria, scope, Action Group, severity and filter-matching title.
Fire with the existing fault commands; this script does not fire, approve repairs or change cooldowns.
When you finish, run the same command with `-Action Restore`; it deletes only the owned copy.
Restore re-enables the canonical; **old evaluation windows can replay a ghost alert and email**.
Both actions support `-WhatIf` without local files; writes are single-submit with GET-only backoff.
On an ambiguous result, inspect the printed temporary name; never blindly repeat Prepare.

What the helper automates, and what to check around it:

1. Before Prepare, save external copies of the canonical scheduled-query rule and
   configuration. After Prepare, inspect the exact state: only the canonical rule
   is disabled and only the temporary rule is enabled. The temporary rule has the
   same host, predicate, LAW, Action
   Group, severity, evaluation frequency and lookback, and its title still matches
   the selected scenario filter. No extra IAM or connector is needed.
2. Require a zero-alert baseline for the exact temporary rule ID and fresh guest
   readiness before you fire one bounded incident. No manual SRE chat starts the
   investigation. Verify the actual thread source against the temporary rule; a
   distinct name doesn't prove successful fresh delivery.
3. Before Restore, wait until the detected source event has aged out of the
   canonical rule's entire lookback, with a margin. For the fifteen-minute SQL
   window, use at least sixteen minutes from actual detection, not from the call
   start. For the ten-minute LOB window, use at least eleven minutes from the
   **last** matching warning, not its first event or the helper start. Then
   Restore re-enables the unchanged canonical rule and deletes only the temporary
   rule.
4. Read back that the canonical rule is enabled, the temporary rule is absent and
   the selected filter still has `mergeEnabled=true` / `mergeWindowHours=3`, and
   compare all other configuration against the saved baseline. On an ambiguous
   write, read back without replaying the PUT, and resume only unperformed
   operations after verifying state. Report a failed or pending restore
   immediately; don't claim normal readiness.

If you instead reduce one filter's cooldown for a single run by hand (the helper
doesn't), reduce only the selected filter, retain merge enabled and Review, restore
it to three hours afterwards, and label the evidence **cooldown reduced for this
single run**. A one-hour setting was used for the fresh runs recorded in the
evidence boundaries. Never change the renderer's three-hour default or the other
scenario filters.

**Backfill warning:** the source-window expiry guard does not prevent Azure
Monitor from replaying an older evaluation after a disabled log rule is
re-enabled. In the 2026-11-02 SQL restore, the canonical rule was re-enabled and
fired again about three and a half minutes later against an older evaluation window. No new
SQL detection occurred; the system resolved that alert about eleven minutes later.
The existing canonical SRE thread then exposed merged count 2 and a last-fired
timestamp matching the replay, with no new canonical thread or contemporaneous
agent/query execution in the captured audit. Its initial merged-ID array omitted
the replay ID; a later read included it. After the next canonical restoration, the
same thread's merged count rose to 3. Treat each read's actual IDs/counts/times
separately rather than assuming the array is a complete, synchronous record.
Later `TrajectoryInsight` messages summarize the old investigation, not a new
query run; those summaries can repeat old incorrect conclusions.

Expect possible extra fired/resolved notifications from the unchanged Action
Group when restoring either rule, even after waiting out the lookback.
Compare source-event time, evaluation window, exact rule and SRE merge metadata;
do not confuse replay with another incident or count it as a new investigation.
No cheap, verified suppression workaround is established here. Do not silently
mute receivers, alter predicates, change cooldown again or delete/recreate the
canonical rule to conceal it. A read-only walkthrough of existing evidence
avoids this routing reset altogether.

This procedure changes routing resources and is not part of ordinary
presentation or configuration apply. Finish SQL capture, cleanup and restoration
before arming LOB. Resolve or close old alerts or threads only through a
supported operation; closure alone is not a documented way to clear the seven-day
merge history. A parent rebuild also loses history, but is not an acceptable reset
shortcut for a running demonstration.

## Fresh bootstrap and existing-state boundary

Default v3 filters route directly to the handling custom agent. A fresh bootstrap
creates one agent and two filters, or three with SQL enabled; a repeated bootstrap is no-op. Modern drift
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

Use the fallback above for unsupported existing state.

## Deployment, readiness and lifecycle

For a new/rebuilt layer, complete deployment can chain parent plus configuration:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -ApproveParentCreation `
  -ConfigurationBackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>
```

Use `-ParentOnly` explicitly if only the parent is intended. It is not Ready.
Do not redeploy the running parent merely to repair modern plans: inspect/apply
configuration directly. Full deployment follows skin resource names; custom
parent overrides require explicit reskinning or parent-only intent.

An existing exact managed Arc resource group covers its SQL host; readiness
does not require a redundant explicit host entry when that group is managed.
The host must still exist with its exact expected ARM ID. A foreign group is
not coverage. Fresh deployment can include the explicit SQL host as well.

### Existing-parent preview warning

A SQL rehearsal preview caught potential removal of `defaultModel`,
`monthlyAgentUnitLimit`, `experimentalSettings`, `sandboxConfiguration` and
`upgradeChannel` because the current parent template omits these existing
settings. **That parent deployment was not applied.** Deploy now refuses any
existing parent **before** IaC preview or deployment, so neither the five settings
nor unmodeled live properties can be stripped. There is no override switch.
Use configuration-only
Inspect/Apply for handler and filter updates on the Running parent. Do not treat
these settings as harmless read-only what-if noise or run a broad redeploy
to add a redundant host ID.

Fresh creation and retained-identity wake load all five values from
`config\sre-parent-settings.json`: Anthropic/Automatic, monthly active-flow AAU
limit 10000, Stable channel, the recorded experimental flags and the complete
Limited sandbox configuration. The limit does not cap always-on charges.
The [pinned Microsoft template](https://github.com/microsoft/sre-agent/blob/ff317310cca5894fcd42ccc32f5452c3f408cc3c/sreagent-templates/bicep/agent-core.bicep)
uses `2025-05-01-preview` for these writable properties; the
[2026 schema](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents)
does not expose AAU/experimental/sandbox settings. The parent module therefore
uses the pinned preview API, not an invented REST payload or an ignored property.
The [Learn API reference](https://learn.microsoft.com/azure/sre-agent/api-reference#agent-properties)
also documents model, limit, channel and experimental properties.

Actual creation requires `-ApproveParentCreation` because it starts the AAU meter;
WhatIf does not. The companion wrapper passes that switch only after you confirm
SRE creation there. After deployment, bounded read-only ARM inspection must match
every complete settings value before handler configuration proceeds. Failure
leaves the parent present and reports unverified setup; it never replays the
deployment or silently hibernates it. Review mode and the retained combined
identity shape are unchanged. Compilation and mocked read-back are not a live
recreation test; verify the same settings on your rebuild.

```powershell
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -DesiredState Active `
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
running an incident supplies that evidence, but it isn't a prerequisite to
clear this advisory item. No read-only preflight certifies a new closed loop.

The Arc/SRE readiness JSON contract remains schemaVersion 1; status is
`pass|fail|pending|skipped`, exits 0 pass, 1 fail/error, 2 pending. The desired
configuration format is separately versioned. Desired states are `Active`,
`Hibernated` and `Removed`; `Ready` remains the compatible Active alias/default,
not a fourth lifecycle state. Preserve required failures/pending outcomes;
the optional rehearsal item does not affect the overall status.
Worker warnings are captured before job remoting and included as optional
`inspection-warnings` data, never printed ahead of the JSON document. They do not
hide required failures or change a required check's outcome. A pending
`inspection-warnings` row on its own, next to an overall `pass`, is advisory. The
scripts drop the known harmless Python `SyntaxWarning` that an installed Azure CLI
extension can print on every call (seen with `monitor-control-service`); other
unrelated stderr, such as another extension's warning, still surfaces in that row,
so read its observed text before ignoring it.

### What to expect: previews and durations

A first-build `Deploy-SreAgent.ps1 -WhatIf` is complete when it ends with "What-if
complete. No resources were deployed." It lists 5 resources to create: the
dedicated SRE group, the parent, workspace Application Insights, the SRE-only UAMI
and the deployer's parent-scoped administrator assignment. It also reports 6
`Unsupported` diagnostics. Those are the six workload role assignments (Reader,
Log Analytics Contributor and Contributor on each Arc group): their IDs depend on
the UAMI principal, which does not exist yet, so Azure cannot preview them. The
Action Group ID is passed through with the casing Azure returns, and readiness
accepts it. Anything else, such as a delete, another role or scope, or a different
parent setting, isn't expected: stop and look into it before you create anything.

A wake `Deploy-SreAgent.ps1 -WhatIf` on the retained identity reads differently:
2 to create (the parent and the deployer's parent-scoped administrator
assignment), 7 to modify, 2 no change and 1 ignore, with no `Unsupported` rows
because the principal now exists. The 7 modifies are expected: six are the workload
role assignments the same principal already holds (what-if shows the literal
`principalId` against a `reference(...)` expression, a display difference), and one
is the retained Application Insights component (the template adds `Flow_Type` and
`Request_Source` defaults). The real run kept the same six assignment IDs and
created no duplicates. A delete, a new principal or role, or another scope isn't
expected: stop and look into it.

Measured live on 2026-11-05 (the first from-zero build): offline tests 48 s,
`-WhatIf` 75 s, complete Deploy 326 s (parent settings read-back, grant and
configuration apply included), `Test-SreReadiness.ps1 -DesiredState Active` 73 to
133 s, `New-LobArcAppMonitorAlert.ps1 -Action Create` 20 s,
`Invoke-LobArcAppOnArc.ps1 -Action Deploy` about 3 minutes (the guest part took
16 s; its result lists `GuestExitCode` and `GuestOutput` directly) and
`Initialize-SreConfiguration.ps1 -Inspect` 11 s. Give each command at
least 600 s. If a Deploy is interrupted after the parent exists, do not rerun it:
Deploy refuses an existing parent, even in `-WhatIf`. Run
`Initialize-SreConfiguration.ps1 -Inspect`, review it, then
`-Apply -BackupPath <NEW_PATH_OUTSIDE_REPO.json>`.

### Hibernation and later reactivation

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
outside the requested profile at the two workload groups, with one narrow
exception: an existing subscription Monitoring Contributor grant on the exact
retained UAMI, regardless of whether the parent exists or has a connected incident platform.
This is the documented [Azure Monitor alert-management prerequisite](https://learn.microsoft.com/azure/sre-agent/permissions).
It can be adopted or explicitly created with `-GrantAzureMonitorAlertAccess`.
Other roles, scopes,
principals or duplicate grants remain rejected. The same exact-grant tolerance
applies before wake, so retained platform access does not block reconstruction
after parent deletion. Hibernated readiness reports it separately from workload
grants. An unset/non-AzMonitor ARM selection on an existing parent emits an
optional readiness warning to review the portal fallback. That configuration
warning does not invalidate retained access or establish scanner health or
incident readiness. When AzMonitor is selected, missing subscription scanner
access is a required failure, not a reason to grant it silently.
This grant survived the live Hibernates of 2026-11-04 and 2026-11-05 (read-only
readiness confirms it), and on 2026-11-05 it alone satisfied the wake's required
`azure-monitor-alert-access` check, with no `-GrantAzureMonitorAlertAccess` switch
([evidence boundaries](#live-lifecycle-proof-2026-11-05)).
Reconciling extra grants is your call; nothing revokes them implicitly.
Otherwise, wake adopts existing direct grant names,
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
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Inspect |
  Out-File -LiteralPath <NEW_PRIVATE_EXPORT_PATH.json> -Encoding utf8 -NoClobber

.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -WhatIf

# Run it for real once you have read the preview. Hibernate is ConfirmImpact High,
# so an AI tool or other non-interactive host must pass -Confirm:$false; without it
# the run stops with "NonInteractive mode" before any change (measured live).
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -Confirm:$false

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -DesiredState Hibernated `
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
or permissions, and a wake rebuilds missing state through the same IaC.
Principal-filtered ARM inventory includes below/above-subscription scopes and
reports unknown scopes instead of missing them. Direct SRE-group ARM reads
distinguish deployer parent grants from UAMI workload permissions.
The documented [ARM assignment-list API](https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope?view=rest-authorization-2022-04-01)
is used with bounded, validated pagination, not Microsoft Graph or guessed SRE routes.
Absent/partial state can be inspected without mutation, but a missing UAMI fails
normal Hibernated even with a saved old principal. Only after SRE is verified
parked should Arc/networking be parked. Parent deletion avoids its always-on
cost, not all remaining storage, monitoring or Arc-service charges.

Fresh creation and wake already select `incidentManagementConfiguration.type:
AzMonitor` in `infra\modules\sre-agent.bicep`, through the
[supported parent ARM property](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents).
This is not a handler/filter configuration step or an optional data connector.
The opt-in grant script supplies the other half: the exact subscription Monitoring
Contributor assignment required by the
[Azure Monitor scanner guide](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts).
The normal rebuild path is **IaC platform selection plus the scripted
grant**, not a required portal connection click.

The existing read-only `incident-platform` readiness check reports the ARM `type`;
`azure-monitor-alert-access` checks the role independently. ARM exposes selection
and generic connection fields, not a scanner-connected/healthy status. A passing
selection check is therefore not alert-delivery proof. On **2026-11-02 UTC**, a
read-only GET of the running existing parent returned `type: AzMonitor`, with
`apiConnectionName`, `connectionName`, `connectionKey`, `connectionUrl` and
`oboUser` all empty. [Learn's platform guide](https://learn.microsoft.com/azure/sre-agent/incident-platforms)
says Azure Monitor needs no supplied credentials; neither that guide nor the ARM
schema specifies an additional required connector resource for this integration.
This existing-parent evidence does not establish how a fresh instance initializes.
**Fresh-agent intake from IaC plus the script worked on the 2026-11-05 from-zero
rebuild:** the T09 alert fired and the agent's thread appeared 17 seconds later,
with no portal connect click. That covers T09 only; SQL and LOB delivery on a
rebuilt agent stay unverified until you run and check each.

### Explicit Azure Monitor access grant

**Portal fallback only:** if `incident-platform` readiness shows an unset or
non-AzMonitor platform, use the documented **Incidents > Connect
an incident platform > Azure Monitor** flow, and understand its access
consequences first. Do not enable a quickstart Autonomous plan. The grant switch
creates only the exact subscription assignment; it doesn't do this fallback. Do not
disconnect another platform, replay guessed connection APIs, create an optional
connector as a prerequisite, or redeploy an existing parent to hide a warning. A
selected platform with no observed alerts needs scanner-access, rule/firing and
routing diagnosis, not a blind connection replay.

The subscription grant is **opt-in**, not an incidental portal side effect.
`Deploy-SreAgent.ps1 -GrantAzureMonitorAlertAccess` ensures it after parent
deployment and before handler configuration, using the newly returned UAMI
principal. Without that switch deployment does not grant subscription access;
the readiness check fails when AzMonitor is selected but its grant is missing.
The caller needs permission to assign roles at the subscription. No account
switch, Graph lookup, broad role reconciliation or permission bypass occurs.

To grant it separately from Deploy, omit the deploy switch and use:

```powershell
.\scripts\Grant-SreAzureMonitorAlertAccess.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -PrincipalId <NEW_UAMI_PRINCIPAL_ID> -WhatIf

# After reading that exact principal, role and subscription scope:
.\scripts\Grant-SreAzureMonitorAlertAccess.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -PrincipalId <NEW_UAMI_PRINCIPAL_ID> -GrantAzureMonitorAlertAccess
```

WhatIf creates no local files and previews at most one assignment. An existing
exact assignment is a no-op, including one originally named by the portal.
A fresh identity's principal cannot be previewed before Azure creates it; the
deploy preview says so rather than inventing a principal. Duplicate exact
grants, identity mismatch and inspection denial stop the operation. Creation
is submitted once and verified by bounded read-back; on a failed or ambiguous
request inspect the exact principal before retrying. Normal Hibernate retains
this grant; full Remove includes it in its exact UAMI assignment inventory.
ARM read-back does not prove effective authorization or incident delivery.

For the next demo, activate and verify Arc first. Deploy the SRE parent using the
retained identity, then render, Inspect and Apply the versioned modern custom agent and
v3 filters with a new external backup, or use complete deployment above.
Keep the same SQL-enabled setup input on wake so the SQL host managed-resource
ID, conditional instructions and third filter are restored. Dropping SQL from
that input while its enabled filter remains is refused as unowned routing,
not silently disabled or deleted. SRE Hibernate/Removed never deletes the Arc
SQL host, database, probe data or Arc alert; those stay with the Arc estate.
No additional workload role IDs are introduced by SQL.
Retired v2 objects, learned memory and deleted history are not restored. The
modern v3 filters explicitly restore enabled three-hour cooldown and Review/Sev2.
Do not replay an old full export as a PUT payload: it is reference
evidence, not a supported restore input. Optional repository authentication has to
be redone. Hibernate with the retained identity was proven live
on 2026-11-04 and again on 2026-11-05, together with a from-zero Deploy and a
wake from the retained identity ([what that established](#live-lifecycle-proof-2026-11-05)).
An in-place T09 repair proves none of these, and a proven wake does not certify a
later instance: repeat the readiness checks after every wake. To see the closed loop
on the woken agent, run [one T09 incident](ai-deploy-handbook.md#run-one-incident-after-setup-optional);
it doesn't restore deleted incident history.

### Explicit Removed convergence

Removed is separate destructive intent, not an automatic step after Hibernate.
Save the live UAMI principal and necessary Inspect/audit evidence privately first.
Use the same explicit subscription/tenant/skin as deployment:

```powershell
.\scripts\Remove-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -WhatIf
# After reading that exact preview, rerun without -WhatIf (and with
# -Confirm:$false in a non-interactive host: Remove is ConfirmImpact High).

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -DesiredState Removed `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -OutputFormat Json
```

The shared lifecycle implementation deletes only inventoried known identity-owned
grants at the known subscription/workload scopes, verified parent administrator
grants, named parent/diagnostics and UAMI. It deletes the dedicated group only
after resources/grants are absent. Unknown resources, IAM roles/scopes or other
SRE-group assignments block the full-removal preview; find out what they are
rather than deleting the group broadly. Other principals' workload grants, shared Arc/Monitor
resources and private exports are outside the removal boundary.

For an independently verified extra UAMI grant, such as a portal-created
Monitoring Reader assignment, pass `-AdditionalOwnedRoleAssignmentIds` with its
**full exact assignment ARM ID**, not a role name, scope, pattern or wildcard.
The principal must still match the saved/live UAMI; IDs must belong to the
selected subscription. This Removed-only allow-list does not exempt other
principals, parent administrators, unknown resources or duplicate platform
grants, and does not change Active/Hibernated readiness. Read the printed
ID/role/scope before you delete anything. It is not permission to discover
and auto-adopt all grants with that role.

The first live read-only Removed preview (2026-11-02) passed with
exactly **seven UAMI assignments** (six workload-group grants plus one exact
subscription Monitoring Contributor), **one parent administrator entry**,
**four resources** (parent, Application Insights, Smart Detection Action Group,
UAMI) and **one dedicated group**. No extra allow-list was needed. The preview
prints those categories and every exact assignment/resource ID; private
before/after inventories matched, and the parent remained Succeeded/Running.
Evidence stays in the single private lab folder. This proves preview/ownership
inspection only: no grant/resource was removed, no agent was hibernated and no
live Removed convergence or subsequent rebuild was exercised.

Already absent or partially removed state converges directly; no intermediate
Hibernated requirement or identity recreation. Save the principal before deleting
it: if both live identity and saved principal are unavailable, removal stops and
Removed readiness reports external-grant verification pending. Failed reads are
failures, never interpreted as absence. Pending deletion is observed within the
deadline, not blindly resubmitted. Parent-lifetime cascade may remove its grants;
already absent exact targets are skipped. Local mocks cover these contracts;
the destructive Removed convergence remains untested against the live estate.

## Evidence boundaries

Local tests cover fresh/reused bootstrap and refusal/failure shapes, not live
service reliability, a destructive lifecycle or a new incident. Keep actual
approval and executor evidence separate; never treat narration as approval, use
broad permissions to bridge a missing capability, or delete the parent as a
configuration-repair shortcut. Historical results do not certify today's instance.

### Live lifecycle proof, 2026-11-05

One live session that used only these docs ran a from-zero build, one T09
incident, then Hibernate, wake and Hibernate again. It established the following
and nothing beyond it.

- **Build.** Deploy took 326 s and `Test-SreReadiness.ps1 -DesiredState Active`
  passed 21 of 21 required checks.
- **Hibernate** took 180 s the first time and 151 s the second. Each run ended with
  `-DesiredState Hibernated` readiness passing (7 checks, including the 2 required
  ones) using the saved principal. The first execute attempt without
  `-Confirm:$false` stopped after 7 s with "NonInteractive mode" and changed
  nothing: a non-interactive host must pass `-Confirm:$false` to Hibernate and Remove.
- **Wake.** The `-WhatIf` preview took 90 s and showed the counts in
  [what to expect](#what-to-expect-previews-and-durations). Deploy took 289 s and
  Active readiness passed 21 of 21 required checks. No `-GrantAzureMonitorAlertAccess`
  was given: the retained subscription-scope Monitoring Contributor grant alone
  satisfied `azure-monitor-alert-access`.
- **Identity.** The UAMI principal and all seven of its role-assignment IDs were
  identical before, between and after the cycles, with no duplicates, so the
  deterministic IDs held. The deployer's parent-scoped administrator assignment was
  recreated with the new parent, and the parent's system principal changed.
- **Survives Hibernate:** the SRE group, the UAMI, its seven grants (six workload,
  one subscription-scope Monitoring Contributor), workspace Application Insights with
  the first run's audit telemetry in the Arc workspace, the Smart Detection action
  group, and the private exports and backups.
- **Lost:** the parent, its handler and three response plans (the wake rebuilds them
  from the versioned assets), every thread and message, memory notes and the approval
  card history. A woken agent starts with no threads.
- **First T09 run, with its caveat.** The alert fired 5.2 minutes after the fault
  command finished, the agent's thread appeared 17 seconds later, and the Review card
  was pending about 7 minutes after the fault. No Approve arrived before the agreed
  20-minute deadline, so the app was reset by hand. The Approve registered
  about 21 minutes after the deadline, on the by-then stale card; the agent's own write
  then ran under its managed identity as a no-op, and its RCA said a person had fixed
  the app first. Alert, thread, card and executor each worked, but **a clean in-window
  repair, approved before the deadline and executed by the agent without the manual
  reset, is still unproven on a rebuilt agent.** SQL and LOB incidents on the rebuilt
  agent were not run.
- **Not covered:** the destructive Removed convergence, and any instance other than
  the one tested. Repeat the readiness checks after every wake.

### Earlier SQL and LOB rehearsals

Live rehearsals on 2026-11-01 and 2026-11-02 (one SQL run, one SQL rerun and one LOB
warning run, each on an earlier agent instance) shaped the handler instructions.
They don't certify the current instance.

- **First SQL run.** A real lock timeout (1222) was detected and its recovery
  verified seven seconds later. Azure Monitor fired about 50 seconds after
  detection and ran the existing Action Group a second later, and an automatic
  Review investigation arrived about two minutes after detection, with no manual
  SRE message, cooldown bypass or second fault. The existing managed Arc group
  covered the SQL host, so only handler instructions and one filter were applied; a
  repeat apply was a no-op and the parent properties were unchanged. The report
  distinguished the historical lock timeout, self-recovery and the next checks for
  you. But it claimed 62 Perf rows where the actual aggregated result header said
  12, and it inferred "no incident platform" from empty optional connector files
  despite actual Azure Monitor delivery. The message API preserved the report but
  omitted the built-in Event/Perf result objects. The audit paired two query
  ToolStart/ToolEnd calls, but both ToolOutput strings were truncated to 1,003
  characters, so **full raw query output was not obtained**. The audit marked the
  incident assisted, not mitigated; no SQL or guest repair was observed. Action Group
  execution did not verify email receipt, and Complete/Idle did not prove a resolved
  Monitor condition or a closed incident.
- **Reporting correction.** A handler-only update then required exact query-header
  row counts, a distinction between aggregated rows and source samples and no
  connector-file inspection as a test of incident-platform connectivity, and to claim
  delivery via Azure Monitor only when actual alert/audit metadata establishes it.
  A maintenance message in a new, non-incident thread asked the agent to correct
  its memory note: the raw file-edit result reported success, but independent
  memory search and the returned file citation both failed with HTTP 400, and the
  next automatic investigation's read-file result contained the corrected note.
  **Memory search remains unverified.** The memory document APIs are not a general
  file-editing interface: don't invent a file-edit endpoint, alter the provider to
  bypass a failed search, or send extra maintenance messages.
- **SQL rerun.** One distinct temporary rule, one real fault, and a cooldown
  reduced for that single run. Detection, recovery, the alert and a different
  automatic thread (sourced from the exact temporary rule) followed within about two
  minutes, and the report arrived about three minutes after detection. The completed
  query headers were 2 Event rows and 119 Perf rows; the report quoted both exactly
  and described the Perf rows as individual samples (a projection, so not comparable
  with the first run's 12 summary rows). It did not repeat the platform inference. No
  approval request, SQL/guest execution or repair was observed, and the Arc estate
  independently verified the owned-session cleanup and a healthy Orders worker. Full
  raw output was still truncated at 1,003 characters, so headers and partial results
  don't independently verify every number in a narrative. The distinct rule identity
  avoided the same-rule merge; closing an old thread did not.
- **LOB warning.** One `WarnForDuration 120` ran on the existing worker with no
  restart, kill or redeployment: the helper restored the original config with exit 0
  and the same PID. Eight real Event 4200 warnings were generated and no 4100/4101
  errors. Azure Monitor fired about a minute into the warning, an automatic
  exact-rule investigation arrived about a minute after that, and five KQL calls
  completed with result headers of 33, 1, 8, 7 and 1 rows (the report correctly
  distinguished eight Perf summary rows from 91 source samples). No manual SRE chat,
  approval request, guest execution or SRE repair was observed. But the narrative
  wrongly inferred ongoing warnings from older ingested events and excluded host
  pressure too strongly from sparse counters: the healthy Event 4000 after the
  warning was not ingested until after the investigation started. Ingestion lag
  explains why a query can miss recovery, not why an older warning establishes
  current state, and a Fired/Acknowledged alert can retain the warning inside its
  ten-minute lookback after recovery. A config-only handler refinement now requires
  evidence age relative to investigation time, explicit ingestion lag and evidence
  newer than the last change before calling a fault active, ongoing or resolved;
  otherwise say "latest evidence at HH:MM UTC, current state unconfirmed". Sparse
  counters support "not observed in the available counters", not "ruled out".
  **That refinement has not been tested by another live incident.**
- **Instruction rewrite.** After the handler was rewritten to drop incident-mechanism
  cues and prescribed causes, a later SQL and LOB rerun was more representative: it
  derived timings and sessions from returned records, ranked a contemporaneous Run
  Command as an unproven change hypothesis (a same-name VM/Arc identity does not
  establish a call path) and separated producer-reported recovery from independent
  checks. It was still not a clean pass on every wording requirement: the old memory's
  "probe" terminology persisted in the SQL report, and the LOB report discovered the
  warning mode through the Run Command output, which is real evidence, not a failure.
  Old memory is untrusted historical context, not a current cause or timing
  contract, and it can still guide query selection. Don't hide telemetry identifiers
  or rewrite evidence to look real.
- **Change Tracking.** Change Tracking and Inventory was assessed as a source of
  change evidence for the LOB config and rejected for this incident: Windows file
  collection runs every 30 to 40 minutes (and can be delayed up to six hours), so a
  two-minute edit restored to identical bytes can fall between scans. It suits
  persistent drift, not a short warning, and an observed change would still show
  correlation, not causation. An application-level configuration audit event could
  capture short-lived changes, but that would be a telemetry-contract change. No
  extension, DCR, tracked file, storage or permission was changed for the
  assessment.
