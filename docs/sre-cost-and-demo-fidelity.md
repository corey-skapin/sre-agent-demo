# SRE cost and demo fidelity

Reviewed against official billing guidance on **2026-10-21**. This is the SRE
layer's cost decision record, not an invoice or a claim that the whole lab is free.
The Arc companion owns VM disks, network, the shared Log Analytics workspace and
their separate optimization decisions.

## Keep the useful demonstration

The IaC uses one managed SRE parent for both scenarios, workspace-based Application
Insights and one retained user-assigned identity. The service can also create the
Smart Detection Action Group covered by the lifecycle scripts. There are no
SRE-owned VMs, managed disks or SSD/HDD settings to downgrade.

Keep T09's real Monitor -> investigation -> Review approval -> repair -> recovery
story. T10/T11 remain hybrid evidence plus Arc Run Command recovery that you run, not
autonomous Arc repair or reliably demonstrated T11 RCA. Preserve scoped Sev2
routes, enabled three-hour cooldown (T12's plan turns it off on purpose, so a repeat
run opens a new thread), Review and the stable-identity lifecycle.
`High` is the action identity's permission profile, **not a billable service tier**;
changing it to `Low` is not a documented pricing discount and can prevent repair.

## The main lever is how long the parent exists

[SRE billing guidance](https://learn.microsoft.com/azure/sre-agent/pricing-billing)
specifies **4 Azure Agent Units (AAUs) per agent-hour** from creation until
deletion, plus variable active-flow AAUs for model processing.

| State | SRE always-on charge | Consequence |
| --- | --- | --- |
| Ready parent | 4 AAUs per hour, plus active work | Live investigation and governed repair are available. |
| Stopped parent | Still 4 AAUs per hour | Active work stops; this does not stop the baseline bill. |
| Verified repo Hibernated | No parent, so no SRE always-on or active-flow charge | Parent/configuration must be rebuilt before the next demo. Other services can still incur charges. |

Use the export, `Hibernate-SreAgent.ps1 -WhatIf`, actual parking and
verification sequence in `docs\sre-response-plan-automation.md`. Retain the
dedicated group/UAMI, existing free workload grants, workspace Application Insights
and owned Action Group. Standing access persists until explicitly reconciled or
Removed; retained telemetry/notifications can still incur usage charges. The
[managed identity has no extra charge](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
There is no reason to delete that identity merely to reduce the SRE baseline.
Wake Arc first, then reconstruct SRE and verify its configuration and readiness.
Never automatically park a running demo during a cost review.

Deletion is an intentional **demo** tradeoff, not a recommendation to delete a
customer's continuously operating SRE service. It loses threads, incident history,
memory and connector state; exports do not restore those. Rebuilding takes time,
needs the grants in place and can consume active-flow AAUs. The retained
identity avoids principal churn, not these other losses. Local tests do not prove
a complete live retained-identity park/wake cycle.

### One measured rehearsal

A full dress rehearsal from zero kept one parent for about 2 hours 28 minutes
(created at 11:27 am, deleted at 1:55 pm on 12 November 2026). At 4 AAUs an hour that
is about **10 baseline AAUs**, plus active work that can't be read back. About 8
minutes of that was the build, and the rest was the acts, the extras and waiting for
cards. Budget 3 hours and 12 baseline AAUs for the same run.

### Illustrative baseline, not a dollar quote

For one agent, an illustrative 730-hour month is **2,920 baseline AAUs**.
Four separately provisioned four-hour demo windows total **64 baseline AAUs**:
2,856 fewer, or approximately **97.8%** less baseline usage. This requires deleting
the parent between windows and includes setup time within those windows; it is
not a measured saving or a claim about billing granularity.

For an Australia East comparison in USD, multiply those baseline units by a
verified current regional/agreement always-on unit rate, then add active-flow
and Monitor costs. The [official pricing page](https://azure.microsoft.com/pricing/details/sre-agent/)
returned `$-` price placeholders during review: **that is an unavailable quote,
not zero**. No actual invoice, negotiated rate or token usage was established.
Do not assume evaluation eligibility or that recreating an agent grants a fresh
evaluation. Check current offer terms; these examples assume no waiver.

## T12: the Friday release

T12 adds one small workload and no second parent, so the SRE parent's cost doesn't
change: 4 AAUs per agent-hour from creation until deletion, plus active work.

- **The workload.** One Linux App Service plan (`B1` by default), one web app and
  a little workspace-based Application Insights telemetry, in their own group. The
  public [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
  listed "Azure App Service Basic Plan - Linux", SKU `B1`, in `australiasoutheast`
  at about AUD 0.03 per hour on 2026-11-10 (the Windows plan for the same SKU was
  listed at AUD 0.13, so keep the Linux one). It's a retail list price, not an
  invoice or an agreement rate: look up your region and currency before you quote
  it. The plan bills for as long as it exists, whether or not the parent does.
  Parking doesn't stop it; `Remove-TicketingWorkload.ps1` does.
- **A window.** The build takes 5 to 8 minutes, and a new role can take far
  longer to work, which is why the workload and its grant are deployed before the
  parent. A run then needs three to six minutes to the Review card and one to two
  more to recovery (measured on 2026-11-11), plus your presenting time. Every hour
  the parent exists is 4 baseline AAUs. The active-flow AAUs for one T12
  investigation can't be read back: Azure Resource Manager has no platform metrics
  for the agent resource (the metric-definitions call answers 400 "not a supported
  platform metric namespace"), so use hours at 4 AAUs as your estimate and check
  the bill.
- **What the GitHub sign-in costs.** Nothing in Azure, but the OAuth grant reaches
  every repository your GitHub account can reach, which is why the `ask` policy is
  applied before anything GitHub is connected.

## Acts 1, 3, 4 and 6: ask, remember, scheduled work and the server room

The `ASK`, `MEMORY`, `PROACTIVE` and `ARC` modules add no resource, no second parent
and no grant, so the SRE parent's cost doesn't change: 4 AAUs per agent-hour from
creation until deletion, plus active work.

- **Ask it anything.** No scheduled work. Each question is active work whose AAUs
  can't be read back. Questions about the Arc servers need that estate awake, which
  has its own cost in the Arc repository.
- **It remembers.** The seed is one call at apply time. The overview is loaded into
  every conversation, so it adds a little to each. The warm-up is a full incident,
  so budget its hours at 4 AAUs each.
- **Scheduled work.** The three tasks are paused, so they cost nothing until you run
  one or resume its schedule. Each run is one agent thread of active work; measured
  on 2026-11-11, the health check took 1 minute 45 seconds, the drift scan about
  1 minute 30 seconds and the deck 2 minutes 42 seconds. With all three schedules
  resumed, the agent would start 11 threads a week (five health checks, five drift
  scans and one deck). The tasks live on the parent, so parking deletes them and
  applying again recreates them paused.
- **No per-run figure.** The active-flow AAUs of a run can't be read back (the same
  limit as T12), so no run has a measured price. Use hours at 4 AAUs as your
  estimate, and don't quote a price per run.
- **The server room.** The act needs the Arc estate awake for at least 30 minutes
  before the beat, which has its own cost in the Arc repository, and the agent up
  for the whole fault: start it about 15 minutes before the beat (one run took 6
  minutes 51 seconds to the card), so budget that lead at 4 AAUs per hour. It creates
  one run command on the server and removes it on reset. The whole 2026-11-12 run,
  with the agent waiting 22 minutes for the click, kept the parent up for 1 hour 10
  minutes. See [Act 6](arc-server-room.md).

## Preserve evidence instead of guessing at telemetry savings

Application Insights uses the existing workspace, so do not add a second
workspace or double-count its shared ingestion. Its component's reported
`RetentionInDays` is not proof of every workspace table's effective retention.
[Application Insights tables include 90-day retention at no additional retention
charge](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure#log-tables-with-90-day-default-retention).
Cutting 90 to 30 days does not establish a retention saving for those tables.
Ingestion, retention beyond the included period and other table types can still
be billed. Historical shared-workspace data can remain after SRE parking.

Attribute measured billable ingestion by table/resource before proposing filters.
Do not silently sample out incident evidence or lower shared daily caps: a cap
can stop ingestion for the rest of the day and interrupt detection/investigation.
See [daily cap guidance](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap).
This repo does not own the shared workspace's plan, retention or collection rules.

## Changes that need a decision, not an automatic downgrade

- **Model/provider:** token-to-AAU rates differ, but fewer tokens/tool calls can
  offset a higher rate. `Automatic` is not proof of a particular resolved model.
  Compare real investigation quality and total task usage before changing it.
- **Monthly allocation:** the documented active-flow limit can disable chat and
  actions when reached. It does not cap always-on or Monitor charges. Do not
  lower it immediately before a rehearsal or present it as a total-cost cap.
- **Telemetry volume/retention:** first measure contribution and prove alert,
  query, RCA and recovery evidence survives any proposed reduction.
- **Scheduling:** choose explicit Ready/Hibernated windows yourself;
  don't add an unattended deletion schedule or silently stop a walkthrough.

The reviewed design already has one parent, narrow response routes, cooldown and
deletion-based parking with a retained costless identity. No evidence established
a safe SRE SKU, permission, model or retention downgrade. Consequently this review
does **not** change IaC defaults or deploy a speculative saving; it documents the
real operating lever and leaves material functionality reductions for a decision.
