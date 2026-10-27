# AI operating instructions - optional SRE layer

## Scope and reading order

- Attach SRE to the companion `arc-demo`; never deploy or edit its estate here.
- Present from `.local/presenter-runsheet.md`; use [the docs map](docs/README.md)
  for operator references and keep the Arc presentation in its own repo.
- Use companion Arc `docs/runsheet.md#present-the-arcmonitor-demo` for Arc UI detail.
- Use [the AI handbook](docs/ai-deploy-handbook.md) for activation and handoff.
- Use [response-plan automation](docs/sre-response-plan-automation.md) as the
  single protocol-pin, setup, failure and lifecycle reference.
- Consult T09 only for an authorized incident; do not run it as a second talk.
- Treat T10/T11 engineering ledgers as historical evidence, not presenter scripts.
- Keep old-instance proof separate from current resource/configuration/run proof.
- Ground portal directions in current Learn and observed controls; do not invent
  menu paths, approval buttons or unobserved deep links.

## Targets and safe changes

- Require explicit subscription, tenant, private skin and desired state.
- Keep Active (`Ready` alias), Hibernated and Removed distinct.
- Validate skin/schema/names; never infer a target from ambient Azure login.
- Keep customer/account context, live IDs, credentials and private paths out of git.
- Keep fictional defaults; supply source repository URL and commit together only
  when needed. A URL is not connector authentication.
- Run local tests and a bounded secret/identifier scan before every push.
- Preview authorized writes; keep `-WhatIf` read-only, including local side effects.
- Fail closed for deployment, activation and removal on unknown ownership,
  wrong target, identity mismatch, denial or ambiguous inspection.
- Warn about unrelated retained free-resource/IAM drift during normal Hibernate;
  do not strand the known paid parent or delete extra resources to hide drift.
- Reconcile excessive/inherited/duplicate IAM explicitly before Active.
- Do not switch global accounts, bypass denial or silently grant permissions.
- Preserve fault flags, workload resources, retained disks and the HDD guard.
- Do not change autonomy, model, telemetry, cooldown or connectors without scope.
- Keep Review everywhere; never switch plans to Autonomous for this demo.
- Do not treat High/Low access as pricing or a Stopped parent as cost-free.
- Use [the cost reference](docs/sre-cost-and-demo-fidelity.md) without inventing prices.

## Activation and configuration

- Activate/verify Arc first; use its owner's fresh readiness handoff.
- Render `Initialize-SreConfiguration.ps1` locally, then authorize `-Inspect`.
- Approve the full preview before `-Apply -BackupPath <NEW_EXTERNAL_FILE>`.
- Use complete `Deploy-SreAgent.ps1 -ConfigurationBackupPath` or explicitly
  `-ParentOnly`; never call parent-only deployment a configured Active demo.
- Follow the canonical protocol pin; do not invent endpoints or replay legacy
  MCP `severity: high`, invalid P1/P2 or response-level instruction payloads.
- Keep instructions/tools on the handling agent and exact Sev2 on AzMonitor plans.
- Keep enabled three-hour cooldown; check actual settings before a repeat.
- Stop on unsupported legacy settings or enabled unowned/quickstart routing;
  never migrate, disable, delete or rebuild automatically.
- Preserve current objects/history and external backups during ordinary updates.
- Read back ambiguous writes before retrying; stop on concurrent changes.
- Report failed/partial setup explicitly; never claim zero-touch or successful
  configuration through an unverified manual fallback.
- Run `Test-SreReadiness.ps1` with the same explicit target/skin.
- Require all required checks to pass; do not rewrite JSON or ignore failures.
- Treat optional `telemetry-and-alerts` as skipped/not evaluated, not loop proof.
- Record a separately authorized incident before claiming new closed-loop success.
- After successful setup, refresh the ignored local context and run
  `New-PresenterRunsheet.ps1` per the handbook; use saved nonsecret inputs only.
- Keep presenter IDs/URLs in `.local`, never tokens or tracked files; do not make
  cloud calls merely to render the guide or present saved health as current.

## Post-activation incident offer

- After successful requested combined activation/SRE reactivation, the SRE-owning
  assistant MUST ask once in conversation whether to trigger one T09 incident.
- Follow [the canonical consent procedure](docs/ai-deploy-handbook.md#post-activation-incident-offer).
- Require fresh Arc readiness, passing required SRE checks and a healthy endpoint.
- Own the single offer across both repos; do not ask on Arc-only, ParentOnly,
  incomplete activation or a read-only navigation rehearsal.
- On no/no affirmative answer, skip and leave the requested Active demo running.
- On yes, have the AI execute the existing T09 runbook; never make the user
  choose scripts or run commands.
- Agree the exact app, observation deadline and narrow operator reset fallback.
- Treat consent as one fault, not a retry, permission change or SRE tool approval.
- Guide the human to the current exact Review card; never auto-approve or treat
  narration/chat consent as an independently audited approval.
- Inspect ambiguous delivery instead of repeating a consumed fault authorization.
- Report actual alert, RCA, executor/tool completion and health evidence separately.
- Distinguish SRE repair from operator fallback; do not infer repair from prose.
- Read MonitorCondition separately from alert workflow state or thread closure.
- Verify false flag, healthy serving revision and HTTP 200; surface recovery errors.
- Never approve a stale card after fallback or promise a watchdog/hard cancellation.
- Present T09 as the primary Review closed loop; keep T10/T11 recovery operator-led.
- Do not claim autonomous Arc repair or reliable T11 RCA.

## Hibernation, removal and reactivation

- Obtain explicit hibernation authorization; never park a requested Active demo.
- Export needed config/evidence outside git and save the live UAMI principal first.
- Preview normal `Hibernate-SreAgent.ps1 -WhatIf`, then execute approved scope.
- Delete only the paid parent; retain dedicated group/UAMI, existing workload
  grants, workspace AppInsights and owned existing Action Group.
- Do not revoke standing grants, delete the UAMI/group or create missing
  diagnostics during normal Hibernate; report wake diagnostics and free drift.
- Verify `Test-SreReadiness.ps1 -DesiredState Hibernated` with saved principal;
  require parent absence and retained identity, not merely a submitted deletion.
- Finish SRE parking before the Arc owner parks the estate.
- Report failed/pending deletion honestly; observe boundedly, never blindly retry.
- Resume Arc first, then rebuild parent/handler/plans using retained identity and
  versioned assets; preserve deterministic workload grant IDs.
- Preserve the combined system/user identity shape; do not add external grants
  to the system principal that rotates with parent recreation.
- Treat exports as reference, not native history/memory/connector restoration.
- Reauthorize optional repository connections separately.
- Use separately authorized `Remove-SreAgent.ps1 -WhatIf` for full removal;
  refuse unknown resources/grants and remove the dedicated group only when empty.
- Preserve shared Arc/Monitor resources and private exports during Removed.
- Verify Removed with the saved principal; do not claim grant absence without it.
- Do not mistake mocked tests or an incident repair for a live lifecycle test.
