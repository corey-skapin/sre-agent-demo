# AI deploy handbook - optional SRE layer

Use this only after standalone `arc-demo` is active. The Arc repo owns its estate;
this repo adds SRE without editing the Arc checkout or redeploying its workloads.

## Handoff prompt

```text
Read AGENTS.md, README.md, docs/delivery-runsheet.md and
docs/sre-response-plan-automation.md.

Inputs: explicit subscription GUID, tenant GUID, skin, and desired state
Ready or Hibernated. Never infer target context from an ambient Azure login.
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
   and overlap now have full read-back. Separately verify the telemetry gate.
   Existing ARM success is not routing
   readiness. Do not induce a fault merely to answer a read-only readiness check.
7. Present T09 as primary proven Review closed loop; T10/T11 as hybrid evidence
   plus governed operator Arc Run Command recovery. T11 RCA is not reliable yet.
8. Leave a requested Ready demo running. Do not automatically hibernate.

For Hibernated:
1. Obtain explicit authorization for deletion and export required evidence.
2. Save the SRE user-assigned identity principal ID.
3. Preview Hibernate-SreAgent.ps1 -WhatIf, then execute only after approval.
4. Verify deletion and external RBAC with Test-SreReadiness.ps1
   -DesiredState Hibernated -PreviousIdentityPrincipalId <saved ID>.
5. Arc lifecycle is separately owned; do not stop its workloads from this repo.

Never change plans to Autonomous, remove quickstart plans, revoke extra grants,
connect a repository, or induce faults without the appropriate scoped approval.
```

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

The deploying identity may be User or ServicePrincipal (including managed
identity). The script infers known Azure CLI identity types; pass
`-DeployerPrincipalType` for an unrecognized execution identity. RBAC names include
the live principal and adopt existing same-principal role assignments. Incremental
Bicep does not remove obsolete grants; Low downgrade with existing write grants
fails explicitly pending a separately approved reconciliation.

High preserves the existing Reader/Log Analytics Contributor/Contributor profile.
Existing Monitoring Contributor grants are explicitly tolerated, not copied into
the standard profile. Low uses true Log Analytics Reader, not the formerly
mislabeled Log Analytics Contributor ID. Hibernation discovers known identity-owned
inherited grants too, shows their IDs in the deletion confirmation and deduplicates
them; no role grants are removed while the desired state is Ready.

Local checks cover parser/schema/rendering/mocked failures and safety behavior.
They do not prove Azure data-plane create reliability, destructive lifecycle
rebuild, live guest execution or a new T09 alert-to-recovery run.
