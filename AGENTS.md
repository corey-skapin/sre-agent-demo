# AGENTS.md - AI Agent Operating Manual for `sre-agent`

> Read this file first when using GitHub Copilot CLI, Scout, Claude Code, Cursor,
> Windsurf, Aider, OpenAI Codex, or another AI coding assistant.

This repo is the optional Azure SRE Agent layer for the standalone
`arc-demo` companion repo supplied with this handoff. It does not deploy
the Arc estate. It attaches SRE Agent to an existing `arc-demo` deployment and
adds the T09/T10/T11 SRE scenarios.

## Current validated stance

- **T09 Container App** is the only validated closed-loop SRE path:
  Azure Monitor alert -> SRE RCA -> Review approval -> SRE-executed repair ->
  recovery verification.
- **T10/T11 Arc paths** are validated for signal/evidence plus governed operator
  Arc Run Command recovery. Do not claim autonomous Arc server repair.
- **T11 LOB-on-Arc** is validated for Event ID `4100`, Log Analytics, Azure
  Monitor alerting, SRE incident creation, and operator recovery. The latest live
  run showed SRE RCA generation can stall, so do not present T11 as reliable SRE
  RCA yet.

The separately authorized fresh current-schema retry on 2026-10-20 verified
automatic T09 handoff/RCA, the exact reset tool completion and the SRE managed
identity as actual repair caller. The app recovered with no operator fallback;
the temporary cooldown change was restored to its original three-hour setting.
Actual MonitorCondition subsequently resolved; its alert workflow state remained
Acknowledged. Do not confuse those separate fields.
The earlier run used operator fallback and remains a separate outcome.
The user reported clicking the exact new Review card; no independent
`ApprovalDecision` telemetry event was captured in the bounded audit query.
Inspect actual approval/executor evidence, not the agent's "approved" narration,
and read MonitorCondition separately from a closed alert's workflow state.
Do not repeat an already-consumed one-shot fault authorization or approve a stale
repair after operator recovery.

## Start here

For a first-time presenter, use this minimal path:

1. `docs\README.md` - complete document map, audience/status and reading order.
2. `docs\delivery-runsheet.md` - single combined guide, private input card,
   read-only rehearsal, numbered portal actions, expected results and fallback.
3. Companion Arc `docs\runsheet.md#present-the-arcmonitor-demo` - detailed UI
   reference for the combined guide's short Arc segment, not a second full talk.

T09 is an operator fault/recovery reference, not a second presentation.
T11 wow is an optional talk-track reference; response-plan automation is for setup
or repair. Do not execute their writes during a navigation-only rehearsal.
The reconstructed instance's configuration was verified, not a new end-to-end
fault/approval/repair cycle. Preserve that caveat until actual new proof exists.
Ground portal instructions in current Learn and actual visible controls; published
SRE pages show different layouts. Mark unobserved UI and use verified private
bookmarks/read-only Inspect instead of inventing a click path or approval button.

Treat these as engineering references, not presenter source-of-truth:

- `docs\t11-lob-app-on-arc-bridge.md`
- `docs\t10-sre-on-arc-experiment.md`
- `docs\clean-room-shareability-test-2026-10-12.md`

## Happy-path setup

Assumes `arc-demo` already exists and is active.
The tracked skins use fictional organizations and no external source repository.
Keep real customer/context values in an untracked private skin outside the repo;
pass it explicitly. Supply your own repository URL and commit together only if
source context is needed. Never infer another operator's target from defaults.
Do not commit personal/customer context, contact details, live cloud IDs or
operator-owned source URLs. Preserve reviewed public service constants and
synthetic fixtures. Run the tracked handoff checks before publishing changes;
they do not replace contextual review or a bounded secret scan.

```powershell
cd C:\src\sre-agent
az login --tenant <TENANT_ID>

$targetArcId = az connectedmachine show `
  --subscription <SUBSCRIPTION_ID> `
  --resource-group rg-arc-demo `
  --name win-app-01 `
  --query id `
  --output tsv

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -ParentOnly `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($targetArcId)
```

Parent-only is not Ready. Render and `-Inspect`
`scripts\Initialize-SreConfiguration.ps1`, then apply only the approved preview
with a new external `-BackupPath` using
`docs\sre-response-plan-automation.md`. Run `scripts\Test-SreReadiness.ps1`
with the same explicit subscription/tenant/skin and resolve its failed/pending
gates before delivery. The Ready command always leaves its external
`telemetry-and-alerts` gate pending: it does not ingest saved rehearsal evidence.
Pair that report with a separately authorized recorded run; do not rewrite it to
exit 0. Failed service authentication/read-back is an explicit blocker.

## Post-activation incident offer

After successfully completing a user-requested AI-led combined activation or
SRE reactivation on an already healthy Arc estate, the SRE-owning assistant
**MUST ask the user once in conversation whether to trigger one representative
T09 Container App incident**. Do not make the user remember or select/run scripts.
Follow [the canonical offer and consent procedure](docs/ai-deploy-handbook.md#post-activation-incident-offer).
Offer only after fresh Arc readiness and all required SRE infrastructure,
configuration and workload checks pass; only the named `telemetry-and-alerts`
rehearsal gate may remain pending, unchanged in the original report.

The SRE assistant owns this offer after the Arc readiness handoff; do not ask
twice across the two repos. No offer during Arc-only activation, parent-only
deployment, failed/incomplete activation or a read-only navigation rehearsal.
Decline or no affirmative answer means skip and leave the activated demo running.
Consent covers one existing T09 run plus its agreed narrow operator reset
fallback, not approval of the SRE Agent's actual Review operation. The AI runs
the existing runbook and guides the human to that real approval card.

## SRE data-plane setup reality

The parent `Microsoft.App/agents` resource deploys repeatably through Bicep.
Microsoft's documented IaC templates now provide supported full service
read/upsert contracts. `scripts\lib\SreConfiguration.psm1` pins the public source
revision; the automation doc links the exact sources and routes.

Use `Initialize-SreConfiguration.ps1 -Inspect` to inspect full handlers, filters
and legacy response handlers, then approved `-Apply -BackupPath <NEW_EXTERNAL_FILE>`.
The initializer is local-only unless `-Inspect` or `-Apply` is supplied.
Complete parent-plus-configuration deploy can use `-ConfigurationBackupPath`.

Do not recreate plans through the legacy MCP `severity: high` interface: it
produced invalid AzMonitor P1/P2 plus legacy response-level instructions.
Current schema uses `priorities: ["Sev2"]`, single-keyword titles, explicit
Review, and instructions/tools on the handling custom agent. Migrating old
response fields requires scoped approval plus `-AllowLegacyMigration`.
Retain parent, identity, custom agent and old history. Default v3 routing replaces
explicitly listed v2 routes through disabled staging -> old-route disable ->
new-route enable, without legacy-handler updates. Existing legacy-handler PUT
collides in the live service; no public POST contract was established, so block
that path rather than guessing. Do not delete the agent to repair plans.
Full exports stay outside git.
After ambiguous writes read back before retrying. No duplicate plan creation.
Report enabled extra/quickstart conflicts; do not remove them automatically.

## Do not do these

- Do not change response plans to Autonomous for customer demos.
- Do not claim T11 autonomous Arc repair or reliable SRE RCA.
- Keep desired Active (Ready compatibility alias), Hibernated or Removed explicit; never hibernate a requested
  running demo automatically. Hibernation is destructive and needs authorization.
- Do not treat High/Low permissions as a pricing tier, or a Stopped parent as
  cost-free. SRE always-on billing continues until parent deletion. Follow
  `docs\sre-cost-and-demo-fidelity.md`; do not silently cut telemetry, change
  model or reduce an active-flow allocation to manufacture savings.
- Do not modify `C:\src\arc-demo` from this repo; layer on top only.

## Hibernation

Use the complete export, preview, verification and reactivation sequence in
`docs\sre-response-plan-automation.md`. Record the live identity principal and
export needed configuration/evidence outside git before deletion. The export is
a reference, not an automatic history/memory restore or a payload to replay.

```powershell
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -WhatIf
```

Remove `-WhatIf` only for the approved scope. Normal parking retains the dedicated
SRE group and `<AGENT_NAME>-uami`, existing UAMI workload grants, workspace
Application Insights and owned Smart Detection Action Group; deletes only the
paid parent. Parent-scope deployer admin is not a UAMI workload grant.
Report unexpected free resources/grants without deleting them or blocking
known-parent parking; inspection denial, wrong target or identity mismatch stops.
Reconcile excessive IAM before Active. Never delete the group/UAMI as a normal
hibernation shortcut. Standing permissions persist while parked.
Deletion observation is bounded; failed or pending cleanup is not Hibernated.
Finish and verify SRE hibernation **before** the Arc owner parks the estate.

Save the SRE identity principal ID and evidence before deletion. Verify
`Test-SreReadiness.ps1 -DesiredState Hibernated -PreviousIdentityPrincipalId <ID>`.
Reactivation rebuilds parent, handler and plans; deleted thread/history/memory and
repository connector authorization are not restored from this repo. No destructive
full-lifecycle test is implied by local mocked tests or the successful T09 retry.
Resume Arc first and require fresh Arc Ready; redeploy the SRE parent using the
retained UAMI, then modern custom agent/v3 filters from versioned assets with
enabled three-hour cooldown. Do not recreate retired legacy routing/history.
First deployment (or recovery from historical whole-group deletion) creates one
new UAMI through the same IaC; later normal cycles preserve its principal and
deterministic workload assignment IDs. The validated combined system/user identity
shape is unchanged: the system-assigned principal still rotates with the parent.
No new external permission is granted to that system principal. Full identity/group
removal uses explicitly authorized `Remove-SreAgent.ps1 -WhatIf`, followed by
approved execution and `Test-SreReadiness.ps1 -DesiredState Removed` with the saved
principal. Removed refuses unknown resources/grants, deletes only known owned
resources/assignments, then removes the empty dedicated group. It never deletes
shared Arc/Monitor resources or private exports. Missing principal after identity
deletion means external-grant verification is pending, not successful.
Old UAMI-only parked state remains supported; wake creates missing diagnostics
and adopts retained grants, with no unnecessary Graph display-name lookup.
