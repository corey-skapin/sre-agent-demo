# Documentation map: what to read and what to present

**Presenting for the first time? Read this page, then
[the combined presenter guide](delivery-runsheet.md).** You do not need to read
every implementation or historical evidence document to present this demo.

This repo is the optional SRE layer. The companion `arc-demo` repo can be
presented by itself; it owns the fleet, workbook, shared monitoring and Arc UI
instructions. Both repos must refer to the same privately supplied runtime estate.

## Minimum presenter path

1. **Choose the scope.** For Arc + Monitor only, use the companion repo's
   `docs\README.md` and `docs\runsheet.md`; no SRE setup is required.
   For the combined 30-minute story, stay in
   [delivery-runsheet.md](delivery-runsheet.md).
2. **Prepare once.** Complete that guide's private input card, access checks,
   read-only preflight and browser bookmarks. Rehearse its numbered navigation
   and fallbacks once, without sending agent messages, inducing faults or
   approving actions.
3. **Present from that same guide.** Its Arc segment uses the companion
   `docs\runsheet.md#present-the-arcmonitor-demo` for detailed UI reference, then
   resumes here. Do not run two full timed presentations back-to-back.
4. **Choose evidence-only or separately rehearsed live T09 in advance.**
   A navigation rehearsal is not an end-to-end fault/repair test. A newly
   reconstructed SRE instance must not inherit the old instance's success claim.
   If current live proof or a real approval card is absent, use the guide's
   explicit configuration/historical-evidence fallback.

An already provisioned lab is a prerequisite. If it is not ready, hand setup to
the operator path below rather than deploying, changing permissions, connecting
repositories or injecting faults in front of the audience.

## Every document and its role

**Canonical** means the presentation source of truth. **Reference** is consulted
for a specific operator task, not read in order during the talk. **Historical**
records an earlier run; it never certifies today's resources or UI.

| Document | Audience and purpose | Status / when needed |
| --- | --- | --- |
| [README.md](README.md) | Everyone: this complete map and reading order. | Start here. |
| [delivery-runsheet.md](delivery-runsheet.md) | First-time presenter: private inputs, one rehearsal, timed combined story, exact navigation, expected results, talk track, approval boundary and fallback. | **Canonical combined presentation. Required for the combined demo.** |
| [t09-native-containerapp-closed-loop.md](t09-native-containerapp-closed-loop.md) | Recovery operator: Container App fault/reset commands, verification, audit queries and prior-run evidence. | **Operator reference**, only for a separately authorized bounded T09 rehearsal/live window. Historical proof is from a previous instance. Not a second presenter script. |
| [t11-hybrid-diagnostics-wow.md](t11-hybrid-diagnostics-wow.md) | Presenter/architect: optional hybrid business story and operator-recovery explanation. Includes separately authorized guest/fault commands for operators. | **Optional reference.** The canonical guide already includes the short read-only scene; skip its live commands during an ordinary presentation. |
| [sre-response-plan-automation.md](sre-response-plan-automation.md) | Deployment operator: canonical protocol coupling/re-pin/fallback, fresh/reused bootstrap, readiness, export and retained-identity park/wake. | **Current operations reference.** Legacy-instance migration is unsupported; not a presenter script. |
| [ai-deploy-handbook.md](ai-deploy-handbook.md) | Operator using an AI assistant: bounded setup/handoff prompts, commands and permission/lifecycle rules. | **Setup reference.** Not a presenter checklist or authorization to execute writes. |
| [reskin-guide.md](reskin-guide.md) | Demo owner: fictional defaults, private runtime skins, labels, source-context options and retargeting. | **Preparation reference.** Read before creating a different estate or audience skin, not during the talk. |
| [sre-cost-and-demo-fidelity.md](sre-cost-and-demo-fidelity.md) | Owner/architect: AAU billing, Stopped versus deletion-based parking, retained identity, telemetry and quality tradeoffs. | **Optional cost/closeout reference.** Not an actual bill, unit-price quote or permission to park a running demo. |
| [sre-sales-rollout-guidance.md](sre-sales-rollout-guidance.md) | Seller/workshop lead: positioning, qualification, illustrative PoC scope and safe claims. | **Optional planning reference.** Not the portal presentation or deployment recipe. |
| [t11-lob-app-on-arc-bridge.md](t11-lob-app-on-arc-bridge.md) | Engineer: LOB sample architecture, guest deployment, event/alert plumbing and historical T11 evidence. | **Engineering reference / historical ledger.** Do not execute its guest operations to fill an empty presentation view. |
| [t10-sre-on-arc-experiment.md](t10-sre-on-arc-experiment.md) | Engineer: Arc experiments and historical SRE configuration/T09 evidence moved out of assistant instructions. | **Experimental appendix / historical evidence.** Not presenter source-of-truth or current-instance proof. |
| [clean-room-shareability-test-2026-10-12.md](clean-room-shareability-test-2026-10-12.md) | Maintainer: dated no-cost clone/parser/WhatIf findings and remaining validation gaps. | **Historical only.** Predates current routing and identity retention; never use its old MCP/browser experiments as a rebuild recipe. |

## Operator path, only when preparation is required

Read [reskinning](reskin-guide.md), then the
[AI/operator handbook](ai-deploy-handbook.md), then
[current response-plan/lifecycle automation](sre-response-plan-automation.md).
Use explicit private target inputs and the repo's supported read-only inspection.
Approve actual changes separately. Wake and verify Arc before SRE; park and
verify SRE before Arc. Parent deployment alone is not a complete configured demo.

Keep Review and enabled three-hour cooldown. SRE readiness passes when required
checks pass; its optional telemetry item is skipped/not evaluated, not run proof. Deleted
history, memory and repository authorization are not restored from exports.
See the canonical guide for what can honestly be shown without a fresh live run.

## Portal grounding and maintenance

The combined guide links current Microsoft Learn sources, distinguishes
documentation screenshots from observed lab UI, and states its observation
limits. Official SRE pages currently describe different navigation layouts;
do not turn an old menu label into an unconditional instruction. Rehearsal records
the visible layout and actual bookmarks, with read-only command fallback.

Keep this index complete when adding or retiring a document. Update the existing
canonical guide instead of adding another competing runsheet. Keep actual
tenant/subscription/customer/account information, deep links, screenshots and
results in a private operator appendix, not in tracked files.
