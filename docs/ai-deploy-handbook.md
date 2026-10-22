# AI deploy handbook - optional SRE layer

Use this only after standalone `arc-demo` is active. The Arc repo owns its estate;
this repo adds SRE without editing the Arc checkout or redeploying its workloads.
This is an operator/AI setup reference, not the presenter script. Start at
[the docs map](README.md) for audience, reading order and presentation guidance.

## Handoff prompt

```text
Read AGENTS.md, README.md, docs/README.md, docs/delivery-runsheet.md and
docs/sre-response-plan-automation.md.

Inputs: explicit subscription GUID, tenant GUID, skin, and desired state
Active (Ready compatibility alias), Hibernated or Removed. Never infer target context from an ambient Azure login.
Keep runtime identifiers and credentials out of git.

For Ready:
1. Confirm the Arc estate is active using Arc readiness and actual inventory.
2. Validate skin; run local mocked tests and Bicep compilation.
3. Preview Deploy-SreAgent.ps1 -WhatIf. Review the exact diff before changes.
4. Deploy with -ParentOnly only when parent changes are authorized. This is
   deliberately not a claim that the full demo is Ready.
5. Render Initialize-SreConfiguration.ps1, then -Inspect via pinned official
   template protocols. Review the full preview before -Apply with a new external
   -BackupPath. Existing legacy settings/P1-P2 need explicit migration approval
   and -AllowLegacyMigration; do not replay the legacy MCP high-severity recipe.
   No parent deletion is required. Never invent endpoints or duplicate plans.
6. Run Test-SreReadiness.ps1: handler, plan, Sev2 filters, legacy fields, Review
   and overlap now have full read-back. Its telemetry gate always remains pending
   because the command does not ingest external run evidence. Pair the report
   with a separately authorized rehearsal; never rewrite JSON/exit2 as exit0.
   Existing ARM success is not routing
   readiness. Do not induce a fault merely to answer a read-only readiness check.
7. T09 is the primary Review closed-loop capability; a new instance still needs
   its own authorized functional rehearsal before a live success claim.
   Present T10/T11 as hybrid evidence plus governed operator Arc Run Command
   recovery. T11 RCA is not reliable yet. Use the canonical guide's evidence-only
   fallback rather than treating old-instance proof as a new-instance pass.
8. Leave a requested Ready demo running. Do not automatically hibernate.
9. After successful combined activation/SRE reactivation, follow the
   Post-activation incident offer below: the SRE assistant must ask once in
   conversation whether to trigger one T09 incident. Do not leave the user to
   remember or run scripts. No fault without an affirmative scoped answer.

For Hibernated:
1. Obtain explicit authorization for deletion and export current Inspect output
   plus required incident/audit evidence outside git. This is not a history restore.
2. Save the SRE user-assigned identity principal ID.
3. Preview Hibernate-SreAgent.ps1 -WhatIf, then execute only after approval.
4. Normal parking deletes only the paid parent; retains SRE group/UAMI, existing
   workload grants, workspace AppInsights and owned Action Group.
   Verify retained principal and parent absence with Test-SreReadiness.ps1
   -DesiredState Hibernated -PreviousIdentityPrincipalId <saved ID>.
   Missing legacy diagnostics or stale free grants are optional wake diagnostics,
   not a reason to leave the paid parent running. Denied inspection still fails.
5. Finish SRE verification before Arc hibernation. Arc lifecycle is separately
   owned; do not stop its workloads from this repo. Wake/verify Arc before SRE.

For Removed:
1. Obtain separate full-removal authorization; preserve exports and principal.
2. Preview Remove-SreAgent.ps1 -WhatIf with the same explicit target/skin.
3. Unknown resources/roles/scopes require ownership reconciliation, not bypass.
4. Execute approved preview; known grants/resources are removed before deleting
   the empty dedicated group. Shared Arc/Monitor and private exports are untouched.
5. Verify -DesiredState Removed with the saved principal. Without that principal,
   external-grant absence is pending even when the group is gone.

Never change plans to Autonomous, remove quickstart plans, revoke extra grants,
connect a repository, or induce faults without the appropriate scoped approval.
```

## Post-activation incident offer

This is an **AI conversation step**, not a script prompt or a new orchestrator.
After a user-requested combined activation, or SRE reactivation on an already
healthy Arc estate, the SRE-owning assistant must offer one representative T09
Container App incident. It owns the offer **once**, after the Arc assistant's
successful readiness handoff and completion of SRE configuration. Do not also
ask from the Arc-only path, after `-ParentOnly`, during read-only rehearsal or
while activation is incomplete.

First verify fresh Arc readiness, all required SRE infrastructure/configuration/
workload checks and the healthy T09 endpoint. The named `telemetry-and-alerts`
gate alone may remain pending: it is the external rehearsal this offer can help
perform. Keep the original readiness report/exit status unchanged; any other
required failed/pending check blocks the offer.

Use the confirmed private target and an agreed observation deadline in the
conversation. For example: **"Activation is complete. Would you like me to
trigger one T09 Container App incident now? It temporarily faults the demo app,
can send configured alert notifications and incurs SRE usage costs. I'll run
the existing demo procedure, monitor until our agreed deadline, use the narrow
operator reset if needed, and guide you to the real human Review approval."**

- **No:** skip incident preparation, report activation separately and leave the
  requested Active demo running. Do not ask again in the same activation.
- **Yes:** confirm the exact app and recovery window, including the narrow
  `SIMULATE_CRASH=false` fallback, then have the AI execute
  [the existing T09 runbook](t09-native-containerapp-closed-loop.md#5-induce-the-fault)
  through observation, human Review and recovery verification. The user does
  not need to choose or run scripts. This authorizes one fault, not a retry,
  permission change, autonomy/cooldown change or approval of the SRE repair.
- **No answer or unattended execution:** do not block on a shell prompt or fault
  silently. Report preparation skipped; tell the user they can ask Copilot to
  run the optional T09 incident when they are present.

Keep Review and enabled three-hour cooldown. Inspect the actual alert and
investigation in the supported UI; cooldown may reuse an existing thread.
Guide the signed-in human to approve only the current run's exact reset card.
Never auto-approve or treat chat consent/narration as that approval. Before
faulting, check the healthy baseline and previous run's recovery; after an
ambiguous write inspect state rather than blindly repeating the fault.

Follow the runbook's existing recovery-owner/deadline and operator fallback
procedure if approval or SRE repair is unavailable. The helper has no automatic
watchdog or hard cancellation guarantee; do not promise otherwise. Surface
reset/health failures immediately and never approve a stale card after fallback.
Record actual alert, investigation and finding evidence where observed; report
missing or uncertain evidence as pending, not as a successful loop. Verify the
false flag, serving revision and HTTP 200, and report actual Monitor condition
resolution or explicitly pending resolution separately from alert workflow state.
Distinguish SRE repair with executor evidence from AI/operator reset fallback.
Preparation failure does not undo or relabel successful infrastructure activation.
This produces new evidence, not restoration of history lost on parent deletion.

## Runtime commands

```powershell
az login --tenant <TENANT_ID>
# Scripts pass --subscription on every request and never run az account set.
.\tests\Invoke-Tests.ps1
az bicep build --file .\infra\main.bicep --stdout

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -WhatIf

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -ParentOnly

.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json

# Read full actual objects/preview before approving any writes.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Inspect

# Only after that exact scope is approved. Add -AllowLegacyMigration only
# for an explicitly approved existing-legacy cutover, not clean reconstruction.
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -Apply `
  -BackupPath <NEW_ABSOLUTE_PATH_OUTSIDE_REPO.json>

.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Ready -OutputFormat Json
```

See [response-plan automation](sre-response-plan-automation.md) for supported
commands, pinned protocol sources, idempotency/timeouts and exact machine
contract. Complete deployment can use -ConfigurationBackupPath instead of
-ParentOnly; a new live incident/recovery test still needs separate authorization.

## Lifecycle and permission boundaries

SRE has a deletion-based off state, not VM-style deallocation. Deletion discards
handler/plan/history/memory/connector state. Parent redeployment is only stage one
of reconstruction. Resume requires data-plane setup and verification again.
Save evidence before cleanup and reauthorize optional repository connections.
Versioned assets recreate the modern custom agent/v3 filters, not retired
legacy objects, saved threads or learned memory. A separate IaC module creates
the SRE-only UAMI on first deployment; later normal cycles retain it in the SRE
group and reuse its principal and deterministic workload grant IDs. Parent
SystemAssigned,UserAssigned compatibility is unchanged: its system principal
still rotates, without external workload grants. Do not promise zero directory
churn. Historical whole-group deletion needs one replacement UAMI; that deleted
principal cannot be restored. Full group/identity removal is separate authorized
cleanup, never ordinary hibernation. The renderer enforces true/3-hour cooldown.

The deploying identity may be User or ServicePrincipal (including managed
identity). The script infers known Azure CLI identity types; pass
`-DeployerPrincipalType` for an unrecognized execution identity. RBAC names include
the live principal and adopt existing same-principal role assignments. Incremental
Bicep does not remove obsolete grants; Low downgrade with existing write grants
fails explicitly pending a separately approved reconciliation.

High uses Reader/Log Analytics Contributor/Contributor at the two workload groups.
Low uses true Log Analytics Reader, not the formerly mislabeled Contributor ID.
Hibernate retains existing grants (free, but still standing access); before Active,
deployment/readiness reject incompatible/inherited/extra grants, including legacy
Monitoring Contributor, for separately approved reconciliation. Deployment adopts
existing direct assignment names and does not query Graph display names.
Retained AppInsights must match the requested workspace/location; wake does not
silently relocate it. Older UAMI-only parking rebuilds missing diagnostics through
the same IaC. No grants are removed during Active or normal Hibernate.
Removed inventories principal-filtered ARM assignments with bounded validated
pagination; unexpected SRE resources or scoped grants block its destructive path.

Local checks cover parser/schema/rendering/mocked failures and safety behavior.
They do not prove Azure data-plane create reliability, destructive lifecycle
rebuild, live guest execution or a new T09 alert-to-recovery run.
The 2026-10-20 fresh T09 retry separately proved SRE repair and actual Monitor
recovery; its earlier operator fallback is distinct. User-confirmed portal
approval and independent write/tool evidence are recorded, but no independent
ApprovalDecision event was captured. It did not exercise deletion-to-Ready.
