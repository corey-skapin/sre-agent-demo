# Reconstructing the SRE handler and Review response plans

## Supported boundary

Parent deployment is not a Ready demo. The complete order is **parent -> data-plane
availability -> custom handler -> plans -> filter/routing verification**. Deletion-based
hibernation requires repeating that sequence. The checked-in skin and handler
instructions reconstruct desired configuration, not historical service state.

Microsoft's supported interfaces, checked on 2026-10-19:

| Interface | Supported capability | Important limit |
|---|---|---|
| Bicep `Microsoft.App/agents` | Parent, identity, Review action mode, managed resources | Does not deploy custom handlers or response plans |
| Azure MCP `sreagent_agents_create` | Idempotent custom-handler create/update | No corresponding custom-handler read command in the discovered surface; `agents_get` reads the parent |
| `sreagent_incidents_plans_create` | Creates/enables a plan; explicitly pass `agent-mode: review` | Non-idempotent; never blindly retry after timeout |
| `sreagent_incidents_plans_list` | Lists configured plans, filters, status and handler summaries | Current result is human-readable text, not a documented stable full desired-state schema |
| SRE portal Builder | Inspect/edit custom handlers, filters, handler mapping, status, autonomy | Requires authorized browser capability and interactive sign-in/onboarding when prompted |

No supported plan-update command was exposed. We do not use undocumented portal
REST endpoints, invent request bodies, or claim that workflow YAML validation
proves successful application. Historical handler-create timeouts and YAML apply
failures remain historical evidence, not proof of current failure or readiness.

Sources:
- [Azure MCP SRE tools](https://learn.microsoft.com/azure/developer/azure-mcp-server/tools/azure-sre-agent)
- [SRE MCP setup and permissions](https://learn.microsoft.com/azure/sre-agent/setup-mcp-server)
- [Incident response plans and portal controls](https://learn.microsoft.com/azure/sre-agent/incident-response-plans)
- [Custom agents](https://learn.microsoft.com/azure/sre-agent/sub-agents)

## Render the exact desired state

```powershell
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
```

This local command returns JSON containing supported MCP requests, with runtime
context, skin-specific resource names, versioned handler instructions, explicit
Review mode, and the required T09/T11 plans. Keep its output outside git: it
contains runtime target IDs. It does not call Azure or authenticate a repository.
`-Apply` fails with `SRE_BOOTSTRAP_CAPABILITY_REQUIRED` rather than pretending to
configure an unverifiable data plane.

`labels.containerResponsePlan` and `labels.lobResponsePlan` identify the plans.
`labels.lobAlertTitleContains` is shared with the LOB alert display name. Title
contains is a **single keyword**, not an undocumented Boolean expression:
T09 uses `containerapp-restarts`; T11 uses the configured LOB keyword. Do not put
`OR` into a literal substring filter. Match the actual alert title in the portal.
Plan severity must include the actual Azure Monitor Sev2 incident; verify the
platform's displayed severity mapping rather than assuming MCP `high` equals Sev2.

## Bounded ensure procedure for a connected agent

1. Verify explicit tenant/subscription and parent `Succeeded`/`Running`. Use the
   read-only readiness command with a bounded timeout. Wait for parent/data-plane
   availability at most 180 seconds, checking every 10 seconds; a timeout is
   pending, not success. Do not start a replacement deployment.
2. Open `https://sre.azure.com` in an authorized visible browser. Select the
   target parent, complete first-run onboarding if required, and inspect
   **Builder > Agent Canvas**. Compare the custom handler's name, description
   and full instructions with the rendered desired state.
3. If absent or different, use the rendered `sreagent_agents_create` request, or
   edit the same handler in Builder. Attempt at most twice, 10 seconds apart.
   After every timeout, **read back in Builder first**: creation may have completed.
   If read-back is unavailable, stop and report a capability requirement. Do not
   create another handler or claim the original request failed definitively.
4. List plans with the rendered verification request, then inspect each named plan
   in **Builder > Incident response plans**. If an exact desired plan already
   exists, leave it unchanged. If an existing plan differs, edit that same plan
   in the portal; do not create a duplicate or delete/recreate it.
5. Only after confirming absence in both list and portal, submit the rendered
   create request **once**. After timeout/error, poll list/portal every 10 seconds
   for at most 180 seconds. If outcome remains ambiguous, stop pending. A plan
   create is not safe to replay merely because the client timed out.
6. Verify each required plan is **On**, correct Azure Monitor source, actual
   severity, literal title keyword, intended impacted service and custom handler,
   and **Review**. Inspect full handler instructions too. The portal's default
   autonomy can be Autonomous, so explicitly select Review every time.
7. Inspect all enabled plans, including quickstart plans, for overlap. Report
   conflicts and proposed narrowing; obtain scoped authorization before changing,
   disabling or deleting another plan. Never automatically remove quickstart.
8. Record observed configuration and remaining gates. Missing browser capability,
   stale authentication, unavailable read-back, conflict or ambiguous timeout is
   an explicit failed/pending gate, never a successful manual fallback.

For repeat runs, ensure means compare/read-back first, update only differing
owned objects, verify, then stop. No plan deletion, autonomy change, fault
induction or new grants are part of this setup procedure.

## Readiness and lifecycle

```powershell
# Explicitly deploy only the supported control plane:
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -ParentOnly

# Read-only ARM/resource/RBAC baseline plus explicit pending service gates:
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Ready `
  -OutputFormat Json -TimeoutSeconds 180
```

The JSON contract is shared with Arc: `schemaVersion`, `workload`, `checkedAtUtc`,
`subscriptionId`, `tenantId`, `resourceGroups`, `desiredState`, `status`,
`checks[{id,resourceId,required,expected,observed,status,message}]`.
Statuses are `pass|fail|pending|skipped`; exit codes are 0 pass, 1 fail/error,
2 pending. A parent with correct ARM configuration can still return pending
because handler/plan/telemetry verification requires supported service/browser
read-back. This script does not accept a user-supplied success attestation.
It must not be described as a full automatic routing certificate.

Before separately authorized hibernation, save the user-assigned identity
principal ID and export incident/thread/audit evidence. Group deletion loses
custom agents, plans, incidents/threads, knowledge/memory and connector setup;
Log Analytics records retained in the Arc workspace follow that workspace's
retention policy. Repository connector authorization must be re-established
explicitly; a source URL is not permission.

After deletion, pass the saved principal to
`Test-SreReadiness.ps1 -DesiredState Hibernated -PreviousIdentityPrincipalId <ID>`
to verify external grants are absent. Without a known old principal, legacy
orphan grant checks remain pending. A submitted deletion is not a verified
hibernated state. Re-enable the Arc spine first, then parent, handler, plans,
readiness, and browser/telemetry gates. Do not hibernate automatically on deploy.

## Current versus historical evidence

Read-only inspection on 2026-10-19 saw a Running Review/High parent and two enabled
Review plans. The Container App was healthy and the target Arc machine Connected.
The initial parent lacked the explicit T09 Container App managed-resource ID.
After separate user approval, a narrow ARM PATCH appended only that existing
Container App ID; read-back preserved the original five IDs byte-for-byte and
confirmed all other parent properties unchanged. Review and existing grants were
preserved. Existing Monitoring Contributor is tolerated for High demo compatibility,
not added by the standard profile; High retains its historical Log Analytics
Contributor grant, while Low now correctly uses true Log Analytics Reader.

Plan title summaries contained `OR` strings requiring portal review. The approved
two filter edits were not performed because available browser observation could
not reliably identify the target window/URL. The live T11 alert still has a display
name without the desired keyword; changing that alert was not authorized. Readiness
therefore reports T11 title alignment failed and service gates pending, not Ready.
Timestamped read-only/reconciliation evidence and rollback IDs were saved outside
git. No fault injection, grant removal, plan recreation or destructive lifecycle
test was performed. This is not evidence of a fresh end-to-end closed loop.

T09 remains the primary historically proven Review closed-loop wow path.
T10/T11 remain hybrid signal/evidence plus governed **operator** Arc Run Command
recovery. T11 SRE RCA can stall; do not promote it to reliable RCA or autonomous
Arc repair.
