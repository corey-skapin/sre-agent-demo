<!-- Adapted from microsoft/sre-agent labs/onboardinglab (agent-recipe/config/hooks/evidence-checklist.yaml) at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md. -->
---
name: release-closing-check
description: Check the evidence and the closing summary before an incident investigation completes.
eventType: Stop
activationMode: always
timeout: 30
maxRejections: 2
---
First determine whether the response presents incident investigation findings or claims that an incident was mitigated or recovered. If it does not, return {"ok": true, "reason": null} immediately. Greetings, general questions, clarifying questions, setup or deployment instructions, plans, future requirements, progress updates, and reports of missing prerequisites are not investigation findings.

For an applicable investigation response, verify that it states the UTC scope, the affected resources, timestamped evidence or explicit evidence gaps, confirmed facts versus hypotheses, confidence, and the next validation step. If it proposes an operational remediation, also require the exact target, a reversible plan, and a statement that the change waits for a person's approval. If it says a change was applied, require that it says a person approved it, and reject any prediction of when the alert will clear.

Return {"ok": true, "reason": null} when complete. Otherwise return {"ok": false, "reason": "Describe the specific missing evidence or qualification"}.
