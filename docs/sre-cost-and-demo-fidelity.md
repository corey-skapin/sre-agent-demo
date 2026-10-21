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

Keep T09's real Monitor -> investigation -> human Review -> repair -> recovery
story. T10/T11 remain hybrid evidence plus operator Arc Run Command recovery, not
autonomous Arc repair or reliably demonstrated T11 RCA. Preserve scoped Sev2
routes, enabled three-hour cooldown, Review and the stable-identity lifecycle.
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

Use the approved export, `Hibernate-SreAgent.ps1 -WhatIf`, actual parking and
verification sequence in `docs\sre-response-plan-automation.md`. Retain the
dedicated group/UAMI, not its workload grants. The
[managed identity has no extra charge](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
There is no reason to delete that identity merely to reduce the SRE baseline.
Wake Arc first, then reconstruct SRE and verify its configuration and readiness.
Never automatically park a running demo during a cost review.

Deletion is an intentional **demo** tradeoff, not a recommendation to delete a
customer's continuously operating SRE service. It loses threads, incident history,
memory and connector state; exports do not restore those. Rebuilding takes time,
requires the approved grants and can consume active-flow AAUs. The retained
identity avoids principal churn, not these other losses. Local tests do not prove
a complete live retained-identity park/wake cycle.

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
- **Scheduling:** choose explicit Ready/Hibernated windows with the operator;
  don't add an unattended deletion schedule or silently stop a walkthrough.

The reviewed design already has one parent, narrow response routes, cooldown and
deletion-based parking with a retained costless identity. No evidence established
a safe SRE SKU, permission, model or retention downgrade. Consequently this review
does **not** change IaC defaults or deploy a speculative saving; it documents the
real operating lever and leaves material functionality reductions for a decision.
