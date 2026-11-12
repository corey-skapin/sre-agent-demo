# Deploy handbook - optional SRE layer

Use this after standalone `arc-demo` is active. This repo adds SRE without editing
the Arc checkout or redeploying its workloads. Your AI tool can follow this page for
you, and the steps are the same if you run them yourself. It is a reference, not
the presentation script: [the docs map](README.md) has the reading order.

## Where the subscription and tenant come from

Every script takes `-SubscriptionId` and `-TenantId` as parameters. Confirm them with the user once, for example from `az account show` (the `id` and `tenantId` fields), then pass them to every script. Don't take them from whatever the CLI happens to be signed in to. Check a skin with `Get-DemoSkin` (from `scripts\lib\DemoSkin.psm1`): it validates the file against the schema and names any missing or wrong field.

## Your presenter guide

After setup, save the confirmed names, IDs and URLs from your setup output and
read-backs in repo-root `.local/demo-context.json` (your AI tool can do this from the
Deploy output), then run:

```powershell
.\scripts\New-PresenterRunsheet.ps1
```

Open the returned `.local/presenter-runsheet.md` to present.
The guide belongs to the checkout that generated it: `.local` is gitignored, the
output path is fixed at `<checkout>\.local\presenter-runsheet.md`, and its link to
the Arc guide is computed relative to that file. Generate it in the checkout you
will present from, not in a temporary worktree that will be deleted, and
regenerate it there after any move or copy (a copied guide has a broken Arc link).
The generator is offline. It reads JSON and fills the tracked
`docs/delivery-runsheet.md` source; plain Markdown does not interpolate JSON.
Refresh after setup changes. Saved context timestamps describe the inputs,
not fresh health checks. Don't query Azure solely to generate a document.
The companion Arc generator can splice this guide into its whole-demo page
(`New-PresenterRunsheet.ps1 -SreGuidePath <this guide>` in `arc-demo`). It requires
the template's level-2 headings `This afternoon: verified existing investigations`,
`Live faults` and steps 1 to 7 (step 7 exactly `7. Close`), so keep them when editing
`docs/delivery-runsheet.md`; `tests/Test-PresenterRunsheet.ps1` checks this.

Context schema version 1 requires these exact nonsecret fields. Start from the
fictional [`config/demo-context.example.json`](../config/demo-context.example.json):
copy it to `.local/demo-context.json` and replace every value from your setup
read-backs. The tracked presenter test renders that file, so its shape stays
current.

| Field | Saved setup source |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `subscriptionId`, `tenantId` | The tenant and subscription you confirmed |
| `recordedAtUtc` | UTC timestamp ending in `Z` for the saved context |
| `resourceGroups` | Object with confirmed `arc`, `infra`, `sre` names |
| `agentName`, `agentUrl` | Agent name and actual Azure/SRE portal resource URL from deployment: the `Portal:` line `Deploy-SreAgent.ps1` prints. Save it then; it can also be rebuilt as `https://portal.azure.com/#view/Microsoft_Azure_PaasServerless/AgentFrameBlade.ReactView/id/` followed by the agent's ARM ID with each `/` written `%2F` |
| `applicationUrl` | Container App HTTPS endpoint: `https://` plus the output of `az containerapp show --name <APP> --resource-group <ARC_GROUP> --query properties.configuration.ingress.fqdn -o tsv` |
| `applicationInsightsResourceId` | SRE diagnostics component |
| `logAnalyticsWorkspaceId` | Existing Arc workspace |
| `containerAppResourceId`, `arcMachineResourceId` | Exact T09 app and T11 Arc machine |
| `containerResponsePlan`, `lobResponsePlan` | Rendered plan names |
| `lobAlertTitleContains`, `lobEventSource` | Rendered LOB signal values |
| `sql` (optional) | Object with exactly `machineResourceId`, `alertResourceId`, `responsePlan`, `alertTitleContains`, `eventSource`, saved only after verified SQL setup |
| `release` (optional) | Object with exactly `appResourceId`, `appUrl`, `repository`, `goodVersion`, `badVersion`, `responsePlan`, saved only after the T12 workload is deployed and `Test-SreReadiness.ps1` passes its `T12-` rows |
| `acts` (optional) | List of one or more of `ASK`, `MEMORY`, `PROACTIVE` and `ARC`, each once, saved only after `Test-SreReadiness.ps1` passes the modules' `ACTS-` rows. `PROACTIVE` also needs `release` |
| `companionArcRunsheetPath` (optional) | Explicit absolute path to the Arc guide, preferably its generated local copy |

Collect these once, at setup. Your skin stays a setup input; you don't edit it to
present. The generator rejects missing fields, wrong subscription/group/type IDs,
unsafe names and credential-bearing URLs. Unknown fields are rejected so a
deployment export or token envelope cannot be used as presenter context.
Keep credentials, tokens, contact details, exports and raw incident payloads out
of this file. The entire `.local` directory is gitignored; do not force-add it.
The JSON and generated guide contain identifiers and should stay on your
machine. Don't publish either.

The optional companion link is computed relative to the generated file, with
path segments escaped. A missing companion file produces a skip note without a
broken link. Changing context or rendering the guide changes no deployment,
lifecycle state, permissions or fault flags.

The optional SQL object uses the actual Arc host and scheduled-query rule IDs,
the rendered plan name, exact title `Arc SQL lock timeout` and source
`ArcSqlEngineDemo`. Its IDs must match the explicit subscription and Arc group.
Omit it until the Arc engine/signal and SRE route are verified; the guide then
shows a skip note. Source defaults alone are not verified setup.

The optional `release` object is the T12 equivalent. `appResourceId` is the
ticketing web app's resource ID (`az webapp show --name <APP> --resource-group <TICKETING_GROUP> --query id -o tsv`; the `Deploy-TicketingWorkload.ps1` output names
the app and its group), `appUrl` is its `https://<name>.azurewebsites.net`
address, `repository` is `<OWNER>/<REPOSITORY>`, the two versions are `vX.Y.Z`
tags and `responsePlan` is the rendered plan name. The resource ID must match the
explicit subscription and be a web app, and the URL must be an `azurewebsites.net`
address without credentials or a path. Omit it and the guide
shows a skip note where the Friday release goes
([T12 runbook](t12-friday-release.md)).

The optional `acts` list switches on the modular acts in the guide: it adds a
running order for the staged 40-minute run and the 15-minute executive cut, and one
block for each module you list: [Act 1, ask it anything](ask-anything.md),
[Act 3, it remembers](it-remembers.md),
[Act 4, it works when nothing is broken](proactive-checks.md) and
[Act 6, the server room](arc-server-room.md). A module you leave
out gets a skip note, and with no `acts` field the guide has no trace of them. Each
act stands alone, except that `PROACTIVE` reads the ticketing web app, so the
generator rejects it without `release`, and the executive cut needs `PROACTIVE`
(its governance deck). `ARC` needs no `release`, but its skin needs `T11`. Keep `acts` in step with your skin's
`sre.requiredScenarios`: list only the modules you built.

The guide is one document for every act, so its context always needs the Container
App, Arc machine and LOB fields above. A deployment that requires only `T12` can run
the incident from the [T12 runbook](t12-friday-release.md), but it can't generate the
guide: the generator rejects the missing fields. Save the full context to get the
guide, or present T12 from the runbook.

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

Sending the request spends agent usage and reads logs and metadata. It runs no
fault, notification, guest command or repair and adds no role or connector. Keep
Review and the existing tools unchanged. Stop if access is denied, if the agent
asks to elevate, or if you see unexpected side effects, and never accept a request
to add permissions for the query. Keep the exact Azure Monitor platform
prerequisite described below.
The [supported interaction](https://learn.microsoft.com/azure/sre-agent/first-investigation)
is New thread, a specific scoped prompt, then Send.

Success needs a completed SRE query with real target-bound rows/timestamps and
an evidence-grounded explanation with conditional next checks. If only 4000
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

The default incident is an **app-warning-only** scenario. It does not
allocate load, consume extra disk or crash/restart the worker. Before you run it,
decide the host, the warning duration, how long you will watch, and who gets the
existing notifications, and check the usage cost. Actual bounded CPU/memory/disk
load is a different scenario and is not implemented here.

Run `Invoke-LobArcAppOnArc.ps1 -Action WarnForDuration -WarningSeconds 120` with
your explicit target inputs: subscription, tenant, resource group, machine, task,
app root, source and saved skin, never defaults guessed from an ambient login.
Preview with `-WhatIf` first; pass `-ApproveWarningWindow` to confirm you want the
warning window. `-GuestScriptOutputPath` renders the same guarded guest script
offline without running it. No new deployment or agent tool is needed.

The guest baseline requires Healthy mode, the expected source, a running task,
the existing worker PID bound to this script/config and a 5-to-60-second loop.
It requires at least two app cycles, temporarily changes only the mode and
incident marker, and restores the exact original config in `finally` if that
config is still its own. It does not restart the task or kill a process. It
checks actual local 4200 events and continued worker/task state. Duration is
30 to 180 seconds; the existing Arc command timeout is 300 seconds.
This is best-effort scoped cleanup, not a watchdog: session/process termination,
Run Command ambiguity or a concurrent edit can leave recovery unverified.
Stop, inspect the existing command and config, and run `-Action ResetFault` only
if that is appropriate. Never blindly retry, overwrite another change, approve an
SRE repair card or suppress a cleanup error.

Before you run it, take a fresh read-only readiness and host baseline and check
the existing scheduled rule, Action Group, the enabled LOB title keyword/Sev2/Review
match, and the enabled three-hour cooldown.
The source rule has count greater than zero for 4100/4101/4200, one failing
evaluation, a ten-minute lookback and five-minute evaluation frequency.
Warning severity on the Windows event still routes through a Sev2 Azure alert.
No rule, routing, cooldown, RBAC or connector change is part of this scenario.
An already fired alert or cooldown can prevent a new incident. Confirm current
eligibility; do not bypass it.

The source handling-agent instructions include 4200 and the configured host
counters. Changing source alone does not update a deployed agent.
Before live automatic correlation, render and Inspect the desired configuration,
read the exact changes, then apply the handler-only update with a new external
backup. If you are enabling SQL as well, use the larger scope below instead.
Stop if the preview shows changes you did not expect. Re-read the instructions
and run the required readiness checks before the warning. This change needs no
new tools or permissions.

Suggested limits: take a fresh ten-minute baseline, warn for 120 seconds, and
expect a verified Healthy config and the original running worker by five minutes
after the guest start. If restoration is unverified, stop the presentation and
inspect before you run `-Action ResetFault`. Watch for the alert and new incident
for at most twenty minutes after that start, without rerunning the warning or
bypassing cooldown. Capture at least five minutes of post-window host samples where
available, and take timestamps from the command result. Existing Action Group
receivers may get fired/resolved notifications and the agent may use
investigation/query usage, so check the actual recipients first. No new receiver,
chat request or rule is created.

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
investigations exposed only partial tool/report evidence.

### SQL setup and sequential rehearsal

The Arc repo handles SQL installation, license decisions, the normal Orders worker,
the bounded incident and cleanup helper, Application collection and the optional
`sql-incident-alert.bicep` module. Make sure its engine, worker and cleanup checks
pass before SRE setup. This repo neither installs SQL nor accepts a license. The
signal both repos use is real lock timeout 1222 on an owned probe row, not a
deadlock or an Orders outage. See the supported
[1222 explanation](https://learn.microsoft.com/sql/relational-databases/errors-events/mssqlserver-1222-database-engine-error).

Enable the optional `SQL` scenario in your private skin:
append it to `sre.requiredScenarios`, set `sre.sqlTargetArcMachine` to the actual
SQL Arc host and supply distinct `labels.sqlResponsePlan`, exact
`labels.sqlAlertTitleContains = Arc SQL lock timeout` and
`labels.sqlEventSource = ArcSqlEngineDemo`. The two fictional examples keep SQL
disabled. You never edit these fields to present, or hunt for resource IDs.

For an already running two-route demo, an exact managed Arc resource group
already covers its SQL host. Use an in-place handler instruction update and one
SQL filter without redeploying that parent. Existing T09/LOB plans, Review, Sev2,
enabled three-hour cooldown, tools, identity and group grants remain unchanged.
For a fresh deployment or rebuild, review `Deploy-SreAgent.ps1 -WhatIf`, then pass
`-ApproveParentCreation` (it starts AAU billing).
An existing parent is refused before IaC; heed the
[parent preview warning](sre-response-plan-automation.md#existing-parent-preview-warning).
Before that preview, complete the [rebuild prerequisites](../README.md#rebuild-prerequisites):
the Arc estate's Container App and restart alert, plus the LOB alert creation and
LOB app deployment, using the same absolute private skin.
Install the required CLI extensions and preserve the Windows CLI's bundled
Python launcher. Missing scenario prerequisites fail their own readiness checks;
they do not hide later handler, plan or grant findings.
Render and Inspect the configuration, read the exact changes, Apply with a new
external backup and repeat to prove it is a no-op. Stop on unrelated differences,
denial or ambiguous writes.
Required SRE readiness also validates the exact SQL alert predicate, tags,
host, LAW, Action Group and one-minute/fifteen-minute settings. It does not run
KQL or certify the guest engine, collection or automatic investigation.

Run one SQL window and one LOB window, **sequentially**, only after fresh readiness
and a check of the Action Group receivers (common schema) and SRE delivery. Expect
possible fired/resolved notifications and ingestion, query and SRE charges. Check
each alert's Monitor condition and actual cooldown; don't disable routing or
cooldown to force a new incident. The
[reset procedure](sre-response-plan-automation.md#reset-between-demo-runs)
distinguishes the three-hour filter setting from Azure Monitor's seven-day
same-rule merge; alert/thread closure alone is not a documented reset. Its
scripted route helper is `Invoke-SreDemoRoute.ps1 -Action Prepare` before a
fresh fault and `-Action Restore` afterwards. Use the existing
inspection path for actual completed tool output, not merely a tool-start label
or truncated narrative. If that path is unavailable, state the evidence limit
before the run instead of claiming full verification.

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
A pending Review card is visible in the thread messages, not in the approvals
endpoint. On the rebuilt agent the proposed write was a thread message whose
`azCliExecution.status` was `Pending` (not started, not completed), and the audit
table showed `ToolStart` for `RunAzCliWriteCommands` with no `ToolEnd`, while
`GET /api/v1/approvals/{threadId}` returned nothing and every message's `approval`
field was null. Detect a pending card from the messages; an empty approvals
response does not mean there is no card. No `ApprovalDecision` event appeared
either, but the Azure CLI execution record for the approved command
(`AgentAzCliExecution` in Learn's event list) carried a `User` that matched the
portal user, so that field attributes the approver. Still say "a person approved
it": it shows who clicked, not that the card was current.
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
repo's verified cleanup and healthy Orders result within five minutes of the
accepted start (the suggested recovery deadline). Stop if it cannot be proved,
and use only the Arc repo's own cleanup.
Observe event 6201/detected, matching 6001/recovered, a new SQL alert, actual
SRE delivery, completed target-bound Event/Perf queries and recommendations for
at most twenty minutes. Recovery normally precedes alert evaluation because
the rule retains fifteen minutes of events. Do not retry a consumed fault,
send an extra chat request or infer a current blocker from an old alert.
Only after SQL cleanup is verified may the separate LOB warning window begin,
using the bounds above. Missing/denied/stalled evidence is an actual incomplete
stage, not a successful automatic RCA. Save evidence privately and refresh the
local SQL context from your read-backs only after setup is verified.

## Build, park and remove: the steps

Your AI tool can follow these steps; they are the same if you run them yourself.
Give it the tenant and subscription, your private skin and the desired state:
Active (`Ready` still works as an alias), Hibernated or Removed. Never take the
target from an ambient Azure login, and keep runtime identifiers and credentials
out of git.

For Active:

1. Confirm the Arc estate is active using Arc readiness and actual inventory.
2. Validate the skin offline: run `Initialize-SreConfiguration.ps1` with only the
   explicit target and `-SkinPath` (no cloud calls), then the local mocked tests and
   Bicep compilation. Create the T11 LOB app/alert, enable SQL and, for T12, deploy
   the ticketing workload with `Deploy-TicketingWorkload.ps1` as the README
   prerequisites and the [T12 runbook](t12-friday-release.md) describe.
3. Preview `Deploy-SreAgent.ps1 -WhatIf` and read the diff before changes.
   On a fresh parent the offline render is the configuration preview.
4. Deploy with `-ApproveParentCreation`, `-GrantAzureMonitorAlertAccess` and a new
   external `-ConfigurationBackupPath`. The grant switch confirms the one
   subscription role assignment a first build needs: readiness fails without it, and
   Deploy refuses an existing parent. A wake needs no change. Deploy creates the
   parent, then applies and verifies the handler and plans. Use
   `-ParentOnly` (deliberately not a claim that the demo is Ready) only to review
   the configuration preview first.
5. For a running parent, or after `-ParentOnly`, render
   `Initialize-SreConfiguration.ps1`, then `-Inspect` via pinned official template
   protocols. Read the full preview before `-Apply` with a new external
   `-BackupPath`. Unsupported legacy settings/P1-P2 stop without migration; use
   the canonical supported fallback, never guessed endpoints or duplicate plans.
6. Run `Test-SreReadiness.ps1`: handler, plan, Sev2 filters, legacy fields, Review
   and overlap have full read-back. Its telemetry item is optional, skipped/not
   evaluated; all required checks must pass. Don't rewrite the report.
   Existing ARM success is not routing
   readiness. Don't induce a fault merely to answer a read-only readiness check.
7. T09 is the primary Review closed-loop capability; a new instance still needs
   its own incident run before you claim a live success.
   Present T10/T11 as hybrid evidence plus Arc Run Command
   recovery that you run. T11 RCA is not reliable yet. Use the canonical guide's
   evidence-only fallback rather than treating old-instance proof as a new-instance
   pass.
8. Leave a demo you still need running; don't hibernate automatically.
   Refresh `.local/demo-context.json` from your inputs and read-backs and run
   `New-PresenterRunsheet.ps1` so you open one filled-in SRE guide.

For Hibernated:

1. Export the current Inspect output plus any incident/audit evidence you need,
   outside git. This is not a history restore.
2. Save the SRE user-assigned identity principal ID.
3. Preview `Hibernate-SreAgent.ps1 -WhatIf`, then run it. It is ConfirmImpact High:
   a non-interactive host must add `-Confirm:$false` or it stops before changing
   anything.
4. Normal parking deletes only the paid parent; retains SRE group/UAMI, existing
   workload grants, workspace AppInsights and owned Action Group.
   Verify retained principal and parent absence with `Test-SreReadiness.ps1
   -DesiredState Hibernated -PreviousIdentityPrincipalId <saved ID>`.
   Missing legacy diagnostics or stale free grants are optional wake diagnostics,
   not a reason to leave the paid parent running. Denied inspection still fails.
   With T12, the ticketing workload keeps running and its plan keeps billing: remove
   it with `Remove-TicketingWorkload.ps1` when you're finished.
5. Finish SRE verification before Arc hibernation. Arc lifecycle is separate;
   don't stop its workloads from this repo. Wake/verify Arc before SRE.

For Removed:

1. Keep your exports and the saved principal.
2. Preview `Remove-SreAgent.ps1 -WhatIf` with the same explicit target and skin.
   With T12, park the agent and run `Remove-TicketingWorkload.ps1` (preview first)
   before this step.
3. Unknown resources/roles/scopes block removal: check what they are rather than
   bypassing the block.
4. Run it (`-Confirm:$false` in a non-interactive host); known
   grants/resources are removed before deleting
   the empty dedicated group. Shared Arc/Monitor and your private exports are
   untouched.
5. Verify `-DesiredState Removed` with the saved principal. Without that principal,
   external-grant absence is pending even when the group is gone.

None of these steps changes plans to Autonomous, removes quickstart plans, revokes
extra grants or connects a repository; do those only if you ask. The one exception
is T12's code repository: it is connected only after you sign in to GitHub yourself
(`Initialize-SreConfiguration.ps1 -Apply -GitHubSignIn`), and only after the GitHub
`ask` policy and the repository-only instruction are in place.

## Run one incident after setup (optional)

Once setup passes readiness you can run one T09 incident to see the closed loop:
[the T09 runbook](t09-native-containerapp-closed-loop.md#5-induce-the-fault). It
briefly breaks the demo Container App, can send configured alert notifications and
uses SRE agent usage. In Review mode the agent investigates and proposes a reset,
and you click **Approve** in the SRE portal
([click path](t09-native-containerapp-closed-loop.md#7-approve-the-governed-fix)).
Ask your AI tool to run it, or follow the runbook yourself.

- Check the healthy baseline first: the app healthy, the previous run's recovery
  done, fresh Arc readiness and passing required SRE checks.
- Keep Review and the enabled three-hour cooldown. Cooldown may reuse an existing
  thread, so inspect the actual alert and investigation in the SRE portal.
- Be at the portal's Incidents view when the fault fires. In the first rebuilt run
  the Review card appeared about 7 minutes after the fault, so waiting up to 20
  minutes after the fault left about 13 minutes to approve it. If you haven't
  approved by then, reset the app yourself with
  `Invoke-NativeContainerAppFault.ps1 -State Repair` and call it a manual reset,
  not agent repair. If your AI tool is inside a long wait, tell it when you have
  approved: it may only see your message when that wait returns.
- After you reset the app yourself, the Review card stays Pending and approvable.
  Deny it, or leave it alone. In the first rebuilt run it was approved 21 minutes
  later and the agent's write ran as a no-op, but the same click on a
  non-idempotent proposal would change Azure after you had already acted.

Afterwards, check the false flag, the serving revision and HTTP 200, and read the
Monitor condition separately from the alert workflow state and thread closure. The
helper has no automatic watchdog or hard cancellation. Missing or uncertain
evidence is pending, not a successful loop. After an ambiguous write, inspect the
state instead of repeating the fault. This produces new evidence; it doesn't
restore history lost when a parent is deleted.

## Runtime commands

Sign in to your tenant yourself first with `az login --tenant <TENANT_ID>`. If an
AI tool is driving, it asks you to do this and waits rather than running it.

```powershell
# Scripts pass --subscription on every request and never run az account set.
# <PRIVATE_LAB_FOLDER>\sre-skin.json is your private skin (kept outside git).
.\tests\Invoke-Tests.ps1
az bicep build --file .\infra\main.bicep --stdout

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -WhatIf

# -GrantAzureMonitorAlertAccess confirms the one subscription role assignment a
# first build needs. A wake needs no change: an existing grant is left alone.
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -ApproveParentCreation `
  -GrantAzureMonitorAlertAccess `
  -ConfigurationBackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>

# The steps below are the manual route: -ParentOnly (not Ready) and then
# configuration by hand. They are also how to change configuration on a
# running parent, which Deploy refuses.
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -ParentOnly -ApproveParentCreation `
  -GrantAzureMonitorAlertAccess

.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json

# Read the full objects and preview before any writes.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json -Inspect

# Apply it once you have read that exact configuration scope.
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
contract.

## Lifecycle and permission boundaries

SRE has a deletion-based off state, not VM-style deallocation. Deletion discards
handler/plan/history/memory/connector state. Parent redeployment is only stage one
of reconstruction. Resume requires data-plane setup and verification again.
Save evidence before cleanup, and reconnect optional repositories yourself.
Versioned assets recreate the modern custom agent/v3 filters, not retired
legacy objects, saved threads or learned memory. A separate IaC module creates
the SRE-only UAMI on first deployment; later normal cycles retain it in the SRE
group and reuse its principal and deterministic workload grant IDs. Parent
SystemAssigned,UserAssigned compatibility is unchanged: its system principal
still rotates, without external workload grants. Do not promise zero directory
churn. Historical whole-group deletion needs one replacement UAMI; that deleted
principal cannot be restored. Full group/identity removal is a separate cleanup
step, never part of ordinary hibernation. The renderer enforces true/3-hour cooldown.

The deploying identity may be User or ServicePrincipal (including managed
identity). The script infers known Azure CLI identity types; pass
`-DeployerPrincipalType` for an unrecognized execution identity. RBAC names include
the live principal and adopt existing same-principal role assignments. Incremental
Bicep does not remove obsolete grants; Low downgrade with existing write grants
fails explicitly until you reconcile them.

High uses Reader/Log Analytics Contributor/Contributor at the two workload groups.
Low uses true Log Analytics Reader, not the formerly mislabeled Contributor ID.
Hibernate retains existing grants (free, but still standing access); before Active,
deployment/readiness reject incompatible/inherited/extra grants for you to
reconcile. The sole exception is one existing subscription
Monitoring Contributor grant for the exact retained UAMI, including while the
parent is absent or its incident platform is disconnected. It is a documented
[platform prerequisite](https://learn.microsoft.com/azure/sre-agent/permissions).
A first build needs that grant. `-GrantAzureMonitorAlertAccess`, on Deploy or on the
[standalone grant script](sre-response-plan-automation.md#explicit-azure-monitor-access-grant),
is the switch that confirms its creation;
other scopes/roles/principals and duplicates are not exempt.
Fresh/wake Bicep sets `incidentManagementConfiguration.type = AzMonitor`; the
grant script supplies the scanner role. No routine portal connection
step is required. Read back the selection and grant separately. The existing
`incident-platform` check reads ARM configuration, not scanner health: an
unset/non-AzMonitor selection emits an advisory warning, not a new required gate.
Only if that check shows the platform is not configured, use the
[portal fallback](sre-response-plan-automation.md#explicit-azure-monitor-access-grant).
Fresh-agent intake through IaC plus the grant worked on the 2026-11-05 from-zero
rebuild for T09 only ([evidence and limits](sre-response-plan-automation.md#live-lifecycle-proof-2026-11-05));
SQL and LOB delivery need their own runs. Never infer this state
from optional connector files. Deployment adopts
existing direct assignment names and does not query Graph display names.
Retained AppInsights must match the requested workspace/location; wake does not
silently relocate it. Older UAMI-only parking rebuilds missing diagnostics through
the same IaC. No grants are removed during Active or normal Hibernate.
Removed inventories principal-filtered ARM assignments with bounded validated
pagination; unexpected SRE resources or scoped grants block its destructive path.

Local checks cover parser/schema/rendering/mocked failures and safety behavior.
They do not prove Azure data-plane create reliability, destructive lifecycle
rebuild, live guest execution or a new T09 alert-to-recovery run. The separate
2026-11-05 live session exercised the build, Hibernate and wake paths and one T09
alert-to-card chain; its limits, including the still-unproven clean in-window
repair, are in the [evidence boundaries](sre-response-plan-automation.md#live-lifecycle-proof-2026-11-05).
