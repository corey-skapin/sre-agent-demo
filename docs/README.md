# SRE demo docs

This [index](README.md) separates presentation, operations and engineering history.

**Presenting:** open the setup-generated `.local/presenter-runsheet.md` in this
repo. Follow it from top to bottom. It has the actual resource links and query
scope already filled in. The Arc repo owns the Arc section.

[delivery-runsheet.md](delivery-runsheet.md) is the source for that SRE guide.
If the local guide is missing, have the setup assistant
[generate it from the saved context](ai-deploy-handbook.md#local-presenter-guide).
The presenter does not need a private input card, skin or resource-ID lookup.

## Setup path

To build, verify, park, wake or remove the SRE layer, read these in order:

1. [`AGENTS.md`](../AGENTS.md) - standing scope and safety rules for assistants.
2. [`README.md`](../README.md) - what is deployed, prerequisites and the Deploy example.
3. [Response-plan automation](sre-response-plan-automation.md) - the single
   protocol-pin, setup, readiness and lifecycle reference. Start at its
   [setup path at a glance](sre-response-plan-automation.md#setup-path-at-a-glance).
4. [AI setup handbook](ai-deploy-handbook.md) - handoff prompt, local guide
   generation and the single optional incident offer.

## Other operator references

These are for a separately approved operation, outside the presenter path.

| Reference | Use |
| --- | --- |
| [T09 procedure](t09-native-containerapp-closed-loop.md) | One separately approved Container App incident, observation and recovery |
| [Cost and fidelity](sre-cost-and-demo-fidelity.md) | Cost-state and demonstration limits |
| [Deployment reskinning](reskin-guide.md) | Existing deployment machinery for maintainers; no presenter customization step |
| [Sales guidance](sre-sales-rollout-guidance.md) | Optional planning reference |

## Engineering and dated evidence

These files are retained for engineering context. None establishes current health
or requires another presentation. The setup path does not depend on them.

| Reference | Contents |
| --- | --- |
| [Response-plan appendix](sre-response-plan-automation.md#appendix-dated-rehearsal-evidence) | Dated SQL and LOB rehearsal notes, kept at the end of the setup reference |
| [T10 ledger](t10-sre-on-arc-experiment.md) | Arc experiments and historical configuration/T09 evidence |
| [T11 bridge](t11-lob-app-on-arc-bridge.md) | LOB sample, guest operations and historical evidence |
| [T11 architecture](t11-hybrid-diagnostics-wow.md) | Hybrid story and operator recovery detail |
| [Clean-room review](clean-room-shareability-test-2026-10-12.md) | Dated clone/parser/WhatIf review |
