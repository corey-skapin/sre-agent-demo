# Arc + Monitor + SRE: first-time presenter's 30-minute guide

This is the **single combined presenter guide**, not a deployment recipe or a
certificate that a particular lab is ready. Start with [the docs map](README.md).
The companion Arc repo remains independently presentable.

**Story:** Arc gives a hybrid estate an Azure operations plane; Monitor supplies
evidence; SRE Agent adds investigation and a human-controlled Azure repair.
T09 is the primary Review closed-loop path. T10/T11 are hybrid signal/evidence
plus **operator** Arc Run Command recovery, not autonomous Arc server repair.
T11's final SRE RCA has stalled in prior runs; do not promise it live.

**Evidence boundary:** a previous instance completed the recorded T09 retry.
The replacement instance's configuration was reconstructed and read-back verified,
but a new end-to-end fault/approval/repair rehearsal was not performed. A retained
identity park/wake round trip is also unverified. Old thread IDs, screenshots and
successes are not current-instance proof.

**Activating with Copilot first?** After the requested combined activation and
fresh Arc/SRE health checks, the SRE-owning assistant must
[offer one optional T09 incident in conversation](ai-deploy-handbook.md#post-activation-incident-offer).
It runs the existing procedure only if you agree and guides you to the real
human Review approval; you do not have to select/run scripts. Declining leaves
the activated lab running. This is a once-only setup handoff, not a fault
trigger during the read-only navigation rehearsal below.

## 1. Prepare your private input card

Allow preparation time before the 30-minute talk. Ask the deployment owner for an
already active, configured lab and fill this card outside git. Generic examples
below are labels, not targets to copy blindly; resolve actual values from the
retained private skins and current resource inventory.

| Input to record privately | Where it comes from / example |
| --- | --- |
| Tenant, subscription, both checkout paths and both private skin paths | Deployment owner; never infer an ambient account or use a fictional skin against a different existing estate. |
| Arc RG, infra RG, SRE RG | Skin/inventory; examples `rg-arc-demo`, `rg-arc-demo-infra`, `rg-arc-demo-sre`. |
| Workbook, Log Analytics workspace and Windows Arc machine | Arc guide/resource map; example machine `win-app-01`. Include the machine's exact Arc resource ID, not its backing VM ID. |
| Container App and healthy application URL | Current inventory; example `ca-arc-demo-fault`. Obtain the actual hostname from read-only Status below, not a guessed URL. |
| T09/T11 alert rules and current alert evidence | Examples `alert-arc-demo-containerapp-restarts` and `alert-arc-demo-lob-arc-app-fault`; save IDs, timestamps and conditions when actual alerts exist. |
| SRE parent, retained UAMI/principal and current routes | Private skin plus Inspect; examples `sre-arc-demo`, `container-app-restart-review-v3`, `lob-arc-app-review-v3`. |
| Existing investigation link, ID, creation time and instance | Only if one exists. Record whether it is current or historical and whether an actual pending operation exists. Never invent a fresh thread. |
| Recovery owner, administrator and hard deadline | Required only for an explicitly approved live T09 window, with exact target, false-reset fallback and who performs it. |
| Shareable fallback evidence | An approved recording/transcript with date, instance and actual outcome, if available. Otherwise use configuration/healthy-app explanation, not a fabricated recording. |

Keep customer/account context and raw exports off the projected screen. Have
existing Azure resource read access, Log Analytics query access and SRE access
ready. **Only an SRE Agent Administrator can approve Azure infrastructure actions.**
Reader access or an agent's managed identity is not your approval role. Have the
owner resolve missing access beforehand; do not grant permissions, authenticate
connectors or consent to temporary elevated access during the demo.

## 2. Rehearse once without changing the lab

1. **Sign in beforehand using the approved lab account.** Open
   `https://portal.azure.com` and `https://sre.azure.com`. Check the intended
   directory/subscription and agent, not a similarly named resource or a trial
   creation screen. If access/onboarding is incomplete, stop for the deployment
   owner rather than creating a replacement.
2. **Require fresh Arc readiness.** In the companion checkout follow its
   `docs\runsheet.md` preflight. Record the activation command result separately
   from readiness. Require current expected-ID Heartbeats/Connected resources
   and healthy compute/networking, not an old screenshot.
3. **Inspect SRE read-only in its checkout.** Substitute your real private inputs:
   use **PowerShell 7.4+ (`pwsh`)** and the deployment's already configured Azure
   CLI, not Windows PowerShell 5.1 or a Bash prompt. Missing tooling/extensions
   are setup work for the owner, not something to install during the talk.

   ```powershell
   cd '<SRE_CHECKOUT>'
   $sreTarget = @{
     SubscriptionId = '<SUBSCRIPTION_ID>'
     TenantId = '<TENANT_ID>'
     SkinPath = '<ABSOLUTE_PRIVATE_SRE_SKIN_PATH>'
   }
   .\scripts\Test-SreReadiness.ps1 @sreTarget -DesiredState Ready `
     -OutputFormat Table -TimeoutSeconds 180
   $readinessExit = $LASTEXITCODE
   $readinessExit # Record this and the individual required check outcomes.
   .\scripts\Initialize-SreConfiguration.ps1 @sreTarget -Inspect
   $appStatus = .\scripts\Invoke-NativeContainerAppFault.ps1 @sreTarget -State Status
   $appStatus | Format-Table Name, SimulateCrash, LatestRevision, ProvisioningState
   (Invoke-WebRequest -Uri "https://$($appStatus.Fqdn)" -TimeoutSec 20).StatusCode
   ```

   All required configuration/resource checks must pass. The named
   `telemetry-and-alerts` check is optional, **skipped / not evaluated**; it does
   not certify a rehearsal or prevent exit 0. Do not ignore required failures or
   pending checks. Inspect should show one intended custom
   agent, two enabled v3 AzMonitor/Sev2/Review routes, enabled three-hour cooldown,
   no active legacy handler and no enabled duplicate/quickstart conflict. Do not
   run Apply, deploy or change routing to make an audience view look complete.
4. **Confirm the workload baseline.** Status must show `SimulateCrash=false`;
   the HTTP check must return 200. In the app's **Revisions and replicas** view
   check the serving revision, healthy replicas and traffic. A successful ARM
   deployment or zero request volume alone is not availability proof.
5. **Open and bookmark the tabs in section 3.** Run each read-only query once,
   check scope/time range and rehearse its fallback. Save actual browser URLs
   privately; never construct undocumented SRE thread routes.
6. **Choose the presentation mode.** Default is **evidence-only**: healthy app,
   current configuration and clearly dated prior evidence if available.
   Live T09 additionally needs a separately authorized bounded break/reset window
   and a successful current-instance functional rehearsal. This documentation
   review authorizes neither. A navigation-only practice is not that rehearsal.

Rehearse the sentences in the timed table with a stopwatch. No agent chat
prompts, new assessments, guest Run Commands, test notifications, faults or
approvals are required to practice navigation. Even the T11 helper's `Status`
executes a guest Run Command; use existing log evidence instead.

## 3. Open these tabs and know what to select

Directions were grounded on **2026-10-21** in the sources below. The local browser
check reached only the unsigned-in SRE landing page; authenticated lab blades and
an actual pending approval card were **not observed**. Published Learn screenshots
are reference UI, not screenshots of this estate. Rehearsal must verify visible
labels and bookmarks; a missing blade/card is a fallback condition, not a reason
to guess or mutate resources.

| Tab | Open / select | Expected visible result and safe fallback |
| --- | --- | --- |
| A: Arc workbook and resource | Follow companion `docs\runsheet.md#present-the-arcmonitor-demo`: workbook, scoped LAW Logs, Monitor alerts, then Arc identity. Use the actual workbook/resource names from your card. | Actual OS/monitoring coverage and an Arc machine (`Microsoft.HybridCompute/machines`), not its backing Azure VM. Skip that guide's optional updates/security/policy expansion to fit this combined slot. |
| B: Workspace Logs | Azure portal global search: find the exact Log Analytics workspace, select it, then **Logs**. If Simple mode opens, use the dropdown at the query editor's top right to select **KQL mode**. Use the Arc guide's prepared scoped queries, select **Run**, check time and resource IDs. | Recent expected-ID Heartbeats and available change/event rows. Empty data means check scope/range and disclose it; do not create a change or assessment to fill the screen. |
| C: Monitor alerts | Azure portal **Monitor > Alerts**; use the prepared scope/time filters and open the exact alert if present. For rule-only proof use **Alert rules**, find the exact rule and inspect it without editing. | Rule/resource/severity/time plus actual **Monitor condition**. A healthy estate may have no fired alert. Show the rule and say it proves configuration, not current delivery or incident execution. |
| D: Healthy app | Azure portal search: **Container Apps**, choose the actual app, then **Revisions and replicas**. Separately open `https://` plus the Status `Fqdn` in a browser tab. | Serving health/traffic plus working HTTP endpoint. Do not select Create new revision, edit variables, restart or scale. If unhealthy, stop the live-ready claim and notify the recovery owner. |
| E: SRE routes | Open your existing agent at `https://sre.azure.com`. Current Learn describes **Incidents > Triggers + response plans**; other published pages show **Builder > Incident response plans**. Use only the path actually visible and verified during rehearsal; inspect the existing route, never create/save/toggle it. | Intended handler, On, Review, exact Sev2/title and three-hour cooldown. If neither documented layout is present, show the private read-only Inspect summary rather than invent another menu or using an old screenshot as current UI. |
| F: SRE investigation | Use a verified existing thread bookmark. Alternatively, Learn's published incident-list screenshot shows **Activities > Incidents**: find the exact alert title/ID/time and select its title link. Confirm identity/time again in the opened investigation. | Existing investigation conversation, evidence and proposed operation if one exists. An empty new instance is normal. Do not start a chat or create an incident simply to populate it. |
| G: SRE audit | In the agent, documented **Monitor > Logs** opens its Application Insights resource in Azure portal. Alternatively open that exact Application Insights resource directly and select **Logs**; use KQL mode for the audit query below. | Timestamped events for the exact current thread, if emitted. Empty telemetry is an observation limit, not proof of approval, success or failure. |
| H: Azure write attribution | Open the exact Container App resource in Azure portal and select **Activity log**; set the approved run's time window, inspect the matching write event and its JSON/caller details. | Actual successful write and caller, correlated to tool completion/current UAMI. A similarly timed operator write must not be relabeled SRE repair. Use saved dated evidence only if current events are absent. |

The two documented SRE navigation layouts are an unresolved documentation/rollout
difference, not verified synonyms in this lab. Do not teach the older Builder
path as universal. Record the path you actually see; direct verified bookmarks
and supported read-only Inspect are the grounded alternatives.

## 4. Present the combined demo

Joining after a complete Arc-only presentation? Do not repeat its tour. Resume
at the **11:00 governance** row, then the T09/evidence, audit and closeout rows;
optionally show the short T11 query first. This is an SRE extension to the
completed Arc talk, not a claim that both full talks fit in 30 minutes.

| Time | Your actions | Say | Expected result / fallback |
| --- | --- | --- | --- |
| 00:00-03:00 | Tab A: show the workbook's actual fleet/OS coverage. Identify one Windows and one Linux row if present. | "These are hybrid-shaped servers. Arc gives them an Azure identity and operations plane; the lab's backing VMs are not a claim that Azure powers real on-prem servers." | Use actual inventory, not a promised fixed fleet count. |
| 03:00-08:00 | Tabs B/C, then the selected Arc resource: run the prepared scoped Heartbeat/change query, inspect an available alert or its rule, show Arc identity. | "Resource identity connects the server to a signal. These timestamps show freshness; a configured rule is different from a delivered notification." | Follow the Arc guide's core stops, not its full standalone timeline. No email tests or recipient verification changes. |
| 08:00-11:00 | Tab B: run the T11 query below. Show healthy 4000 rows and any available 4100 evidence with its actual timestamp. | "An application event on an Arc server can become Azure Monitor evidence. Recovery here is an operator's governed Arc Run Command, not autonomous SRE server repair." | No 4100 row is not a fresh fault. Explain the mechanism or show labeled prior evidence; never induce T11. |
| 11:00-14:00 | Tab E: show the two existing routes and their handler, Review and cooldown. | "The route narrows which incident is investigated. RBAC limits access, and Review requires a human decision for Azure infrastructure writes; it is not blanket approval governance for emails or every external tool." | Use verified Inspect output if UI differs. Missing configuration means stop claiming a live SRE path. |
| 14:00-22:00 | Tabs D/F: in evidence-only mode show the healthy app plus a dated prior investigation if available. For a separately rehearsed/authorized live run, follow section 5 with the recovery owner. | "The intended loop is alert, evidence, proposed narrow fix, actual approval, then independently verified recovery." | Healthy configuration is not a new closed-loop pass. If no shareable prior proof exists, explain the flow without calling it a recording or current result. |
| 22:00-26:00 | Tabs G/H/D/C: show matching tool completion, actual write caller and app health; check Monitor condition separately. | "A proposed command is not execution. This caller and completed tool result establish who acted; HTTP health and Monitor recovery are separate observations." | Use actual current outcomes. Monitor resolution can lag beyond the meeting; don't force-close or change a rule. |
| 26:00-30:00 | Return to the architecture/workbook; close on a scoped non-production PoC. | "Reuse the skin and stable identity. Park explicitly after the session; a Stopped SRE parent is still billed. Real customer monitoring normally stays available rather than deleting its history." | No automatic cleanup, permission change, repository connection or autonomy change at close. |

### T11 read-only query

In **workspace Logs**, substitute the exact Arc resource ID and event source from
your card before selecting Run. This query is not a guest operation:

```kusto
Event
| where TimeGenerated > ago(24h)
| where _ResourceId =~ "<ARC_MACHINE_RESOURCE_ID>"
| where Source == "<LOB_EVENT_SOURCE>"
| where EventID in (4000, 4100)
| project TimeGenerated, Computer, EventID, RenderedDescription
| top 20 by TimeGenerated desc
```

Default source is `ArcLobBridgeApp`. Event 4000 is healthy heartbeat; 4100 is the
sample fatal-processing event, **not a generic Windows failure code**. Check the
payload privately before projecting it. Widen the lookback only to inspect known
historical evidence and name its date. No rows: show the current alert-rule query
or the labeled engineering ledger, then continue. Do not run Deploy, InduceFault,
CollectLogs, Status or ResetFault merely to make this presentation scene work.

## 5. Live T09 only: where the real approval happens

This section is for an already authorized window, not authorization itself.
The operator follows [the T09 runbook](t09-native-containerapp-closed-loop.md)
for the one break/reset and fallback. Record the deadline and owner **before**
the break. The helper does not install an automatic recovery watchdog.

1. Recheck false flag, serving health, HTTP 200, recovered Monitor condition and
   correct routes. Repeated alert fires can merge/reopen an older investigation
   during the enabled **three-hour cooldown**. Do not disable it or repeat a
   fault just to get a new card.
2. After the one authorized break, use tab C's actual new alert/time, then tab F's
   corresponding investigation. Confirm the actual ID rather than assuming the
   newest or previously closed thread is the current run.
3. **Approval is inside that investigation conversation, on the proposed Azure
   infrastructure operation.** Open its operation details if collapsed and
   inspect the full command and arguments. Learn documents **Approve / Deny**
   on that operation; there is no approval to perform in the Azure Monitor alert
   workflow or by typing "approved" into chat. Exact pending-card placement was
   not locally observed in this review.
4. Only the signed-in administrator, under the approved run scope, selects
   **Approve** for the exact current app/group/subscription and the narrow
   `SIMULATE_CRASH=false` reset. A permission/temporary-access prompt, different
   write, stale card, RCA prose, `ToolStart` or "approved" narration is **not**
   this approval. Stop rather than consenting, broadening scope or switching to
   Autonomous. Do not select Deny/cancel an obsolete request without its own
   appropriate authorization.
5. If no real pending card appears, do not hunt for a global approval button or
   substitute a chat message. At the recovery owner's **pre-agreed deadline**,
   use only the already authorized narrow operator reset if needed. Surface
   restore failure immediately. Once operator recovery occurs, leave the stale
   SRE proposal unapproved and call the outcome **operator fallback**, not an
   SRE closed-loop pass.
6. Independently correlate completed tool result, successful Azure write/caller,
   false flag, healthy serving revision/traffic and HTTP 200. Actual Monitor
   condition resolves on its own evaluation schedule; workflow Closed or
   Acknowledged is not that condition.

**Timing:** the metric alert alone can take 5-10 minutes; RCA, approval and
recovery add time. Monitor resolution took about 17 minutes after the write in
the prior recorded retry. An eight-minute talk slot cannot guarantee a complete
new cycle. Agree any pre-staging explicitly within the bounded fault window and
disclose it; never silently break the app early, extend the recovery deadline or
hold the rest of the presentation waiting. At the slot end, report the actual
outcome and continue with the prepared fallback.

## 6. Show evidence without overstating it

In **Application Insights resource Logs** (not workspace-scoped table names),
substitute the actual thread ID and the correct run time range:

```kusto
customEvents
| where timestamp > ago(2h)
| where tostring(customDimensions.ThreadId) == "<CURRENT_THREAD_ID>"
| where name in ("AgentToolExecution", "ApprovalDecision",
    "AgentAzCliExecution", "IncidentActivitySnapshot")
| project timestamp, name, customDimensions
| order by timestamp asc
```

Expand the matching events: correlate `ToolStart` and `ToolEnd` using `CallId`;
read the actual output rather than a request alone. `ApprovalDecision`, when
present, is decision evidence; its absence is not live card state. Compare the
write caller to the **current** retained UAMI, not a deleted predecessor or the
operator. Check `ResponsePlanId`, Review and actual assisted/mitigated outcome.
Keep raw identifiers/results private.

The previous successful retry combined user-reported approval of the actual card
with independently matched tool completion, SRE-identity write and recovery.
Its bounded query did not capture an independent ApprovalDecision event. It is
historical evidence, not proof that a new instance has completed this loop.

## 7. After the talk

Leave a requested Ready demo running. Parking is a separate authorized operator
task in [response-plan automation](sre-response-plan-automation.md): export needed
evidence, preview, park SRE retaining its UAMI, verify, then park Arc through its
own repo. Wake/verify Arc before reconstructing SRE. Deletion loses history,
memory and connector state; a saved export is not a restore of those things.
Use [the cost guide](sre-cost-and-demo-fidelity.md) for the always-on charge and
residual-cost caveats, not an invented zero-cost claim.

## Grounding sources and observation limits

Reviewed 2026-10-21; these are **documentation-grounded**, not a claim that every
authenticated blade was exercised here:

- [Current incident tutorial](https://learn.microsoft.com/azure/sre-agent/automate-incidents):
  newer documented response-plan path and published Activities/Incidents list
  and investigation-conversation screenshots.
- [Response-plan reference](https://learn.microsoft.com/azure/sre-agent/response-plan):
  alternate Builder layout, route fields, actual three-hour merging behavior.
  Different published layouts require rehearsal verification, not guessing.
- [Run modes](https://learn.microsoft.com/azure/sre-agent/run-modes) and
  [mitigations](https://learn.microsoft.com/azure/sre-agent/execute-mitigations):
  infrastructure-operation Approve/Deny, administrator role and limits of Review.
- [Investigation links](https://learn.microsoft.com/azure/sre-agent/incident-response#share-investigation-threads):
  thread title **... > Copy link to thread** for existing accessible threads;
  save privately, do not post/send it during a read-only walkthrough.
- [Audit actions](https://learn.microsoft.com/azure/sre-agent/audit-agent-actions):
  Monitor > Logs, customEvents, ToolStart/ToolEnd and approval/caller correlation.
- [Container App variables](https://learn.microsoft.com/azure/container-apps/environment-variables)
  and [revisions](https://learn.microsoft.com/azure/container-apps/revisions-manage):
  Container Apps selection, Revisions and replicas and revision-scope changes.
- [Log Analytics modes](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-simple-mode):
  Simple/KQL selection; companion Arc guide provides the scoped monitoring tour.

Local observation was the live unsigned-in `https://sre.azure.com` landing page
with Sign in; no authenticated incident/card, action execution or approval was
observed or generated. No fault, approval, connector consent, notification send,
cloud mutation or lifecycle execution was performed for this documentation review.
