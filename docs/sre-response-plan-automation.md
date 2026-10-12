# SRE custom agent and response-plan automation decision

## Decision

The SRE setup is **partly automatable today** and should be documented that way.

| Setup item | Current automation status | Demo kit stance |
|---|---|---|
| Parent `Microsoft.App/agents` resource | Automated through Bicep and `Deploy-SreAgent.ps1` | Shareable and repeatable |
| Custom handling/subagent | MCP now exposes `sreagent_agents_create`; prior portal setup worked; live verification of the MCP create path is still required after SRE is reactivated | Treat as the preferred automation path to validate next |
| Incident response plan | MCP exposes `sreagent_incidents_plans_create`, but it requires an existing custom agent/handler | Automatable after the custom agent exists |
| Portal/manual setup | Official docs describe portal/canvas setup and it worked in the live lab | Keep as fallback and document clearly |
| Playwright/browser automation | Feasible fallback if MCP custom-agent create fails | Separate optional task |

## Why this matters

The goal is that another SE can send the two repo links to an AI coding assistant
and say "deploy the demo" with minimal human interpretation. The parent SRE Agent
deployment already works this way. The remaining risk is SRE data-plane setup:
creating the custom handling agent and response plans that route Azure Monitor
alerts to that custom agent.

## Official documentation findings

Microsoft Learn currently describes incident response plan creation through the
SRE Agent portal:

- Create or use an agent with an incident platform connected.
- Create at least one custom agent first.
- Create the response plan from **Builder > Agent Canvas** or **Builder > Incident
  response plans**.
- For Azure Monitor, filter by severity and optional title contains.
- Select a response custom agent/subagent.
- Select autonomy level. Start with **Review**.
- Avoid duplicate routing by deleting or disabling the automatically created
  quickstart response plan if it also matches the alert.

The docs also state that Azure Monitor connects automatically when the SRE Agent is
created, and response plans decide which incidents the agent handles.

The Azure MCP Server docs list an SRE Agent **Incidents: Create plan** tool. That
matches the `sreagent_incidents_plans_create` MCP command, but plan creation still
depends on a handler/custom agent existing.

## Current MCP command surface

The currently exposed SRE MCP commands include these relevant operations:

### Create custom sub-agent

`sreagent_agents_create`

Required:

- `name`
- `agent`

Optional/useful:

- `subscription`
- `tenant`
- `resource-group`
- `description`
- `instructions`
- `tools`
- `handoffs`

This command did not exist, or was not used, during the earlier failed setup pass.
It is the best candidate for making custom-agent setup fully automatable.

### Create response plan

`sreagent_incidents_plans_create`

Required:

- `name`
- `severity`
- `trigger-condition`
- `services`
- `steps`
- `agent`

Optional/useful:

- `subscription`
- `tenant`
- `resource-group`
- `agent-mode`
- `escalation`
- `runbook-url`

Known live behavior: when no custom handling agent existed, plan creation failed
with:

```text
Handling agent 'sre-arc-demo' does not exist.
```

After the custom agent was created in the portal, response-plan creation worked for
the LOB app plan.

### Workflow YAML path

`sreagent_workflows_generate`, `sreagent_workflows_validate`, and
`sreagent_workflows_apply` exist for ExtendedAgent and tool YAML.

Historical live result:

- YAML validation passed.
- `sreagent_workflows_apply` failed with a data-plane 400:

```text
The JSON value could not be converted ...; request field is required.
```

Until that schema mismatch is resolved, do not make YAML apply the primary path.

## Recommended automation order

Use this order in the shareable AI deploy handbook:

1. Deploy the parent SRE Agent:
   ```powershell
   .\scripts\Deploy-SreAgent.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath .\config\demo-skin.json `
     -AccessLevel High
   ```
2. Create the custom handling agent with MCP:
   ```text
   command: sreagent_agents_create
   name: sre-arc-demo
   agent: sre-arc-demo
   subscription: <SUBSCRIPTION_ID>
   tenant: <TENANT_ID>
   resource-group: rg-arc-demo-sre
   description: Handles Arc demo Azure Monitor incidents in Review mode.
   instructions: Investigate only the Arc demo resources. For Container App alerts, identify SIMULATE_CRASH and propose resetting it to false. For Arc server and LOB-on-Arc alerts, produce RCA and guide operator Arc Run Command recovery; do not claim autonomous Arc repair.
   ```
3. Create the T09 response plan with MCP:
   ```text
   command: sreagent_incidents_plans_create
   name: container-app-restart-review
   severity: high
   trigger-condition: alert-arc-demo-containerapp-restarts OR containerapp-restarts
   services: Azure Container Apps, ca-arc-demo-fault, rg-arc-demo-infra
   steps: Investigate revision health, RestartCount, and SIMULATE_CRASH; propose az containerapp update SIMULATE_CRASH=false; verify recovery
   agent-mode: review
   agent: sre-arc-demo
   ```
4. Create the T11 response plan only if running the LOB-on-Arc bridge:
   ```text
   command: sreagent_incidents_plans_create
   name: lob-arc-app-review
   severity: high
   trigger-condition: lob-arc-app-fault OR ArcLobBridgeApp
   services: Azure Arc, win-app-01, ArcLobBridgeApp
   steps: Inspect Log Analytics Event rows and Arc machine state; produce RCA; guide operator Arc Run Command recovery
   agent-mode: review
   agent: sre-arc-demo
   ```
5. Verify:
   ```text
   command: sreagent_incidents_plans_list
   agent: sre-arc-demo
   subscription: <SUBSCRIPTION_ID>
   tenant: <TENANT_ID>
   resource-group: rg-arc-demo-sre
   ```

## Fallback manual portal path

If `sreagent_agents_create` fails in the live environment, use the portal path:

1. Open `https://sre.azure.com`.
2. Select the parent agent `sre-arc-demo`.
3. Go to **Builder > Agent Canvas**.
4. Create a custom agent named `sre-arc-demo`.
5. Paste the instructions from the MCP step above.
6. Go to **Builder > Incident response plans** or **Incidents > Triggers + response plans**.
7. Delete or disable any quickstart response plan that would also match the demo alerts.
8. Create `container-app-restart-review` in Review mode.
9. Create `lob-arc-app-review` only if running T11.
10. Verify the plan grid shows the expected plan, status On, response custom agent,
    severity, and Review autonomy.

## What remains to validate

The SRE layer is currently hibernated, so this review could not live-test
`sreagent_agents_create`. The clean-room shareability test must validate:

1. Deploy parent SRE Agent.
2. Run `sreagent_agents_create`.
3. Run `sreagent_incidents_plans_create`.
4. Confirm a T09 Azure Monitor alert automatically opens a thread handled by the
   custom agent.

If step 2 fails, proceed to the optional Playwright/browser automation task.
