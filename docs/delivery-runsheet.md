# Arc + Monitor + SRE: 30-minute presenter runsheet

Use this as the single presenter path across the two companion repos. It is a
reusable runbook, not certification that a particular lab is currently running.
All organization names in tracked skins are fictional. Keep actual accounts,
cloud identifiers, repository URLs and evidence in a private operator appendix
outside git. Local checkout paths below are examples, not personal paths.

**Story:** Arc gives a hybrid estate an Azure operations plane; Monitor turns it
into signal; SRE Agent adds evidence-led diagnosis and governed action.
T09 is the primary Review-mode closed-loop demonstration. T10/T11 are hybrid
evidence plus operator Arc Run Command recovery, not autonomous server repair.
T11 RCA generation can stall; do not promise reliable SRE RCA there.

## Before the audience arrives

1. Use the retained private skins and explicit subscription/tenant. Run Arc
   readiness from its own checkout, require fresh Connected/Heartbeat evidence,
   and verify active compute/networking. A successful readiness report does not
   erase a failed activation command: record the command result separately.
2. Require a current SRE parent, the expected retained UAMI and exact approved
   workload grants; verify the custom handler and two v3 routes enabled,
   AzMonitor/Sev2/Review, intended literal keywords and enabled three-hour cooldown.
   No enabled duplicate/quickstart conflict or active legacy response handler.
3. Run SRE read-only readiness. Every required configuration/resource check must
   pass; `telemetry-and-alerts` remains pending/exit 2 because it does not ingest
   rehearsal artifacts. Pair it with separately recorded live evidence, never
   relabel pending as pass. Parent absence is not an audience-ready SRE demo.
4. Verify the Container App has `SIMULATE_CRASH=false`, a healthy serving revision
   with replicas/traffic and HTTP 200. Inspect MonitorCondition, not just alert
   workflow status. If no current proof exists, label any saved run historical.
5. Open Arc inventory, Log Analytics/Monitor, change-tracking evidence, SRE
   incident view and the healthy app endpoint. An operator who can approve the
   exact new Review operation must already be signed in before any fault starts.
6. A request for a runsheet is not permission to inject a fault. Live T09 needs
   explicit approval for one bounded break/reset window, target and fallback.
   Do not induce T11 or change VM/network/Defender settings for this walkthrough.

The current-source bootstrap, permission boundaries and supported full read-back
are in `sre-response-plan-automation.md`. Use `C:\src\arc-demo\docs\runsheet.md`
for Arc-specific portal/query detail, not a second competing timed presentation.

## The 30-minute flow

| Time | Scene | Show and say | Guard / fallback |
|---|---|---|---|
| 00:00-03:00 | Why one operations plane | Arc inventory, tags, OS mix and resource relationships. "These remain hybrid servers; Arc gives teams a common Azure management surface." | Show actual inventory, not an assumed fixed fleet size. |
| 03:00-09:00 | Monitor and change evidence | Current Heartbeats, useful alerts, change-tracking inventory and recent recorded changes. Explain the link between resource, signal and operational context. | Ingestion can lag. Distinguish current rows from historical examples; do not create changes or assessments merely to fill the view. |
| 09:00-12:00 | Hybrid diagnostic evidence | A Windows Arc machine, the local LOB sample and available Application events. Show how code path, event and resource can be correlated. | Historical Event ID 4100 may illustrate the pattern if clearly labeled. Do not claim it is a current incident or induce a new hybrid fault. |
| 12:00-14:00 | Governed SRE setup | Parent/UAMI scope, the custom handler, modern v3 Sev2 routes, Review and three-hour cooldown. "Write capability is bounded by RBAC and an actual approval card." | If parent/routing is missing, stop the live SRE claim; use architecture and labeled historical evidence only. |
| 14:00-23:00 | T09 primary wow | If separately authorized, one controlled Container App break -> Monitor fire -> intended new investigation/RCA -> exact Review reset -> audit and health recovery. Otherwise show the healthy workload and clearly labeled prior proof. | Follow the bounded procedure below. No approval by chat, stale-card replay, repeated fault or hidden operator repair. |
| 23:00-27:00 | T11 hybrid recovery boundary | Show available event/alert evidence and the operator Run Command recovery path. "The signal is Azure-side; hybrid repair remains operator-led." | No new T11 fault here. Unavailable/stalled RCA is a limit, not a reliable feature to promise. |
| 27:00-30:00 | Reuse, cost and close | Fictional skins/runtime inputs, same stable UAMI on wake, revoked grants while parked, Review and audit evidence. Close with a scoped non-production PoC. | Parking is a separately authorized operator action after the demo, never automatic at the end of this script. |

## T09: approval and recovery choreography

Use `t09-native-containerapp-closed-loop.md` for exact commands and existing
bounded waits. The administrator must be ready before the approved break:

1. Recheck false flag, healthy endpoint, alert recovery and routes. Record the
   exact fault window. One authorization covers one controlled break/reset, not
   repeated attempts or unrelated proposed commands.
2. In `https://sre.azure.com`, open the intended agent and the current investigation.
   Wait for a real operation card with **Approve / Deny**, not merely RCA prose.
3. Confirm it is the **new** investigation/tool request, with the exact current
   app/group/subscription and only the `SIMULATE_CRASH=false` reset described in
   the T09 runbook. Never approve additional permission, autonomy or shell scope.
4. Enabled three-hour cooldown can merge/reopen an older investigation. Do not
   assume a resolved alert or closed thread creates a fresh card. If an old card
   is reused or no actual write request exists, stop and diagnose; do not replay
   it or disable cooldown without a separately scoped approval.
5. Independently verify execution attribution, then healthy serving revision,
   replicas/traffic, HTTP 200 and MonitorCondition recovery. User-reported approval
   is not execution proof; tool narration is not an audit event.
6. At the pre-agreed deadline, restore false using only the authorized narrow
   fallback if SRE repair has not already been independently verified. Surface
   restore failure immediately. Operator fallback is an assisted outcome, not
   an SRE-executed closed-loop pass. Do not run a second fault to improve the story.
7. After fallback, leave any old proposal unapproved. Card cancellation/denial
   needs its own appropriate authorization; closing a thread is not cancellation.

If the nine-minute slot expires, move on with the actual observed outcome and
the healthy app. Use a labeled prior recording only if available. Never imply
deleted pre-hibernation threads, history or optional repository connectors were
restored by the repo. No independent approval-decision event was captured in the
recorded successful retry; user-reported portal approval plus independent tool
completion and managed-identity activity establish that run's narrower proof.

## Operator reference: park SRE first, then Arc

Use separate checkouts and retained private skins; check each exit status.
These are examples to preview and separately authorize, not presenter actions:

```powershell
cd C:\src\sre-agent
$sreTarget = @{
  SubscriptionId = '<SUBSCRIPTION_ID>'
  TenantId = '<TENANT_ID>'
  SkinPath = '<RETAINED_SRE_SKIN_PATH>'
}
.\scripts\Hibernate-SreAgent.ps1 @sreTarget -WhatIf
.\scripts\Hibernate-SreAgent.ps1 @sreTarget -PreviousIdentityPrincipalId '<SAVED_SRE_PRINCIPAL_ID>'
.\scripts\Test-SreReadiness.ps1 @sreTarget -DesiredState Hibernated `
  -PreviousIdentityPrincipalId '<SAVED_SRE_PRINCIPAL_ID>' -OutputFormat Json -TimeoutSeconds 180

# Continue only after retained UAMI, absent parent/diagnostics/grants/admin verified.
cd C:\src\arc-demo
$arcTarget = @{
  SubscriptionId = '<SUBSCRIPTION_ID>'
  TenantId = '<TENANT_ID>'
  NamePrefix = '<PREFIX>'
  SkinPath = '<RETAINED_ARC_SKIN_PATH>'
}
.\scripts\Hibernate-ArcDemo.ps1 @arcTarget -WhatIf
.\scripts\Hibernate-ArcDemo.ps1 @arcTarget
.\scripts\Test-ArcDemoReadiness.ps1 @arcTarget -DesiredState Hibernated -OutputFormat Json -TimeoutSeconds 300
```

SRE removes its parent/known diagnostics and owned grants but retains the SRE-only
UAMI/group. This still loses live configuration/history/memory/connector state;
exports are reference evidence, not automatic history or credential restores.
Only the UAMI principal is stable; parent system identity still rotates.
Identity has no extra charge, but retained storage/monitoring/services can be billable.
Full group/UAMI deletion is separate destructive cleanup, not normal hibernation.

Arc parking retains data/disks/identities/credentials and monitoring while parking
retained compute and deleting only its expected NAT/PIP after compute verification.
It accepts target fields plus ShouldProcess flags, not deployment-feature/cost flags.
Wake Arc and verify it first, then reconstruct SRE with the retained UAMI through
the same IaC and versioned modern handler/routes. Initial creation after historical
whole-group deletion needs one replacement UAMI, not recovery of the deleted one.
No local mocked check or prior in-place repair proves a new complete live
retained-identity park/wake round trip.
