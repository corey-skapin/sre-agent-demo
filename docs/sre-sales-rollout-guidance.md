# Azure SRE Agent sales and rollout guidance

Reusable workshop-planning guidance for the Arc + Monitor + SRE demo, grounded
in Microsoft Learn and the validation boundaries in this repo. It contains no
account, territory, internal-chat, pipeline or consumption dataset.
Confirm current product prerequisites, capabilities and commercial terms before
using this in a proposal. This is not a customer-specific eligibility assessment,
pricing offer or a zero-cost hibernation claim.
This is optional workshop planning, not a portal runsheet; to present, start with
[the docs map](README.md), then open the generated `.local/presenter-runsheet.md`.

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

A suggested two-day engagement is below. Agree deliverables, access and timing
with the participants; this is an illustrative workshop shape, not a commitment.

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
3. Proposed mitigation reviewed by a person before execution.
4. At least one extension point configured.
5. Governance model documented: roles, run mode, tool access, audit and next
   expansion scope.

## Account planning and rollout signals

If you have account evidence available, use it privately to
qualify the conversation. Do not copy account metrics or source workbooks into
this reusable repo. The following qualitative segments are illustrative only:

| Segment | What to do |
|---|---|
| Sustained usage | Validate business value, production use cases and expansion paths. |
| Emerging usage | Confirm whether it is pilot, early production or stalled evaluation. |
| Declining usage | Investigate onboarding, architecture, value realisation or workload changes. |
| No usage | Qualify with Azure footprint, operational complexity, modernisation motions and account-team context before creating pipeline. |

Do not treat ACR alone as opportunity value, customer intent or pipeline stage.

## Workshop options

Possible reusable formats:

- A 1:many webinar or roadshow around the power and use of SRE Agent.
- A Modern Ops implementation roadshow with interested field participation.
- A technical workshop guide that gives a practical PoC structure and
  prerequisites.

For the Arc + Monitor + SRE demo, the suggested path is:

1. Use the Arc + Monitor demo to earn the operations-plane conversation.
2. Use Defender for Cloud recommendations as the security co-sell.
3. Use T09 as live closed-loop SRE proof only after you have run a
   current-instance rehearsal; otherwise label historical evidence or show the
   configured healthy workload without claiming a new completed loop.
4. Use T11 as the hybrid evidence and Arc Run Command recovery proof.
5. Close on a two-day PoC or workshop, not on broad autonomous remediation.

## How to attach this to the demo

During Act 1, establish the customer already has:

- a hybrid estate,
- security posture questions,
- operational alerts,
- data in Azure Monitor.

In the SRE section, show the Azure-native Container App path first. This
is the validated closed-loop capability, not an unconditional claim that a newly
reconstructed instance has completed it. Follow the canonical guide's live gates
and evidence-only fallback.

Then position hybrid Arc scenarios as the next trust-building step:

- Arc and Monitor bring on-prem-shaped signals into Azure.
- SRE Agent can create incident threads and propose actions.
- The customer's engineers approve or perform Arc Run Command remediation.
- Autonomous Arc repair is future hardening, not the current demo claim.

## Seller-safe talk tracks

Use:

- “Start in Review mode so engineers approve proposed Azure infrastructure actions.”
- “The first win is investigation quality, not autonomous repair.”
- “The PoC should use a real non-production workload and a real alert.”
- “Consumption tells us where adoption exists, but it does not replace account
  planning.”

Avoid:

- “The agent will fix your datacenter servers automatically.”
- “SRE Agent replaces your SRE team.”
- “A two-day PoC includes workload remediation.”
- “Existing SRE spend means there is already a qualified opportunity.”
