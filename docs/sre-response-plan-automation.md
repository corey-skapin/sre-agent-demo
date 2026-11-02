# Reconstructing current-schema SRE handler and Review response plans

**Deployment/lifecycle operator reference.** For an already provisioned demo,
present from the generated `.local/presenter-runsheet.md`, using
[the SRE guide source](delivery-runsheet.md), not the setup
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
ambiguous PUT is verified by read-only polling, never replayed.

### Post-write visibility and troubleshooting

The service can accept a PUT before list reads expose the new properties.
Configuration apply sends each PUT **once**, then polls the supported read-only
collections with 2, 4, 8, 16 and capped 20-second backoff. Per-object and final
whole-configuration verification use the same pattern, for up to five minutes
without extending the existing overall `-TimeoutSeconds` deadline (default
180 seconds, maximum 600). Use an explicitly reviewed timeout when a longer
verification budget is needed; no background verification continues after exit.

A timeout or transport error after PUT is an ambiguous outcome, not permission
to replay it. Read-only polling can establish that the write committed.
Denied/invalid writes or denied reads fail explicitly; unsupported routing,
foreign edits and partial target changes stop rather than being overwritten.
If the deadline expires, report **unverified**, retain the external backup and
Inspect again before reviewing any new apply. Do not retry the PUT to cure a
stale read. After fresh readback proves a completed step, resume only genuinely
unperformed operations within the approved scope.

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
| SQL (opt-in) | `labels.sqlResponsePlan` | `AzMonitor` / `["Sev2"]` | exact `Arc SQL lock timeout` | `labels.agentName` / `Review` |

Filters are enabled. The literal title is one keyword, never an `OR` expression.
The default impacted services remain `Azure Container Apps` and `Azure Arc`;
verify actual incident matching in the separately authorized rehearsal.
The renderer explicitly sets `mergeEnabled=true` and `mergeWindowHours=3` on
all configured modern routes, for fresh creation and reconciliation. This matches the
validated live settings; they are no longer left to service defaults.
Inspect actual cooldown before a repeat. Azure Monitor's scanner also
[merges firings from the same rule with a seven-day lookback](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts).
That scanner rule identity is separate from the filter's three-hour cooldown:
shortening the latter alone does not guarantee a fresh investigation. Any
temporary override and exact restoration need scoped approval; neither closing
a thread nor a resolved alert is a documented fresh-thread reset.
The custom agent investigates T09 and proposes only the expected app repair.
T10/T11 remain hybrid evidence plus **operator** Arc Run Command recovery.
Do not claim reliable T11 RCA or autonomous Arc repair.

### Representative investigation instructions

The shared handler now separates environment context, an evidence-led
investigation method and governance. Context supplies exact hosts/workspace,
Event/Perf/Heartbeat sources, event meanings and configured counter semantics.
Business criticality, customer impact and application-to-SQL topology are
explicitly unknown until evidence establishes them. The method builds a timeline
and blast radius, correlates available change evidence, ranks hypotheses with
supporting/contradicting evidence and confidence, and gives human next checks.
Durations, sessions, affected objects, wait resources and recovery are derived
from actual records, never prescribed by the incident-generation mechanism.

SQL and Windows application investigations remain diagnostic-only. The separate
Container App policy retains its existing flag-reset proposal, specific human
Review approval and post-change health verification. Only its scenario narration
was removed; neither its tools nor approval authority changed. This wording
change has no new Container App live test until the coordinated step-7 rehearsal.

The rewrite was applied config-only on **2026-11-02 at 01:01:07 UTC** with an
external backup, repeated no-op and independent zero-operation Inspect.
Filters, assigned tools and full ARM parent properties were unchanged. This
configuration proof is not a new SQL or LOB investigation result; record those
separately after the one-per-scenario coordinated reruns. Existing memory remains
on this running agent and may influence later output; distinguish actually
observed reuse from merely having old notes available.

#### SQL comparison from the single authorized rerun

The version-2 SQL incident on **2026-11-02 at 01:50:24 UTC** produced a fresh
automatic Review investigation, completed at **01:55:03 UTC**. The Arc owner
independently verified one matching incident, both version-2 event payloads and
post-incident Orders/host/session health. That independent operator evidence is
separate from what the SRE agent itself queried and concluded.

| Aspect | Earlier SQL reports | New SQL report |
|---|---|---|
| Cause and duration | Controlled-probe narrative, preset rollback/timeout contract | Evidence-derived sessions, key wait and 7.39-second producer-reported recovery; blocker hold time unknown. |
| Change correlation | Known incident mechanism substituted for investigation | Ranked a contemporaneous Run Command as an unproven hypothesis; same-name VM/Arc identity does not establish a call path. |
| Impact and health | Recovery contract implied cleanup and continuing processing | Unknown business impact; producer-reported recovery is not independent session cleanup or current health. |
| Metrics and coverage | First report confused summary rows with sample totals | Separates summary rows from source samples and qualifies 60-second host counters; two initial wrong-workspace queries failed and were disclosed. |
| Historical memory | Reused old contract and presentation framing | Read the old notes, but rejected their cleanup assertion. Residual "probe" terminology remains unsupported by the normal commit/read event text. |

This is substantially more representative, **not a clean pass on every wording
requirement**. The old memory contained "probe" terminology and was read in this
run; the normal 6000 records do not contain that label. Its exact causal origin
cannot be proven, but the unsupported term persisted. The report also states
that no Azure Monitor comment tool exists more strongly than tool discovery can
establish. Evidence-only terminology, workspace-ID resolution before querying
and capability-absence wording were tightened config-only at
**02:10:27 UTC**, after SQL routing restoration and before LOB preparation.
An external backup, repeated no-op and independent zero-operation Inspect
verified that only handler instructions changed; filters and parent properties
were unchanged. This refinement has no additional SQL live run.

SQL routing restoration was verified at **02:07:47 UTC**: canonical enabled,
temporary absent and normal merge-enabled three-hour routing restored. The
expiry guard used the actual 6201 timestamp plus sixteen minutes, not alert
delivery time; possible canonical replay remains a separate notification risk.

The captured audit has 74 records and five successful KQL result headers:
57 event rows, 2 heartbeat summaries, 12 counter summaries, 32 raw counter rows
and 3 event summaries. Two earlier KQL attempts failed before the current
workspace ID was resolved. Several audit outputs truncate at 1,003 characters,
so these headers and exact KQL do not independently verify every numerical
statement in the narrative. Detailed thread identities and raw captures stay in
private evidence, not tracked configuration.

#### Audit of the earlier SQL and LOB investigations

The saved first SQL run, SQL rerun and LOB investigation show multiple sources
of rehearsal framing. A quoted telemetry identifier is not, by itself, invented
analysis; do not hide those identifiers or rewrite the evidence to look real.

| Demo-tied element | Source | Observed effect / change |
|---|---|---|
| "demo resources", T09/T10/T11, "proven ... wow", prior RCA stall | Shared instructions and handoff description | Removed presentation/history claims from operational instructions. |
| SIMULATE_CRASH and its reset | Existing Container App recovery policy | Retained only under that incident type; not SQL/LOB diagnosis. |
| "simulated dependency warning", "no induced host load" | Shared instructions, not the Event 4200 message | LOB narrative selected a simulation/config-switch cause and excluded pressure; removed prescribed cause. |
| Twelve-second rollback and 5000-ms lock timeout | SQL instructions; timeout/block-limit values also appear in actual JSON | Narrative repeated controlled timing; now derive values and durations from returned records. |
| Owned `dbo.IncidentProbe` row and preserved Orders worker | SQL instructions; object also named in narrative | Removed object/mechanism and guaranteed business-continuity claims from instructions. |
| Recovery only after rollback, successful test query and owned-session cleanup | SQL instruction contract | Both SQL reports acknowledged relying on that contract, not separate checks in returned payload; now distinguish producer assertion from independent proof. |
| Fifteen-minute alert window and expected late delivery | SQL instructions and actual rule metadata | Now inspect the rule's actual window instead of assuming it. |
| "Do not call this a deadlock" | SQL instructions | Replaced outcome-directed phrasing with error-code/wait/engine-based classification. |
| Fault/reset/helper/operator-recovery narration | Shared/SQL instructions and operator runbooks | Removed incident-generation procedures from diagnosis; retain governance without prescribing a recovery story. |
| Controlled timeout / "probe self-recovers" | Earlier SQL alert description, supplied to both old incident threads | Neutral description now deployed by the Arc owner; historical thread input remains unchanged. |
| T11/fault wording | Earlier LOB alert description/title; 4100 source message and config names | Neutral description now live, titles unchanged; 4100 wording changed in source only. The 4200 warning itself does not say simulation. |
| `scenario=sql-lock-timeout`, `ARCDEMO`, `ArcDemoOrders`, `lockTimeoutMs`, `maxBlockSeconds` | Actual SQL event JSON | Preserve and quote only when relevant; no instruction supplies their values. |
| Arc/demo/source-script/repository names and revision | Resource identities and LOB event context | Genuine provenance, not proof of cause or repository access. |
| "controlled probe", "intended controlled test", "recovered by design" | SQL narratives, supported in part by instructions/alert text | Do not let a familiar mechanism replace ranked evidence-based investigation. |
| "simulation switched on", no load "by design" | LOB narrative, strongly cued by instructions | Not established by Event 4200 alone; require change evidence. |
| Prior SQL payload/rehearsal notes | Saved memory read by later SQL/LOB threads | Memory is untrusted historical context, not a current cause or timing contract; no new maintenance message authorized. |
| Ongoing warning and host pressure "ruled out" | LOB narrative despite stale/incomplete data | Preserve evidence-age, ingestion-lag and sparse-counter guardrails. |

The coordinated follow-up deployed neutral alert descriptions (titles unchanged),
renamed `dbo.IncidentProbe` to `dbo.OrderProcessingCheckpoint`, and introduced SQL event
schema version 2 without `scenario` or `maxBlockSeconds`. The retained fields are
`schemaVersion`, `incidentId`, `state`, `instance`, `database`,
`blockerSessionId`, `victimSessionId`, `waitType`, `waitResource`,
`sqlErrorNumber`, `lockTimeoutMs` and `observedAtUtc`. The timeout setting must be
observed from SQL, not inserted as a predetermined event value. `ARCDEMO` and
`ArcDemoOrders` remain actual evidence identities. The Arc owner verified the emitter update without a worker restart at
**2026-11-02 01:30:17 UTC** and the exact canonical version-2 predicate at
**01:39:10 UTC**, before SRE cloned the temporary rule. Normal Orders commits,
the new checkpoint and absence of owned sessions were checked separately.
Source readiness pins version 2, exact host/source/state/error; deployment and
a new investigation remain separate live gates. Companion source revision and
deployment evidence stay in the private handoff rather than operator-owned
repository defaults.
The LOB 4100 message's source wording is also neutralized to "Fatal
order-processing error" without changing its event ID, exit behavior or config
controls. This source-only string change is not deployed to the running LOB
worker; the approved warning uses the unchanged 4200 path.

#### Change Tracking feasibility: assessment only

[Change Tracking and Inventory](https://learn.microsoft.com/azure/automation/change-tracking/overview-monitoring-agent)
supports Arc-enabled Windows file hashes and optional before/after content;
change metadata goes to `ConfigurationChange`, while `ConfigurationData` is
scheduled inventory. Tracking the LOB `appsettings.json` could provide realistic
configuration-change evidence if its CT extension, DCR, tracked path and workspace
coverage were verified. Content comparison additionally needs approved storage
and data handling. No extension, DCR, tracked file, storage or permission was
changed for this assessment; actual coverage/latency remains unverified.

Current [collection limits](https://learn.microsoft.com/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix#change-tracking-and-inventory-data-collection)
document Windows file collection every **30 to 40 minutes**, not near-real-time
application auditing. The same reference warns that high network traffic can
delay records up to **six hours**. A two-minute edit restored to identical bytes
can occur entirely between scans and leave no observed hash difference.
Therefore CT is feasible for persistent drift/historical correlation, **not a
reliable root-cause signal for this short warning**, and was **assessed and
rejected for this incident**. Even an observed change
establishes correlation, not causation by itself. A future application-level
configuration audit event could capture short-lived changes more faithfully,
but would be a separately approved telemetry-contract change.

SQL is enabled only by adding `SQL` to `sre.requiredScenarios` with an explicit
`sre.sqlTargetArcMachine` and the three SQL labels. SQL-disabled inputs need no
SQL fields; the example values are dormant, not deployment or readiness proof.
The renderer appends `config\sre-sql.instructions.txt` only when SQL is enabled.
It binds the exact SQL host/workspace and existing Event/Perf tools to real
`ArcSqlEngineDemo` 6201/6001 evidence and operator-only recommendations, not SQL
execution, session termination or Arc repair. No connector or extra role is
created. All configured plan names and title keywords must be nonoverlapping.

The Arc owner supplies `al-<prefix>-sql-lock-timeout`, exact display name
`Arc SQL lock timeout - <prefix>`, existing LAW/Action Group and its canonical
host/source/JSON query. SRE readiness compares that frozen predicate, including
schemaVersion 2, detected state, Event6201 and actual error1222,
plus enabled Sev2, one-minute evaluation, fifteen-minute lookback, autoMitigate
and Count greater than zero for one of one evaluations. It checks the owner's
tags and exact IDs without running KQL or SQL. Guest engine, DCR collection,
cleanup and actual alert/SRE completion require the separate approved rehearsal.
The self-recovered lock may no longer exist when the alert arrives.

### Observed SQL rehearsal

One authorized SQL rehearsal on **2026-11-01 UTC** produced a real 1222 detected
event at 23:24:21 and verified recovery at 23:24:28. Azure Monitor fired at
23:25:12, executed the existing Action Group at 23:25:13 and delivered an
automatic Review investigation at 23:26:22. No manual SRE message, cooldown
bypass, second fault or LOB fault was used. The existing managed Arc group
covered the SQL host; only handler instructions and one filter were applied.
The repeated configuration apply was no-op and the parent properties stayed
unchanged. This is SQL-scene evidence, not full Active-estate readiness.

The final thread reported investigation Complete, with its narrative at
23:27:47. The documented message API preserved the complete report but omitted
the built-in Event/Perf result objects. Thread-bound Application Insights audit
paired two actual query ToolStart/ToolEnd calls and preserved their inputs and
partial actual results. Both ToolOutput strings were truncated to 1003
characters; **full raw query output was not obtained**. The report correctly
distinguished historical lock timeout, self-recovery and operator-only steps.
Its Perf claim of 62 rows disagreed with the actual aggregated result header of
12 rows; do not confuse source samples with returned summary rows.

The agent also incorrectly inferred no incident platform from empty optional
connector configuration, despite actual AzMonitor delivery. Its connector-file
grep exited 1, and internal memory writes were recorded. No SQL/guest repair was
observed; the audit marked assisted true and mitigated false. Action Group
execution did not verify email receipt. Investigation completion/Idle did not
prove resolved MonitorCondition or a closed incident. Keep raw target-bound
evidence private. This first run remains historical evidence, including its
incorrect claims; do not silently rewrite it as a corrected investigation.

### Reporting correction and memory limits

On **2026-11-02 UTC**, a handler-only configuration update applied the reporting
correction, with an external backup and a repeated no-op verified at 00:01:50.
The general handler and optional SQL instructions require exact query-header
row counts, distinguish aggregated rows from source samples, and forbid
connector-file inspection as a test of incident-platform connectivity. Claim
delivery via Azure Monitor only when actual alert/audit metadata establishes it.
The three filters, parent settings and IAM were unchanged by this update.
Whether the next investigation follows those instructions needs new evidence.

One separately authorized maintenance message in a new, non-incident thread
requested only the narrow memory correction, with no investigation or Azure/SQL
tool use. Its raw file-edit result reported successful replacement of the false
platform sentence. No 62-row claim was found in the two memory files it read.
At maintenance time, independent memory search and the returned file citation
both failed with HTTP 400. The subsequent automatic SQL investigation's actual
read-file result contained the corrected note and not the old false sentence,
providing persisted readback without another maintenance message.
**Memory search remains unverified**; do not describe that read-file evidence as
a successful independent search. Keep the instruction override.

The documented memory document APIs are not a general synthesized-file editing
interface. Do not invent a file-edit endpoint, alter the provider to bypass a
failed search, or send an extra maintenance/investigation message without scope.

### Observed SQL rerun

The separately authorized **2026-11-02 UTC** rerun used one distinct temporary
rule and one real fault, with **cooldown reduced for this single run
(user-authorized)**. Detection at 00:17:51.9609032 and recovery at
00:17:59.2515432 preceded the alert at 00:18:49.1672495. A different automatic
thread was created at 00:19:26.3204117, with the exact temporary rule as its
source. The actual AgentStart audit was 00:19:26.7549611, before the first
Event/Perf queries at 00:19:43. Its final narrative arrived at 00:20:57.6666356; a read at 00:21:29
reported investigation Complete and messages Idle. No manual investigation
message was used.

The two completed query audit headers were **2 Event rows and 119 Perf rows**.
The narrative quoted both exactly and correctly described the Perf query as
individual samples: this run used projection rather than the first run's
aggregation, so 119 is not directly comparable with the first run's 12 summary
rows. It did not repeat the false platform/optional-connector inference or
inspect connector files. Those two reporting errors were corrected in this run.
This is not a guarantee of future model behavior.

The captured actions were read-only workspace/alert/rule lookups, Event/Perf
queries, memory reads/updates and tool discovery. No approval request, SQL/guest
execution or resource repair was observed. The Arc owner independently verified
owned-session/probe cleanup and the healthy Orders worker. Full raw built-in
query output remained unavailable: both audit results still truncated at 1003
characters. Headers and partial actual results are stronger than a narrative,
but do not independently verify every performance value in that narrative.
The later audit snapshot recorded Review/AzMonitor, assisted true and mitigated
false. Action Group execution was verified, but inbox receipt was not.
The same-rule merge limitation was avoided by the distinct rule identity,
not by closing an old thread. After the source-event expiry guard, direct reads
at **00:36:47 UTC** verified canonical enabled, temporary absent and SQL cooldown
restored to three hours, with Review and the other filters unchanged.
Investigation completion alone would not have proved that restoration.

### Observed LOB warning and reporting limits

One separately authorized **2026-11-02 UTC** `WarnForDuration 120` ran after SQL
capture. The existing worker remained running; no restart, kill or redeployment
was used. The helper changed config at 00:27:32, ended the warning at 00:29:32
and restored the original config at **00:29:34**, with exit 0 and the same PID.
Eight real Event 4200 warnings were generated from 00:27:36 through 00:29:21;
no 4100/4101 errors were observed. LOB routing and its three-hour cooldown were
not changed.

Azure Monitor fired at 00:28:39, executed the existing Action Group and delivered
an automatic exact-rule investigation at 00:29:41. Five KQL calls completed;
their actual result headers were **33, 1, 8, 7 and 1 rows**. The report correctly
distinguished eight Perf summary rows from 91 source samples. Final narrative
arrived at 00:31:10 and a read at 00:31:24 showed Complete/Idle. No manual SRE
chat, approval request, guest execution or SRE repair was observed. Captured
incident audit flags remained assisted false / mitigated false; completion
does not imply those flags changed.

The narrative incorrectly inferred ongoing warnings from older ingested events
and too strongly excluded host pressure from sparse counters. Healthy Event
4000 at **00:30:21** was not ingested until **00:31:00**, after the investigation
started. Independent guest Status at 00:32:39 verified Healthy/running with the
original PID; a LAW read at 00:36:04 confirmed post-restoration healthy events
through 00:34:21. Ingestion lag explains why a query could miss recovery, not
why an older warning establishes current state. A Fired/Acknowledged alert can
also retain the warning inside its ten-minute lookback after recovery.
This proves automatic capture and completed investigation, **not reliable
current-state/RCA or SRE repair**.

At **00:43:40 UTC**, a config-only handler refinement was applied with a new
external backup, repeated no-op and independent zero-operation Inspect.
Filters and ARM parent properties were unchanged. It requires evidence age
relative to investigation time, explicit ingestion lag, and evidence newer than
the last change before calling a fault active, ongoing or resolved. Otherwise
say "latest evidence at HH:MM UTC, current state unconfirmed"; sparse counters
support "not observed in the available counters", not "ruled out".
**These refinements have not been tested by another live incident.** The
coordinated step-7 rehearsal from merged main owns that test; no LOB rerun or
additional cooldown bypass was authorized here.

### Reset between demo runs

The normal configuration remains Review with enabled three-hour cooldown.
First inspect the actual alert condition, previous investigation, last routing
time and current filter. An old Complete/Idle thread, a closed alert workflow,
and resolved MonitorCondition are different facts. Reuse an existing thread
for an evidence walkthrough when a genuinely fresh automatic run is unnecessary.

For a separately authorized fresh SQL or LOB rehearsal inside the seven-day merge
lookback, use this narrowly reviewed isolation procedure:

1. Save external copies of the canonical scheduled-query rule and configuration.
   Review one distinctly named temporary rule with the same host, predicate,
   LAW, Action Group, severity, evaluation frequency and lookback. Its title
   must still match the selected scenario filter. No extra IAM or connector is needed.
2. Disable only the canonical rule, create/enable only that temporary rule and
   inspect the exact state. If separately authorized, reduce only the selected
   filter's cooldown; retain merge enabled and Review. Label the evidence
   **cooldown reduced for this single run (user-authorized)**. A one-hour setting
   was used for the authorized fresh runs. Never change the
   renderer's three-hour default or the other scenario filters.
3. Require a zero-alert baseline for the exact temporary rule ID and fresh guest
   readiness before the Arc owner fires one bounded incident. No manual SRE chat
   starts the investigation. Verify actual thread source against the temporary
   rule; do not assume that a distinct name proves successful fresh delivery.
4. After capture, wait until the detected source event has aged out of the
   canonical rule's entire lookback, with a margin. For its fifteen-minute
   SQL window, use at least sixteen minutes from actual detection, not caller
   start. For the ten-minute LOB window, use at least eleven minutes from the
   **last** matching warning, not its first event or helper start.
   Restore the selected filter to three hours, re-enable the unchanged canonical
   rule, then delete only the temporary rule.
5. Independently read back canonical enabled, temporary absent and selected filter
   `mergeEnabled=true` / `mergeWindowHours=3`; compare all other configuration
   against the saved baseline. On an ambiguous write, read back without replaying
   the PUT; resume only unperformed operations after verified state inspection.
   Report a failed or pending restore immediately; do not claim normal readiness.

**Backfill warning:** the source-window expiry guard does not prevent Azure
Monitor from replaying an older evaluation after a disabled log rule is
re-enabled. In the 2026-11-02 SQL restore, canonical was re-enabled at 00:36:24
but fired again at 00:39:50 against the older 00:17:16-00:32:16 evaluation
window. No new SQL detection occurred; the system resolved that alert at
00:50:51. The existing canonical SRE thread then exposed merged count 2 and a
last-fired timestamp matching the replay, with no new canonical thread or
contemporaneous agent/query execution in the captured audit. Its merged-ID
array did not expose the replay ID, so do not claim exact-ID inclusion there.
Later `TrajectoryInsight` messages summarize the old investigation, not a new
query run; those summaries can repeat old incorrect conclusions.

Expect possible extra fired/resolved notifications from the unchanged Action
Group when restoring either rule, even after waiting out the lookback.
Compare source-event time, evaluation window, exact rule and SRE merge metadata;
do not confuse replay with another incident or count it as a new investigation.
No cheap, verified suppression workaround is established here. Do not silently
mute receivers, alter predicates, change cooldown again or delete/recreate the
canonical rule to conceal it. A read-only walkthrough of existing evidence
avoids this routing reset altogether; no cloud change was made for this finding.

This procedure changes routing resources and is not included in ordinary
presentation or configuration apply. Each scenario requires its own separate
authorization; complete SQL capture, cleanup and restoration before arming LOB.
Resolve/close old alerts or threads only with
their own approval and supported operation; closure alone is not a documented
way to clear the seven-day merge history. A parent rebuild also loses history,
but is not an acceptable reset shortcut for a running demonstration.

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

An existing exact managed Arc resource group covers its SQL host; readiness
does not require a redundant explicit host entry when that group is managed.
The host must still exist with its exact expected ARM ID. A foreign group is
not coverage. Fresh deployment can include the explicit SQL host as well.

### Existing-parent preview warning

A SQL rehearsal preview caught potential removal of `defaultModel`,
`monthlyAgentUnitLimit`, `experimentalSettings`, `sandboxConfiguration` and
`upgradeChannel` because the current parent template omits these existing
settings. **That parent deployment was not applied.** Use configuration-only
Inspect/Apply for handler and filter updates on the Running parent. Do not treat
these settings as harmless read-only what-if noise or approve a broad redeploy
to add a redundant host ID. A supported preservation fix needs separate work
and validation before redeploying that existing parent.

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
outside the requested profile at the two workload groups, with one narrow
exception: an existing subscription Monitoring Contributor grant on the exact
retained UAMI, regardless of whether the parent exists or has a connected incident platform.
This is the documented [Azure Monitor alert-management prerequisite](https://learn.microsoft.com/azure/sre-agent/permissions).
It is platform-managed, not created by this repo. Other roles, scopes,
principals or duplicate grants remain rejected. The same exact-grant tolerance
applies before wake, so retained platform access does not block reconstruction
after parent deletion. Hibernated readiness reports it separately from workload
grants. A disconnected or unset platform on an existing parent emits an optional
readiness warning: alerts will not reach the agent until Azure Monitor is
connected. That warning does not invalidate retained access or establish
incident readiness. When AzMonitor is selected, missing subscription scanner
access is a required failure, not a reason to grant it silently.
This rehearsal did not test a live park/wake cycle with that grant.
Reconciliation requires separate scope approval, not implicit revocation.
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

Fresh creation and wake already select `incidentManagementConfiguration.type:
AzMonitor` in `infra\modules\sre-agent.bicep`, through the
[supported parent ARM property](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents).
This is not a handler/filter configuration step or an optional data connector.
Read back both that setting and the exact retained subscription Monitoring
Contributor assignment before declaring automatic incident routing ready.
The [Azure Monitor scanner guide](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)
requires that role and documents **Incidents > Connect an incident platform >
Azure Monitor** if connection setup remains incomplete. Obtain separate approval
for that supported portal step and any platform-managed access consequence; the
repo never creates the subscription role. Do not disconnect another platform,
replay guessed connection APIs or redeploy an existing parent to hide a warning.
Compiled-template and mocked wake checks establish source wiring, not a live
recreation/delivery test.

For the next demo, activate and verify Arc first. Deploy the SRE parent using the
retained identity, then render/Inspect/approve/Apply the versioned modern custom agent and
v3 filters with a new external backup, or use complete deployment above.
Keep the same SQL-enabled setup input on wake so the SQL host managed-resource
ID, conditional instructions and third filter are restored. Dropping SQL from
that input while its enabled filter remains is refused as unowned routing,
not silently disabled or deleted. SRE Hibernate/Removed never deletes the Arc
SQL host, database, probe data or Arc-owned alert; those remain the Arc owner's
scope. No additional workload role IDs are introduced by SQL.
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
