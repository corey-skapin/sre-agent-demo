# SRE demo docs

These pages are for you, the person who cloned this repo, usually working through
an AI tool. This [index](README.md) lists them. Start with the root
[`README.md`](../README.md).

## Set up and run

1. [`README.md`](../README.md): what gets deployed, the prerequisites and the
   Deploy example.
2. [Response-plan automation](sre-response-plan-automation.md): the setup,
   readiness and lifecycle reference. Start at its
   [setup path at a glance](sre-response-plan-automation.md#setup-path-at-a-glance).
3. [Deploy handbook](ai-deploy-handbook.md): generating your presenter guide, the
   LOB and SQL scenarios, and the steps your AI tool follows to build, park and
   remove.

## Present

Open `.local/presenter-runsheet.md` in this repo and follow it from top to bottom.
It has your resource links and query scope filled in. The Arc repo has its own
section. [delivery-runsheet.md](delivery-runsheet.md) is the template it's
generated from. If the local guide is missing,
[generate it](ai-deploy-handbook.md#your-presenter-guide) from your saved context.

## Scenarios and references

| Page | Use it to |
| --- | --- |
| [T09 runbook](t09-native-containerapp-closed-loop.md) | Run one Container App incident and watch the agent propose a fix |
| [T11: LOB app on Arc](t11-lob-app-on-arc-bridge.md) | Deploy the LOB app on an Arc server, create its alert and break it |
| [T12: The Friday release](t12-friday-release.md) | Deploy a small web app, release a bad version, and watch the agent find it and propose the redeploy-previous fix |
| [Act 1: ask it anything](ask-anything.md) | Let your audience question the agent about the estate, from a question bank |
| [Act 3: it remembers](it-remembers.md) | Seed the agent's notes, run the warm-up, and keep the notes across a rebuild |
| [Act 4: it works when nothing is broken](proactive-checks.md) | Run the scheduled health check, the Bicep drift scan and the governance deck |
| [Cost and fidelity](sre-cost-and-demo-fidelity.md) | See what the SRE layer costs and how parking changes it |
| [Reskinning](reskin-guide.md) | Change the names, labels and region in your private skin |
| [Sales guidance](sre-sales-rollout-guidance.md) | Plan a workshop or PoC around the demo |
