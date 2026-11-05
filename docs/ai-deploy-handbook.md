# AI deploy handbook - optional SRE layer

Use this only after standalone `arc-demo` is active. The Arc repo owns its estate;
this repo adds SRE without editing the Arc checkout or redeploying its workloads.
This is an operator/AI setup reference, not the presenter script. Start at
[the docs map](README.md) for audience, reading order and presentation guidance.

## Local presenter guide

After successful setup, the assistant saves the confirmed names, IDs and URLs
from the approved inputs and setup readbacks in repo-root
`.local/demo-context.json`, then runs:

```powershell
.\scripts\New-PresenterRunsheet.ps1
```

Open the returned `.local/presenter-runsheet.md` for the SRE presentation.
The generator is offline. It reads JSON and fills the tracked
`docs/delivery-runsheet.md` source; plain Markdown does not interpolate JSON.
Refresh after setup changes. Saved context timestamps describe the inputs,
not fresh health checks. Do not query Azure solely to generate a document.
The companion Arc generator can splice this guide into its whole-demo page
(`New-PresenterRunsheet.ps1 -SreGuidePath <this guide>` in `arc-demo`). It requires
the template's level-2 headings `This afternoon: verified existing investigations`,
`Live faults` and steps 1 to 7 (step 7 exactly `7. Close`), so keep them when editing
`docs/delivery-runsheet.md`; `tests/Test-PresenterRunsheet.ps1` checks this.

Context schema version 1 requires these exact nonsecret fields:

| Field | Saved setup source |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `subscriptionId`, `tenantId` | Explicit approved target |
| `recordedAtUtc` | UTC timestamp ending in `Z` for the saved context |
| `resourceGroups` | Object with confirmed `arc`, `infra`, `sre` names |
| `agentName`, `agentUrl` | Agent name and actual Azure/SRE portal resource URL from deployment |
| `applicationUrl` | Container App HTTPS endpoint |
| `applicationInsightsResourceId` | SRE diagnostics component |
| `logAnalyticsWorkspaceId` | Existing Arc workspace |
| `containerAppResourceId`, `arcMachineResourceId` | Exact T09 app and T11 Arc machine |
| `containerResponsePlan`, `lobResponsePlan` | Rendered plan names |
| `lobAlertTitleContains`, `lobEventSource` | Approved rendered LOB signal values |
| `sql` (optional) | Object with exactly `machineResourceId`, `alertResourceId`, `responsePlan`, `alertTitleContains`, `eventSource`, saved only after verified SQL setup |
| `companionArcRunsheetPath` (optional) | Explicit absolute path to the Arc guide, preferably its generated local copy |

The assistant collects these once during setup, not from the presenter.
Deployment skins remain internal setup inputs and require no presenter changes.
The generator rejects missing fields, wrong subscription/group/type IDs,
unsafe names and credential-bearing URLs. Unknown fields are rejected so a
deployment export or token envelope cannot be used as presenter context.
Keep credentials, tokens, contact details, exports and raw incident payloads out
of this file. The entire `.local` directory is gitignored; do not force-add it.
The JSON and generated guide contain identifiers and should stay on the operator
machine. Never publish either by default.

The optional companion link is computed relative to the generated file, with
path segments escaped. A missing companion file produces a skip note without a
broken link. Changing context or rendering the guide changes no deployment,
lifecycle state, permissions or fault flags.

The optional SQL object uses the actual Arc host and scheduled-query rule IDs,
the rendered plan name, exact title `Arc SQL lock timeout` and source
`ArcSqlEngineDemo`. Its IDs must match the explicit subscription and Arc group.
Omit it until the Arc engine/signal and SRE route are verified; the guide then
shows a skip note. Source defaults alone are not verified setup.

### LOB investigation validation

The generated guide contains a ready-to-send request for one read-only SRE
investigation of the exact Arc machine's existing Application events and host
performance logs. It uses the saved workspace resource ID and one bounded
30-minute union query: at most 50 events and 250 total rows, including per-minute
host summaries. No additional context field is needed.
Existing `QueryLogAnalyticsByWorkspaceId` and read CLI tools are already assigned
to the handling agent. The workspace and Arc machine are already managed
resources; required readiness checks validate the scoped role profile.
[Built-in log queries](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability)
can use resource IDs or workspace IDs without a connector.

Before any live test, obtain scoped approval for one SRE chat request and the
associated read-only log/metadata access and usage. This does not authorize a
fault, notification, guest command, repair, new role or connector. Keep Review
and existing tools unchanged. Stop on access denial, a request to elevate, or
unexpected side effects; never accept a request to add permissions for the query.
Preserve the existing exact Azure Monitor platform prerequisite described below.
The [supported interaction](https://learn.microsoft.com/azure/sre-agent/first-investigation)
is New thread, a specific scoped prompt, then Send.

Success needs a completed SRE query with real target-bound rows/timestamps and
an evidence-grounded explanation with conditional operator steps. If only 4000
is present, a healthy-telemetry conclusion is useful; no failure RCA is claimed.
No data, tool failure, stalled output or a manual portal query alone leaves SRE
investigation unverified. Record its actual outcome and thread link privately.
The historical alert-triggered T11 RCA stalled with no established backend
root cause. This bounded manual path does not fix or certify that automatic path.

### Host context and an optional bounded LOB warning

Arc's core DCR source (`scripts/Deploy-ArcDemo.ps1`, `New-CoreDcrBody`) specifies
`Microsoft-Perf` to `Perf` every 60 seconds. Its Windows paths include
`\Processor Information(_Total)\% Processor Time`,
`\Memory\% Committed Bytes In Use`, `\Memory\Available MBytes` and
`\LogicalDisk(_Total)\% Free Space`. The guide uses the documented
[Perf columns](https://learn.microsoft.com/azure/azure-monitor/reference/tables/perf)
and scoped [aggregation pattern](https://learn.microsoft.com/azure/azure-monitor/logs/get-started-queries#aggregate-and-group-results).
The separate VM Insights `Microsoft-InsightsMetrics` stream is not this table.
Source intent does not prove current collection. Missing samples are a visibility
gap, not zero CPU or a healthy memory/disk assessment. These are host counters,
not per-process metrics; free-space percent does not measure storage latency.

The proposed default incident is an **app-warning-only** scenario. It does not
allocate load, consume extra disk or crash/restart the worker. After the user
chooses that scenario, agree the exact host, warning duration, observation
deadline, existing notification recipients/usage costs and operator cleanup
fallback before any live operation. Actual bounded CPU/memory/disk load is a
different scenario and is not implemented or authorized here.

Use the existing helper with explicit approved target inputs and
`-Action WarnForDuration -WarningSeconds 120`. First preview with `-WhatIf`;
execution additionally requires `-ApproveWarningWindow`. The assistant fills
subscription, tenant, resource group, machine, task, app root, source and saved
skin from approved setup, never defaults guessed from an ambient login.
`-GuestScriptOutputPath` can render the same guarded guest script offline;
rendering is not execution approval. No new deployment or agent tool is needed.

The guest baseline requires Healthy mode, the expected source, a running task,
the existing worker PID bound to this script/config and a 5-to-60-second loop.
It requires at least two app cycles, temporarily changes only the mode and
incident marker, and restores the exact original config in `finally` if that
config is still its own. It does not restart the task or kill a process. It
checks actual local 4200 events and continued worker/task state. Duration is
30 to 180 seconds; the existing Arc command timeout is 300 seconds.
This is best-effort scoped cleanup, not a watchdog: session/process termination,
Run Command ambiguity or a concurrent edit can leave recovery unverified.
Stop, inspect the existing command and config, and use only the separately
approved operator ResetFault fallback when appropriate. Never blindly retry,
overwrite another change, approve an SRE repair card or suppress a cleanup error.

Before that guest command, obtain a fresh read-only readiness/host baseline
within the authorized window and check the existing scheduled rule, Action Group,
enabled LOB title keyword/Sev2/Review match, and enabled three-hour cooldown.
The source rule has count greater than zero for 4100/4101/4200, one failing
evaluation, a ten-minute lookback and five-minute evaluation frequency.
Warning severity on the Windows event still routes through a Sev2 Azure alert.
No rule, routing, cooldown, RBAC or connector change is part of this scenario.
An already fired alert or cooldown can prevent a new incident. Confirm current
eligibility; do not bypass it.

The source handling-agent instructions include 4200 and the configured host
counters. Changing source alone does not update a deployed agent.
Before live automatic correlation, render and Inspect the desired configuration,
then separately authorize the exact handler-only update with a new external
backup. If enabling SQL as well, use the larger explicit scope below instead.
Stop on changes outside the approved preview. Re-read the instructions
and run required readiness checks before the warning. No new tools or permissions
are required by this source change; this is not approval to apply it.

Proposed rehearsal limits for approval: obtain a fresh ten-minute baseline,
warn for 120 seconds, and require verified Healthy config/original running worker
by five minutes after the accepted guest start. If restoration is unverified,
stop the presentation and invoke only the agreed narrow operator fallback after
inspection. Observe the alert/new incident until at most twenty minutes after
that start, without rerunning the warning or bypassing cooldown. Capture at
least five minutes of post-window host samples where available; the assistant
fills real timestamps from the command result, not presenter-supplied IDs.
Existing Action Group receivers may get fired/resolved notifications and the
agent may incur investigation/query usage. Confirm actual recipients and consent
before execution. No new receiver, chat request or rule is created implicitly.

Record UTC baseline, warning start/end, config restoration and post-window
evidence. Allow for AMA ingestion and scheduled evaluation after the warning
has ended. Bound observation explicitly; there is no delivery deadline guarantee.
Prove each stage independently: Event 4200, a newly fired alert/Monitor condition,
its Action Group/SRE delivery, a new actual investigation and completed query
results/recommendations. A restored Healthy config does not resolve an alert
immediately while events remain inside its lookback. Correlate actual CPU,
memory and free-space bins before/during/after, reporting missing stages.
No relationship between synthetic dependency warnings and resource pressure is
assumed. Historical automatic RCA is unproven, and earlier read-only
investigations exposed only partial tool/report evidence. New metrics
queries, guest warning, notifications and investigation usage need new scope;
earlier one-time consents do not carry over.

### SQL setup and sequential rehearsal

The Arc owner owns SQL installation, license decisions, the normal Orders worker,
bounded incident/cleanup helper, Application collection and the optional
`sql-incident-alert.bicep` module. Obtain that owner's fresh engine/worker and
cleanup-readiness handoff before SRE setup. This repo neither installs SQL nor
accepts a license. The agreed signal is real lock timeout 1222 on an owned probe
row, not a deadlock or an Orders outage. See the supported
[1222 explanation](https://learn.microsoft.com/sql/relational-databases/errors-events/mssqlserver-1222-database-engine-error).

Enable the optional `SQL` scenario only in the approved private setup input:
append it to `sre.requiredScenarios`, set `sre.sqlTargetArcMachine` to the actual
SQL Arc host and supply distinct `labels.sqlResponsePlan`, exact
`labels.sqlAlertTitleContains = Arc SQL lock timeout` and
`labels.sqlEventSource = ArcSqlEngineDemo`. The two fictional examples keep SQL
disabled. The presenter never edits these fields or hunts for resource IDs.

For an already running two-route demo, an exact managed Arc resource group
already covers its SQL host. Use an in-place handler instruction update and one
SQL filter without redeploying that parent. Existing T09/LOB plans, Review, Sev2,
enabled three-hour cooldown, tools, identity and group grants remain unchanged.
For a fresh deployment or rebuild, review `Deploy-SreAgent.ps1 -WhatIf` and obtain
authorization for parent creation (`-ApproveParentCreation`, starts AAU billing).
An existing parent is refused before IaC; heed the
[parent preview warning](sre-response-plan-automation.md#existing-parent-preview-warning).
Before that preview, complete the [rebuild prerequisites](../README.md#rebuild-prerequisites):
the Arc-owned Container App and restart alert, plus the separately authorized
LOB alert creation and LOB app deployment, using the same absolute private skin.
Install the required CLI extensions and preserve the Windows CLI's bundled
Python launcher. Missing scenario prerequisites fail their own readiness checks;
they do not hide later handler, plan or grant findings.
Render/Inspect configuration, approve its exact changes, Apply with a new external backup and
repeat to prove no-op. Stop on unrelated differences, denial or ambiguous writes.
Required SRE readiness also validates the exact SQL alert predicate, owner tags,
host, LAW, Action Group and one-minute/fifteen-minute settings. It does not run
KQL or certify the guest engine, collection or automatic investigation.

Agree and release one SQL window and one LOB window, **sequentially**, only after
fresh readiness and the actual Action Group receiver/common-schema and SRE
delivery checks. Disclose possible fired/resolved notifications and ingestion,
query/SRE charges. Check each alert's Monitor condition and actual cooldown;
do not disable routing or cooldown to force a new incident without a separately
approved exception. The [reset procedure](sre-response-plan-automation.md#reset-between-demo-runs)
distinguishes the three-hour filter setting from Azure Monitor's seven-day
same-rule merge; alert/thread closure alone is not a documented reset. Its
scripted route helper is `Invoke-SreDemoRoute.ps1 -Action Prepare` before a
fresh fault and `-Action Restore` afterwards. Use the existing
inspection path for actual completed tool output, not merely a tool-start label
or truncated narrative. If that path is unavailable, state the evidence limit
before the run instead of claiming full verification.
The [recorded SQL rehearsal](sre-response-plan-automation.md#observed-sql-rehearsal)
proved automatic routing and completed query execution, but not full raw-result
capture. It does not certify the separate LOB route or a future instance.

The documented [data-plane thread API](https://learn.microsoft.com/azure/sre-agent/api-reference#threads-and-chat)
offers read-only GETs of the actual thread and its messages on the endpoint read
from the exact parent, using the `https://azuresre.dev` token audience.
Keep tokens in memory, raw responses outside git and those reads separate from
the configuration adapter's narrower handler/filter route allowlist. Inspect
actual execution status, command, full output/error and timestamps. Do not send
a message or approve an action to obtain evidence. A shortened canvas summary
or Application Insights tool-start event is not the raw completed result.
The documented [audit events](https://learn.microsoft.com/azure/sre-agent/audit-agent-actions)
can pair `AgentToolExecution` ToolStart/ToolEnd by thread and CallId. Inspect
actual ToolOutput for truncation: a completed event with a shortened result is
execution and partial-result evidence, not full raw output. Preserve those limits
instead of substituting the final narrative or rerunning the fault.
The documented [GenAI content table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/appgenaicontent)
also exposes tool-result fields, but their existence does not mean this agent
populates them. An exact-trace read for the first SQL run returned assistant
messages with empty tool results and input messages; it did not recover the
missing query output. Do not enable new telemetry or claim full capture merely
because a table schema supports it.

For SQL, record the helper's actual UTC start, incidentId, real 1222, observed
blocker/victim/wait and rollback/probe/owned-session cleanup results. The blocker
rolls back after twelve seconds and the victim times out after five seconds;
this is not a promise of Azure delivery within twelve seconds. Require the Arc
owner's verified cleanup/healthy Orders result within the agreed recovery
deadline, proposed five minutes after accepted start. Stop if it cannot be
proved; only the separately agreed narrow operator cleanup is authorized.
Observe event 6201/detected, matching 6001/recovered, a new SQL alert, actual
SRE delivery, completed target-bound Event/Perf queries and recommendations for
at most twenty minutes. Recovery normally precedes alert evaluation because
the rule retains fifteen minutes of events. Do not retry a consumed fault,
send an extra chat request or infer a current blocker from an old alert.
Only after SQL cleanup is verified may the separate LOB warning window begin,
using the bounds above. Missing/denied/stalled evidence is an actual incomplete
stage, not a successful automatic RCA. Save evidence privately and refresh the
local SQL context from approved readbacks only after setup is verified.

## Handoff prompt

```text
Read AGENTS.md, README.md, docs/README.md, docs/delivery-runsheet.md and
docs/sre-response-plan-automation.md.

Inputs: explicit subscription GUID, tenant GUID, skin, and desired state
Active (Ready compatibility alias), Hibernated or Removed. Never infer target context from an ambient Azure login.
Use a private skin outside git (a copy of config/demo-skin.json edited for the
live Arc estate) for every script; the tracked skin is only a fictional template.
Keep runtime identifiers and credentials out of git.

For Active:
1. Confirm the Arc estate is active using Arc readiness and actual inventory.
2. Validate the skin offline: run Initialize-SreConfiguration.ps1 with only the
   explicit target and -SkinPath (no cloud calls), then the local mocked tests and
   Bicep compilation. Create the T11 LOB app/alert and enable SQL only as the
   README prerequisites describe.
3. Preview Deploy-SreAgent.ps1 -WhatIf. Review the exact diff before changes.
   On a fresh parent the offline render is the configuration preview.
4. Deploy with -ApproveParentCreation and a new external -ConfigurationBackupPath
   only when parent creation is authorized. It creates the parent, then applies
   and verifies the handler and plans. Use -ParentOnly (deliberately not a claim
   that the demo is Ready) only to review the configuration preview first.
5. For a running parent, or after -ParentOnly, render Initialize-SreConfiguration.ps1,
   then -Inspect via pinned official template protocols. Review the full preview
   before -Apply with a new external -BackupPath. Unsupported legacy settings/P1-P2
   stop without migration; use the canonical supported fallback, never guessed
   endpoints or duplicate plans.
6. Run Test-SreReadiness.ps1: handler, plan, Sev2 filters, legacy fields, Review
   and overlap have full read-back. Its telemetry item is optional, skipped/not
   evaluated; all required checks must pass. Never rewrite the report.
   Existing ARM success is not routing
   readiness. Do not induce a fault merely to answer a read-only readiness check.
7. T09 is the primary Review closed-loop capability; a new instance still needs
   its own authorized functional rehearsal before a live success claim.
   Present T10/T11 as hybrid evidence plus governed operator Arc Run Command
   recovery. T11 RCA is not reliable yet. Use the canonical guide's evidence-only
   fallback rather than treating old-instance proof as a new-instance pass.
8. Leave a requested Active demo running. Do not automatically hibernate.
   Refresh .local/demo-context.json from approved inputs/readbacks and run
   New-PresenterRunsheet.ps1 so the presenter opens one filled-in SRE guide.
9. After successful combined activation/SRE reactivation, follow the
   Post-activation incident offer below: the SRE assistant must ask once in
   conversation whether to trigger one T09 incident. Do not leave the user to
   remember or run scripts. No fault without an affirmative scoped answer.

For Hibernated:
1. Obtain explicit authorization for deletion and export current Inspect output
   plus required incident/audit evidence outside git. This is not a history restore.
2. Save the SRE user-assigned identity principal ID.
3. Preview Hibernate-SreAgent.ps1 -WhatIf, then execute only after approval. It
   is ConfirmImpact High: a non-interactive host must add -Confirm:$false (the
   reviewed preview is the approval) or it stops before changing anything.
4. Normal parking deletes only the paid parent; retains SRE group/UAMI, existing
   workload grants, workspace AppInsights and owned Action Group.
   Verify retained principal and parent absence with Test-SreReadiness.ps1
   -DesiredState Hibernated -PreviousIdentityPrincipalId <saved ID>.
   Missing legacy diagnostics or stale free grants are optional wake diagnostics,
   not a reason to leave the paid parent running. Denied inspection still fails.
5. Finish SRE verification before Arc hibernation. Arc lifecycle is separately
   owned; do not stop its workloads from this repo. Wake/verify Arc before SRE.

For Removed:
1. Obtain separate full-removal authorization; preserve exports and principal.
2. Preview Remove-SreAgent.ps1 -WhatIf with the same explicit target/skin.
3. Unknown resources/roles/scopes require ownership reconciliation, not bypass.
4. Execute approved preview (-Confirm:$false in a non-interactive host); known
   grants/resources are removed before deleting
   the empty dedicated group. Shared Arc/Monitor and private exports are untouched.
5. Verify -DesiredState Removed with the saved principal. Without that principal,
   external-grant absence is pending even when the group is gone.

Never change plans to Autonomous, remove quickstart plans, revoke extra grants,
connect a repository, or induce faults without the appropriate scoped approval.
```

## Post-activation incident offer

This is an **AI conversation step**, not a script prompt or a new orchestrator.
After a user-requested combined activation, or SRE reactivation on an already
healthy Arc estate, the SRE-owning assistant must offer one representative T09
Container App incident. It owns the offer **once**, after the Arc assistant's
successful readiness handoff and completion of SRE configuration. Do not also
ask from the Arc-only path, after `-ParentOnly`, during read-only rehearsal or
while activation is incomplete.

First verify fresh Arc readiness, all required SRE infrastructure/configuration/
workload checks and the healthy T09 endpoint. Keep the original readiness report
unchanged; any required failed/pending check blocks the offer. The optional
unevaluated rehearsal item is not incident proof and needs no special exception.

Use the confirmed private target and an agreed observation deadline in the
conversation. For example: **"Activation is complete. Would you like me to
trigger one T09 Container App incident now? It temporarily faults the demo app,
can send configured alert notifications and incurs SRE usage costs. I'll run
the existing demo procedure, monitor until our agreed deadline, use the narrow
operator reset if needed, and guide you to the real human Review approval."**

- **No:** skip incident preparation, report activation separately and leave the
  requested Active demo running. Do not ask again in the same activation.
- **Yes:** confirm the exact app and recovery window, including the narrow
  `SIMULATE_CRASH=false` fallback, then have the AI execute
  [the existing T09 runbook](t09-native-containerapp-closed-loop.md#5-induce-the-fault)
  through observation, human Review and recovery verification. The user does
  not need to choose or run scripts. This authorizes one fault, not a retry,
  permission change, autonomy/cooldown change or approval of the SRE repair.
- **No answer or unattended execution:** do not block on a shell prompt or fault
  silently. Report preparation skipped; tell the user they can ask Copilot to
  run the optional T09 incident when they are present.

Keep Review and enabled three-hour cooldown. Inspect the actual alert and
investigation in the supported UI; cooldown may reuse an existing thread.
Guide the signed-in human to approve only the current run's exact reset card.
Never auto-approve or treat chat consent/narration as that approval. Before
faulting, check the healthy baseline and previous run's recovery; after an
ambiguous write inspect state rather than blindly repeating the fault.

Follow the runbook's existing recovery-owner/deadline and operator fallback
procedure if approval or SRE repair is unavailable. The helper has no automatic
watchdog or hard cancellation guarantee; do not promise otherwise. Surface
reset/health failures immediately and never approve a stale card after fallback.
Record actual alert, investigation and finding evidence where observed; report
missing or uncertain evidence as pending, not as a successful loop. Verify the
false flag, serving revision and HTTP 200, and report actual Monitor condition
resolution or explicitly pending resolution separately from alert workflow state.
Distinguish SRE repair with executor evidence from AI/operator reset fallback.
Preparation failure does not undo or relabel successful infrastructure activation.
This produces new evidence, not restoration of history lost on parent deletion.

## Runtime commands

```powershell
az login --tenant <TENANT_ID>
# Scripts pass --subscription on every request and never run az account set.
# <PRIVATE_LAB_FOLDER>\sre-skin.json is your private skin (kept outside git).
.\tests\Invoke-Tests.ps1
az bicep build --file .\infra\main.bicep --stdout

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -WhatIf

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -ApproveParentCreation `
  -ConfigurationBackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>

# The steps below are the manual route: -ParentOnly (not Ready) and then
# configuration by hand. They are also how to change configuration on a
# running parent, which Deploy refuses.
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -ParentOnly -ApproveParentCreation

.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json

# Read full actual objects/preview before approving any writes.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Inspect

# Only after that exact modern configuration scope is approved.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Apply `
  -BackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -DesiredState Active -OutputFormat Json
```

See [response-plan automation](sre-response-plan-automation.md) for supported
commands, pinned protocol sources, idempotency/timeouts and exact machine
contract. A new live incident/recovery test still needs separate authorization.

## Lifecycle and permission boundaries

SRE has a deletion-based off state, not VM-style deallocation. Deletion discards
handler/plan/history/memory/connector state. Parent redeployment is only stage one
of reconstruction. Resume requires data-plane setup and verification again.
Save evidence before cleanup and reauthorize optional repository connections.
Versioned assets recreate the modern custom agent/v3 filters, not retired
legacy objects, saved threads or learned memory. A separate IaC module creates
the SRE-only UAMI on first deployment; later normal cycles retain it in the SRE
group and reuse its principal and deterministic workload grant IDs. Parent
SystemAssigned,UserAssigned compatibility is unchanged: its system principal
still rotates, without external workload grants. Do not promise zero directory
churn. Historical whole-group deletion needs one replacement UAMI; that deleted
principal cannot be restored. Full group/identity removal is separate authorized
cleanup, never ordinary hibernation. The renderer enforces true/3-hour cooldown.

The deploying identity may be User or ServicePrincipal (including managed
identity). The script infers known Azure CLI identity types; pass
`-DeployerPrincipalType` for an unrecognized execution identity. RBAC names include
the live principal and adopt existing same-principal role assignments. Incremental
Bicep does not remove obsolete grants; Low downgrade with existing write grants
fails explicitly pending a separately approved reconciliation.

High uses Reader/Log Analytics Contributor/Contributor at the two workload groups.
Low uses true Log Analytics Reader, not the formerly mislabeled Contributor ID.
Hibernate retains existing grants (free, but still standing access); before Active,
deployment/readiness reject incompatible/inherited/extra grants for separately
approved reconciliation. The sole exception is one existing subscription
Monitoring Contributor grant for the exact retained UAMI, including while the
parent is absent or its incident platform is disconnected. It is a documented
[platform prerequisite](https://learn.microsoft.com/azure/sre-agent/permissions).
Creation requires explicit `-GrantAzureMonitorAlertAccess`, either on Deploy or
the [standalone grant script](sre-response-plan-automation.md#explicit-azure-monitor-access-grant);
other scopes/roles/principals and duplicates are not exempt.
Fresh/wake Bicep sets `incidentManagementConfiguration.type = AzMonitor`; the
opt-in script supplies the approved scanner role. No routine portal connection
step is required. Read back the selection and grant separately. The existing
`incident-platform` check reads ARM configuration, not scanner health: an
unset/non-AzMonitor selection emits an advisory warning, not a new required gate.
Only if that check shows the platform is not configured, use the separately
authorized [portal fallback](sre-response-plan-automation.md#explicit-azure-monitor-access-grant).
Fresh-agent intake through IaC plus the grant remains unproven until the rebuild
and separately authorized alert-delivery verification. Never infer this state
from optional connector files. Deployment adopts
existing direct assignment names and does not query Graph display names.
Retained AppInsights must match the requested workspace/location; wake does not
silently relocate it. Older UAMI-only parking rebuilds missing diagnostics through
the same IaC. No grants are removed during Active or normal Hibernate.
Removed inventories principal-filtered ARM assignments with bounded validated
pagination; unexpected SRE resources or scoped grants block its destructive path.

Local checks cover parser/schema/rendering/mocked failures and safety behavior.
They do not prove Azure data-plane create reliability, destructive lifecycle
rebuild, live guest execution or a new T09 alert-to-recovery run.
See the [historical engineering ledger](t10-sre-on-arc-experiment.md#historical-sre-configuration-and-t09-evidence)
for dated run outcomes and their evidence limits.
