# Delivery runsheet — Arc + Monitor + SRE three-act demo

Scene-by-scene storyboard for delivering the reusable Arc + Azure Monitor + Azure SRE Agent demo. It spans both repos:

- `C:\src\arc-demo` = standalone Arc + Monitor spine.
- `C:\src\sre-agent` = optional SRE Agent layer over an existing `arc-demo` deployment.

Recommended delivery: **60-70 minutes** plus pre-demo setup. Shorten by skipping optional Azure VM/AKS beats and using T09 as the primary live closed-loop SRE path.

## Validation and honesty markers

| Marker | Meaning for the presenter |
|---|---|
| **Built / locally validated** | Repo assets, docs, Bicep, and scripts were authored and locally checked. Safe to show paths, commands, and intended flow. |
| **Live lab required** | Requires a deployed Azure subscription/portal run before claiming it worked live. |
| **Pending verdict** | Do not sell as proven. State it is the next empirical lab question. |

Current status for T13:

- Act 1 Arc/Monitor assets are built in `C:\src\arc-demo`; portal visuals depend on a live deployment and data ingestion.
- T09 native Container App SRE loop is live validated end to end: alert, RCA, Review approval, SRE repair, recovery, and alert closure.
- T10 Arc-server value is live validated for SRE-assisted diagnosis and Arc Run Command viability. Autonomous / SRE-executed Arc server repair is **not currently demo-ready** and should be described only as possible future capability.
- T11 LOB-on-Arc bridge is live validated for Arc app fault signal, Log Analytics Event ID `4100`, Azure Monitor alerting, SRE incident creation, and operator Arc Run Command recovery. In the latest run, SRE RCA generation stalled before final diagnostic output, so do **not** present T11 as a proven SRE RCA or autonomous repair path.
- Present T09 as the fully closed-loop "wow" path. Present T10/T11 as hybrid signal, diagnosis package, and governed operator remediation through Arc Run Command.

## Narrative spine

Use this as the through-line, especially for SA DTF / OCIO-style conversations:

> The customer already has servers, apps, and operational knowledge spread across
> datacenters, teams, and tools. The demo is not "look at another portal." The demo
> is: bring the estate into one Azure operations plane, turn on useful signals, then
> show how SRE Agent can compress investigation time for both Azure-native and
> on-prem-shaped incidents.

Before:

- Inventory lives in spreadsheets, CMDB extracts, and team memory.
- Legacy OS and SQL estate risk is hard to prioritize.
- Alerts tell operators that something happened, but not what to do next.
- On-prem app incidents start with RDP, log hunting, and finding the right owner.

After:

- Arc gives the hybrid estate Azure identity, inventory, tags, policy, Defender,
  Update Manager, Monitor, and auditable access.
- Azure-native workloads can already use a full SRE closed loop.
- Arc/on-prem-shaped workloads get Azure-side evidence and governed operator
  recovery through Azure; SRE RCA is the part we keep hardening.
- The same spine can be reskinned across OCIO agencies and other customers.

The two phrases to repeat:

1. **"Arc is the operations plane for hybrid."**
2. **"SRE Agent turns signals into guided investigation and safe action."**

## Pre-demo setup checklist

Use a clean/new subscription in the **same tenant** for both repos. Keep tenant/subscription IDs as runtime inputs.

1. Deploy or activate the Arc/Monitor spine:

   ```powershell
   cd C:\src\arc-demo
   az login --tenant <TENANT_ID>
   az account set --subscription <SUBSCRIPTION_ID>

   .\scripts\Deploy-ArcDemo.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath .\config\demo-skin.json `
     -DeployAzureVMs $true `
     -DeployContainerApps $true
   ```

   Optional: add `-DeployAks $true` if you want the AKS beat and have time/cost headroom. Keep `-DeployArcOnPrem $true` for the core DTF-shaped story.

2. For Act 2 live rehearsal only, deploy the SRE layer after `arc-demo` exists:

   ```powershell
   cd C:\src\sre-agent
   .\scripts\Deploy-SreAgent.ps1 `
     -SubscriptionId <SUBSCRIPTION_ID> `
     -TenantId <TENANT_ID> `
     -SkinPath .\config\demo-skin.json `
     -AccessLevel High
   ```

3. Open tabs before the meeting:
   - `C:\src\arc-demo\docs\runsheet.md`
   - `C:\src\sre-agent\docs\t09-native-containerapp-closed-loop.md`
   - `C:\src\sre-agent\docs\t10-sre-on-arc-experiment.md`
   - `C:\src\sre-agent\docs\t11-hybrid-diagnostics-wow.md`
   - `C:\src\sre-agent\docs\t11-lob-app-on-arc-bridge.md`
   - Arc Demo workbook, Arc servers, Azure Monitor Alerts, Log Analytics, Update Manager, Defender for Cloud.
   - SRE Agent portal only if a live SRE lab has been rehearsed.

## Time plan

| Segment | Time |
|---|---:|
| Opening and Act 1 Arc/Monitor | 25-30 min |
| Act 2 governed SRE loop and hybrid positioning | 20-25 min |
| Act 3 scale/govern/reuse | 12-15 min |
| Close / reset / next steps | 3-5 min |

## Act 1 — Arc as the operations plane

Goal: move the customer from "server-by-server operations" to "one governed
operations plane" before talking about AI remediation.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 1.1 Customer pain | 2 min | Frame SA DTF Infrastructure Modernisation Program: hybrid Hyper-V + Azure, existing Arc connection, EOL pressure, 2am toil. | `C:\src\arc-demo\config\demo-skin.json`, `docs\reskin-guide.md` | "The issue is not whether these servers exist. The issue is whether operations, security, and app teams can reason over them from one place." | Built / locally validated |
| 1.2 Demo contract | 2 min | Explain two repos: Arc/Monitor spine first, optional SRE layer second. | `C:\src\arc-demo\docs\runsheet.md`, `README.md`, `scripts\Deploy-ArcDemo.ps1` | "Arc-demo stands alone. SRE is the next layer once the estate has signal." | Built / locally validated |
| 1.3 Estate overview | 4 min | Open **Arc Demo - Estate Overview** workbook and **Azure Arc > Machines** filtered to `rg-arc-demo`. Fallback: open `rg-arc-demo` and filter to `Microsoft.HybridCompute/machines`. Show OS mix and connected machines. | `docs\runsheet.md` sections 3.2-3.3; `docs\legacy-os-fleet.md` | "This is the first win: one inventory, one tagging model, one place to start the operational conversation." | Live lab required for portal data |
| 1.4 Legacy OS / ESU posture | 4 min | Filter tags `osTier`, `monitorTier`, `esuEligible`. Show represented WS2008/WS2012 tier if using mixed fleet. | `docs\legacy-os-fleet.md`; `-OnPremFleetPath`; `bicep\params\mixed-legacy-fleet.bicepparam` | "Legacy is not invisible anymore. We can be honest about what can and cannot run agents, then plan ESU and modernization from data." | Built; live ESU enrollment not automated |
| 1.5 Governance and risk | 8 min | Inventory, Machine Configuration/TLS 1.2 posture, Update Manager, Defender for Cloud, optional SQL workload simulation. | `docs\runsheet.md` sections 3.3-3.8 | "Arc makes hybrid servers policy-addressable and visible to platform, security, and operations teams." | Live lab required for populated blades |
| 1.6 Monitor on supported machines | 5 min | On WS2016+/WS2019/WS2022, show Heartbeat, Perf/Event, VM Insights map, Change Tracking. | AMA/DCR modules in `arc-demo`; KQL in `docs\runsheet.md` section 3.7 | "This is where the operations plane becomes signal: heartbeat, events, performance, drift, and alerts." | Live lab required for telemetry |
| 1.7 Alert seam | 4-5 min | Show heartbeat alert and Action Group. If deployed, show Azure-native VM, Container App `RestartCount`, optional AKS pod-restart alert. | `docs\container-app-fault.md`, `docs\aks-break-scenario.md`, `-DeployAzureVMs`, `-DeployContainerApps`, `-DeployAks` | "The Action Group is the seam. It lets us move from monitoring to guided incident response without changing the Arc spine." | Built; live alert firing requires lab |

Act 1 close line:

> "We now have a reusable hybrid operations plane: inventory, governance, security, patch posture, Monitor, and alerts. That is useful even before any AI agent appears."

## Act 2 — SRE Agent governed loop

Goal: show the difference between "an alert fired" and "we know what happened and
what safe action to take." Keep governance explicit.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 2.1 Honest status reset | 1 min | State which SRE paths are live-proven today. | This runsheet; T09/T10/T11 evidence checklists | "The Azure-native Container App path is closed-loop proven. The Arc-server paths are proven for signal, evidence, and operator Arc Run Command recovery. We are not selling autonomous Arc server repair in this demo." | Required honesty marker |
| 2.2 Optional SRE layer architecture | 3 min | Show `sre-agent` README, Review mode, AzMonitor incident source, RBAC profiles, and separation from `arc-demo`. | `C:\src\sre-agent\README.md`, `infra\main.bicep`, `scripts\Deploy-SreAgent.ps1` | "The agent layers on top. It reads existing Arc/Monitor resources; it does not redeploy or modify arc-demo." | Built / locally validated |
| 2.3 T09 native Container App wow | 10-12 min | Induce `SIMULATE_CRASH=true`, wait for `alert-arc-demo-containerapp-restarts`, show SRE RCA, approve reset to `false`, verify endpoint and audit. | `docs\t09-native-containerapp-closed-loop.md`, `scripts\Invoke-NativeContainerAppFault.ps1`, `C:\src\arc-demo\docs\container-app-fault.md` | "This shows the closed-loop future that is already real for Azure-native workloads." | Live validated |
| 2.4 T11 hybrid diagnostics wow | 8-10 min | Show the LOB app fault on an Arc server: Event ID `4100`, Azure Monitor alert, SRE incident creation if configured, evidence package, and operator Arc Run Command recovery. | `docs\t11-hybrid-diagnostics-wow.md`, `docs\t11-lob-app-on-arc-bridge.md`, `scripts\Invoke-LobArcAppOnArc.ps1`, `scripts\New-LobArcAppMonitorAlert.ps1` | "This is the on-prem-shaped wow: Arc turns an opaque datacenter app failure into Azure-side evidence and a governed operator action. The current proven claim is signal plus operator recovery, not autonomous repair." | Live validated for alert + incident creation + manual Arc recovery; SRE RCA generation is not yet reliable |
| 2.5 T10 backstage evidence | 2-3 min | Mention only if the audience wants proof of the mechanics: Arc Run Command works, SRE can reason over Arc evidence, autonomous Arc repair is future-only. Do not run T10 as the main demo scene. | `docs\t10-sre-on-arc-experiment.md`, `scripts\Invoke-T10ArcFault.ps1` | "T10 is the engineering proof behind the T11 story, not the main customer scene." | Backstage evidence |
| 2.6 Governance and audit | 2 min | Reinforce Review mode, approval card, RBAC, Activity Log, SRE thread audit. | T09 section 9; README RBAC table | "AI can recommend and execute only inside Azure RBAC, Review approval, and auditable operations." | Built design; live audit requires run |

Act 2 fallback if live SRE is not ready:

> "For today, T09 is the proven SRE closed-loop path. For T11, the proven path is Arc app event, Log Analytics, Azure Monitor alert, and operator Arc Run Command recovery. If the SRE handler stalls, show the evidence package and say the response-plan route is being hardened, not the Arc diagnostic model."

## Act 3 — Scale and govern

Goal: move from one demo to a reusable customer motion without changing the technical spine.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 3.1 Spine + skin model | 4 min | Show both `config\demo-skin.json` files and dummy-customer examples. Explain what changes per customer. | `C:\src\arc-demo\docs\reskin-guide.md`, `C:\src\sre-agent\docs\reskin-guide.md` | "The spine is the Azure build and click-path. The skin is customer name, estate mix, prefix, toggles, labels, and repo context." | Built / locally validated |
| 3.2 Two-repo separation | 3 min | Point to `arc-demo` standalone README/runsheet and optional `sre-agent` scenario docs. | `C:\src\arc-demo\README.md`; `C:\src\sre-agent\README.md` | "We can deliver Arc/Monitor alone, then add SRE only when the customer is ready." | Built / locally validated |
| 3.3 Same-tenant-new-subscription lab | 2 min | Explain subscription pattern: clean subscription, same tenant, runtime IDs, no private values in docs. | `arc-demo` README prerequisites; `scripts\Deploy-ArcDemo.ps1`; `scripts\Deploy-SreAgent.ps1` | "Make the lab easy to reset and safe to share. Keep customer-specific IDs out of source." | Built guidance |
| 3.4 Approval gates, RBAC, audit | 3 min | Show Low/High access profiles and Review-mode stance. Explain production hardening. | `sre-agent` README; `docs\t10-sre-on-arc-experiment.md` required RBAC | "Scale depends on trust: least privilege, explicit approval, Activity Log, SRE thread, and no unattended risky changes." | Built design; live proof pending |
| 3.5 SRE rollout motion | 2 min | Position the next step as a two-day Review-mode PoC or 1:many Modern Ops workshop, not as production autonomy. | `docs\sre-sales-rollout-guidance.md` | "Use the live demo to qualify a real workload, real telemetry, a real Azure Monitor alert, and the customer team needed for a PoC." | Internal guidance |
| 3.6 OCIO / customer reuse | 2 min | Close with DTF as poster child, reusable across OCIO agencies and other hybrid-estate customers. | Reskin guides and this runsheet | "Same spine, new skin: prove once, retarget repeatedly across agencies, business units, or accounts." | Positioning |
| 3.7 Follow-on paths | 1 min | Mention SQL sidecar/customer PoC and EDE PoC as follow-ons, not gaps. | `arc-demo\docs\sql-arc-spike.md`, T14 summary | "If SQL Server enabled by Azure Arc is important, we connect a real non-Azure SQL host in a follow-on PoC. Today’s demo proves the reusable operations and diagnostics motion." | Follow-on |

## Close line

> "This is the pattern I want you to remember: Arc gives the hybrid estate an
> Azure operations plane, Monitor turns it into signal, and SRE Agent turns signal
> into guided diagnosis and safe action. We can reuse the same spine with a new
> skin for each agency or customer."

## Scene-to-asset quick map

| Story beat | Primary asset |
|---|---|
| Arc estate / cook's tour | `C:\src\arc-demo\docs\runsheet.md` |
| Legacy OS / ESU posture | `C:\src\arc-demo\docs\legacy-os-fleet.md` |
| Optional Azure-native VM | `-DeployAzureVMs $true` and `C:\src\arc-demo\README.md` |
| Optional Container App fault | `C:\src\arc-demo\docs\container-app-fault.md` |
| Optional AKS fault | `C:\src\arc-demo\docs\aks-break-scenario.md` |
| SRE Agent deployment | `C:\src\sre-agent\scripts\Deploy-SreAgent.ps1` |
| T09 native closed loop | `C:\src\sre-agent\docs\t09-native-containerapp-closed-loop.md` |
| T10 Arc-server experiment | `C:\src\sre-agent\docs\t10-sre-on-arc-experiment.md` |
| T11 hybrid diagnostics wow | `C:\src\sre-agent\docs\t11-hybrid-diagnostics-wow.md` |
| T11 LOB-on-Arc bridge details | `C:\src\sre-agent\docs\t11-lob-app-on-arc-bridge.md` |
| Reskin / reuse | both repos' `docs\reskin-guide.md` and `config\demo-skin.json` |

## Reset checklist

After any live rehearsal:

```powershell
cd C:\src\sre-agent
.\scripts\Invoke-NativeContainerAppFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -State Repair
.\scripts\Invoke-T10ArcFault.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action Reset
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json -Action ResetFault

cd C:\src\arc-demo
.\scripts\Hibernate-ArcDemo.ps1 -SkinPath .\config\demo-skin.json

cd C:\src\sre-agent
.\scripts\Hibernate-SreAgent.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath .\config\demo-skin.json
```

Only include reset commands for scenarios you actually induced. Capture SRE threads, alert history, Activity Log entries, and KQL snippets before resetting.

## Remaining live-validation gaps

- T09: optional source-code repository connection/audit polish only; core closed-loop path is proven.
- T10: keep as assisted diagnosis plus manual/operator Arc Run Command replay. Treat SRE-executed Arc Run Command repair as future investigation, not current demo scope.
- T11: current proven behaviour is Log Analytics Event ID `4100`, Azure Monitor alerting, SRE incident creation when response plans are configured, and operator Arc Run Command recovery. The latest SRE RCA generation stalled, so keep T11 positioned as hybrid evidence + governed operator recovery until response-plan RCA is reliable.
- Act 1: before customer delivery, refresh live portal screenshots/queries after deployment because Monitor, Defender, Policy, and Update Manager blades have ingestion delays.
