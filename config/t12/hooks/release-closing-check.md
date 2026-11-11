<!-- Adapted from microsoft/sre-agent labs/onboardinglab (agent-recipe/config/hooks/evidence-checklist.yaml) at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md. -->
---
name: release-closing-check
description: Check the evidence and the closing summary before an incident investigation completes.
eventType: Stop
activationMode: always
timeout: 30
maxRejections: 2
---
First determine whether this response is the incident investigation summary: it presents findings about the alert's cause or impact, or reports that the incident was mitigated, rolled back or recovered. If it is not, return {"ok": true, "reason": null} immediately, even when it mentions the incident or an earlier change. Greetings, questions, plans, progress notes, GitHub issue drafts, and reports of missing prerequisites are not investigation summaries.

For an investigation summary, check only these: the UTC scope, the affected resources, timestamped evidence or explicit evidence gaps, confirmed facts kept apart from hypotheses, a confidence level, and the next validation step. If it proposes an operational remediation, also require the exact target, a reversible plan, and a statement that the change waits for a person's approval. If it says a change was applied, require only that it says a person approved it: do not ask for the approver's name or the approval time. Reject any prediction or implication that the alert will clear, or when; stating the alert's current state, or that it was not checked, is fine.

Return {"ok": true, "reason": null} when complete. Otherwise return {"ok": false, "reason": "Describe the specific missing evidence or qualification"}.
