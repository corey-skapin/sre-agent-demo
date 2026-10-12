# AI deploy handbook - SRE Agent layer

Use this after the standalone `arc-demo` repo is deployed. This repo adds the
optional Azure SRE Agent layer and scenario runbooks.

## Give this prompt to the AI assistant

```text
You are deploying the optional Azure SRE Agent layer from
https://github.com/corey-skapin/sre-agent-demo on top of an existing deployment
from https://github.com/corey-skapin/arc-demo.

Read README.md, docs/t09-native-containerapp-closed-loop.md,
docs/sre-response-plan-automation.md, docs/t10-sre-on-arc-experiment.md,
docs/t11-lob-app-on-arc-bridge.md, and docs/delivery-runsheet.md before running
commands.

Inputs:
- Subscription ID: <SUBSCRIPTION_ID>
- Tenant ID: <TENANT_ID>
- Arc demo name prefix: <PREFIX, default arc-demo>
- SRE access level: High for lab validation, Low for observe-only

Do:
1. Confirm arc-demo is deployed and active.
2. Deploy the parent SRE Agent with scripts/Deploy-SreAgent.ps1.
3. Create the custom handling agent with sreagent_agents_create if available.
4. Create the T09 response plan with sreagent_incidents_plans_create.
5. If MCP custom-agent creation fails, use docs/sre-response-plan-automation.md portal/browser fallback.
6. Validate T09 as the only fully closed-loop remediation path.
7. Position T10/T11 as assisted diagnostics plus operator Arc Run Command recovery.
8. Hibernate the SRE layer with scripts/Hibernate-SreAgent.ps1 when finished.

Do not:
- Claim autonomous Arc server repair.
- Change response plans to Autonomous for customer demos.
- Leave the SRE resource group running after the rehearsal unless the user asks.
```

## Required inputs

| Input | Notes |
|---|---|
| Subscription ID | Same subscription as `arc-demo`. |
| Tenant ID | Same tenant used for `arc-demo`. |
| Name prefix | Must match `arc-demo` skin, default `arc-demo`. |
| Access level | `High` for live remediation validation; `Low` for observe-only. |
| Portal access | Needed only if MCP custom-agent creation fails. |

## Deployment order

```powershell
git clone https://github.com/corey-skapin/sre-agent-demo C:\src\sre-agent
cd C:\src\sre-agent

az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -AccessLevel High
```

## Configure custom agent and response plan

Preferred path:

1. Use `sreagent_agents_create` to create custom handling agent `sre-arc-demo`.
2. Use `sreagent_incidents_plans_create` to create `container-app-restart-review`.
3. Use `sreagent_incidents_plans_list` to verify.

Exact fields and fallback steps are in
[`sre-response-plan-automation.md`](sre-response-plan-automation.md).

If MCP setup fails:

1. Use the manual portal path in `sre-response-plan-automation.md`.
2. Or give the browser-agent prompt in that doc to Scout/Playwright.
3. Verify the plan grid before inducing alerts.

## Validation checklist

| Check | Expected |
|---|---|
| Parent SRE Agent exists | `sre-arc-demo` running in `rg-arc-demo-sre` |
| Incident platform | Azure Monitor |
| Custom handling agent | `sre-arc-demo` exists in Agent Canvas / subagent builder |
| T09 response plan | `container-app-restart-review`, On, Review mode |
| T09 closed loop | Container App alert opens SRE thread, RCA identifies `SIMULATE_CRASH=true`, approval resets it to `false`, app recovers |
| T11 code context | `https://github.com/corey-skapin/arc-demo` connected in SRE knowledge base if running LOB-on-Arc |
| T10/T11 stance | Assisted diagnostics only; operator Arc Run Command recovery |

## Scenario priority

1. **T09 Container App** - primary live "wow"; fully closed-loop validated.
2. **T10 Arc server** - assisted diagnostics, not autonomous repair.
3. **T11 LOB-on-Arc** - hybrid RCA bridge, operator recovery, optional if time allows.

## Hibernation

After rehearsal:

```powershell
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
```

Verify:

```powershell
az group exists -n rg-arc-demo-sre -o tsv
```

Expected: `false` after deletion completes.

Then hibernate the Arc spine from `C:\src\arc-demo` if the whole lab should be off.

## Manual steps summary

Manual/portal work is not expected if `sreagent_agents_create` works. If it fails,
the unavoidable manual step is creating the custom handling agent in the SRE portal
before creating response plans. The documented browser-agent path makes that step
repeatable and explicit.
