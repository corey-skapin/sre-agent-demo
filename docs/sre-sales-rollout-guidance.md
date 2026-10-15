# Azure SRE Agent sales and rollout guidance

Internal field guidance assembled from the VIC1 pipeline-review chat, the Azure
SRE Agent one-pager, the PoC datasheet, the SRE Agent spend workbook, Microsoft
Learn SRE Agent docs, and the current Arc + Monitor + SRE demo validation.

Use this as account-team guidance, not as a customer-facing datasheet.

## Positioning

Use this line:

> Azure Monitor tells the operations team that something changed. Azure SRE Agent
> investigates why, explains the evidence, and proposes the next action inside a
> governed run mode.

Position SRE Agent above static monitoring and runbooks:

- It handles incidents, scheduled operational checks, and natural-language
  investigations.
- It connects telemetry, recent changes, resource context, code and runbooks.
- It supports a trust path: Reader or observe-only first, Review mode for
  approved actions, then Autonomous only where the customer has earned that
  confidence.
- It should be sold as operational knowledge capture and investigation
  acceleration, not as unrestricted AI remediation.

## Qualification signals

Good SRE Agent candidates have most of these:

- A platform, SRE, operations or DevOps team responsible for incident response.
- Azure Monitor, Log Analytics or Application Insights already collecting useful
  telemetry.
- At least one Azure Monitor alert that represents a real operational pain.
- A non-production workload suitable for a PoC.
- Access to a source repository or runbook corpus that helps explain incidents.
- An operations leader who wants reduced MTTR, less manual triage and less
  dependence on tribal knowledge.

Weak fit:

- No observable workload.
- No incident or on-call process.
- No customer team available for a hands-on workshop.
- A desire to jump directly to production Autonomous mode.

## Two-day PoC shape

The internal PoC datasheet frames a two-day engagement.

### Day 1: deploy and investigate

1. Confirm success criteria and prerequisites.
2. Explain architecture, identity, RBAC, pricing, trust model and run modes.
3. Deploy the parent SRE Agent.
4. Connect Azure resources, Log Analytics or Application Insights, code and
   knowledge sources.
5. Run an interactive investigation so the customer sees how the agent reasons
   over their context.

### Day 2: incident response and extension

1. Connect Azure Monitor as the incident source.
2. Create a Review-mode incident response plan.
3. Trigger or replay a safe test alert.
4. Review the agent investigation and approve the proposed mitigation.
5. Add one extension point: runbook, skill, custom tool, connector, scheduled task
   or subagent.
6. Close with governance, usage and a roadmap from reactive operations toward
   more trusted automation.

## PoC prerequisites

Before scheduling, confirm:

- Azure subscription in a supported region.
- Owner, or Contributor plus User Access Administrator, for the SRE Agent scope.
- PIM activated in advance where required.
- Non-production workload with telemetry.
- Azure Monitor alert rule.
- Access to code or runbooks if code-aware RCA is in scope.
- Browser access to `.azuresre.ai`.
- Customer team available: SRE/platform lead, 2-6 engineers, subscription owner,
  optional app owner and cloud architect.

Keep out of scope unless explicitly agreed:

- Production Autonomous mode.
- PagerDuty or ServiceNow integration.
- Custom MCP server development.
- Landing-zone remediation.
- Broad workload remediation.

## Success criteria

A strong PoC closeout proves:

1. SRE Agent deployed and scoped to at least one workload.
2. Azure Monitor alert investigated end to end.
3. Proposed mitigation reviewed by a human before execution.
4. At least one extension point configured.
5. Governance model documented: roles, run mode, tool access, audit and next
   expansion scope.

## Account planning and rollout signals

The SRE Agent spend workbook is a usage signal, not a pipeline system.

Current workbook shape:

- 302 customer rows.
- 31 customers with SRE Agent usage.
- Around 10 percent adoption in that workbook.
- Approximately $49.8K FYTD SRE Agent ACR.
- The top five consumers account for about 55 percent of identified FYTD SRE
  Agent ACR; top ten account for about 76 percent.

Use it to segment accounts:

| Segment | What to do |
|---|---|
| Sustained usage | Validate business value, production use cases and expansion paths. |
| Emerging usage | Confirm whether it is pilot, early production or stalled evaluation. |
| Declining usage | Investigate onboarding, architecture, value realisation or workload changes. |
| No usage | Qualify with Azure footprint, operational complexity, modernisation motions and account-team context before creating pipeline. |

Do not treat ACR alone as opportunity value, customer intent or pipeline stage.

## VIC1 chat signals

The VIC1 discussion reinforced three field motions:

- A 1:many webinar or roadshow around the power and use of SRE Agent.
- A Modern Ops implementation roadshow with interested field participation.
- A CSU/CSA-style workshop paper that gives a practical PoC structure and
  prerequisites.

For Corey’s Arc + Monitor + SRE demo, the right path is:

1. Use the Arc + Monitor demo to earn the operations-plane conversation.
2. Use Defender for Cloud recommendations as the security co-sell.
3. Use T09 as the live closed-loop SRE proof.
4. Use T11 as the hybrid evidence and operator recovery proof.
5. Close on a two-day PoC or workshop, not on broad autonomous remediation.

## How to attach this to the demo

During Act 1, establish the customer already has:

- a hybrid estate,
- security posture questions,
- operational alerts,
- data in Azure Monitor.

During Act 2, show SRE Agent on the Azure-native Container App path first. This
is the reliable closed-loop proof.

Then position hybrid Arc scenarios as the next trust-building step:

- Arc and Monitor bring on-prem-shaped signals into Azure.
- SRE Agent can create incident threads and propose actions.
- Operators approve or perform Arc Run Command remediation.
- Autonomous Arc repair is future hardening, not the current demo claim.

## Seller-safe talk tracks

Use:

- “Start in Review mode so engineers approve proposed actions.”
- “The first win is investigation quality, not autonomous repair.”
- “The PoC should use a real non-production workload and a real alert.”
- “Consumption tells us where adoption exists, but it does not replace account
  planning.”

Avoid:

- “The agent will fix your datacenter servers automatically.”
- “SRE Agent replaces your SRE team.”
- “A two-day PoC includes workload remediation.”
- “Existing SRE spend means there is already a qualified opportunity.”

