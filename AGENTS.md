# AGENTS.md - AI Agent Operating Manual for `sre-agent`

> Read this file first when using GitHub Copilot CLI, Scout, Claude Code, Cursor,
> Windsurf, Aider, OpenAI Codex, or another AI coding assistant.

This repo is the optional Azure SRE Agent layer for the standalone
[`arc-demo`](https://github.com/corey-skapin/arc-demo) repo. It does not deploy
the Arc estate. It attaches SRE Agent to an existing `arc-demo` deployment and
adds the T09/T10/T11 SRE scenarios.

## Current validated stance

- **T09 Container App** is the only fully validated closed-loop SRE path:
  Azure Monitor alert -> SRE RCA -> Review approval -> SRE-executed repair ->
  recovery verification.
- **T10/T11 Arc paths** are validated for signal/evidence plus governed operator
  Arc Run Command recovery. Do not claim autonomous Arc server repair.
- **T11 LOB-on-Arc** is validated for Event ID `4100`, Log Analytics, Azure
  Monitor alerting, SRE incident creation, and operator recovery. The latest live
  run showed SRE RCA generation can stall, so do not present T11 as reliable SRE
  RCA yet.

## Start here

For a live demo or customer rehearsal, use only this presenter path:

1. `docs\delivery-runsheet.md` - main story and timings across both repos.
2. `C:\src\arc-demo\docs\runsheet.md` - Act 1 Arc/Monitor walkthrough.
3. `docs\t09-native-containerapp-closed-loop.md` - primary SRE wow path.
4. `docs\t11-hybrid-diagnostics-wow.md` - hybrid Arc evidence/recovery path.
5. `docs\sre-response-plan-automation.md` - setup or repair SRE response plans.

Treat these as engineering references, not presenter source-of-truth:

- `docs\t11-lob-app-on-arc-bridge.md`
- `docs\t10-sre-on-arc-experiment.md`
- `docs\clean-room-shareability-test-2026-10-12.md`

## Happy-path setup

Assumes `arc-demo` already exists and is active.

```powershell
cd C:\src\sre-agent
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

$targetArcId = az connectedmachine show `
  --resource-group rg-arc-demo `
  --name win-app-01 `
  --query id `
  --output tsv

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($targetArcId)
```

Then configure the custom handler and Review-mode response plans using
`docs\sre-response-plan-automation.md`.

## SRE data-plane setup reality

The parent `Microsoft.App/agents` resource deploys repeatably through Bicep.
The response plans are automatable through MCP **after** a custom handling agent
exists.

The custom handling agent creation path is currently the fragile part:

- `sreagent_agents_create` can time out in the SRE data plane.
- `sreagent_workflows_apply` has validated YAML but failed server-side in the
  latest live run.
- The SRE portal path works after first-run onboarding. Scout/Playwright can
  automate it once the user is signed in to the lab subscription account.

Use this fallback if MCP custom-agent creation fails:

1. Open `https://sre.azure.com`.
2. Select the `sre-arc-demo` agent.
3. If the first-run screen appears, select **Done and go to agent**.
4. Go to **Builder** > **Agent Canvas**.
5. Create a subagent named `sre-arc-demo`.
6. Paste the handler instructions from `docs\sre-response-plan-automation.md`.
7. Use MCP `sreagent_incidents_plans_create` to create:
   - `container-app-restart-review-v2`
   - `lob-arc-app-review-v2`
8. Verify with `sreagent_incidents_plans_list`.

## Do not do these

- Do not change response plans to Autonomous for customer demos.
- Do not claim T11 autonomous Arc repair or reliable SRE RCA.
- Do not leave `rg-arc-demo-sre` running after a rehearsal unless the user asks.
- Do not modify `C:\src\arc-demo` from this repo; layer on top only.

## Hibernation

```powershell
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json
```

Then hibernate the Arc estate from `C:\src\arc-demo` if the whole lab should be
parked.
