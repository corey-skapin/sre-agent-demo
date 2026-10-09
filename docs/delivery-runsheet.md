# Delivery runsheet — Arc + Monitor + SRE three-act demo

Scene-by-scene storyboard for delivering the reusable Arc + Azure Monitor + Azure SRE Agent demo. It spans both repos:

- `C:\src\arc-demo` = standalone Arc + Monitor spine.
- `C:\src\sre-agent` = optional SRE Agent layer over an existing `arc-demo` deployment.

Recommended delivery: **60-70 minutes** plus pre-demo setup. Shorten by skipping optional Azure VM/AKS beats and treating Act 2 as positioning until live SRE evidence is captured.

## Validation and honesty markers

| Marker | Meaning for the presenter |
|---|---|
| **Built / locally validated** | Repo assets, docs, Bicep, and scripts were authored and locally checked. Safe to show paths, commands, and intended flow. |
| **Live lab required** | Requires a deployed Azure subscription/portal run before claiming it worked live. |
| **Pending verdict** | Do not sell as proven. State it is the next empirical lab question. |

Current status for T13:

- Act 1 Arc/Monitor assets are built in `C:\src\arc-demo`; portal visuals depend on a live deployment and data ingestion.
- T09 native Container App SRE loop is the documented wow path, but live Azure alert/SRE execution is still pending.
- T10 Arc-server SRE remediation and T11 LOB-on-Arc bridge are packages/positioning paths with live verdicts pending.
- Do **not** present live SRE remediation as proven until evidence is captured in the T09/T10/T11 checklists.

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

Goal: prove the estate can be operated from Azure before talking about AI remediation.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 1.1 Skin the opening | 2 min | Frame SA DTF Infrastructure Modernisation Program: hybrid Hyper-V + Azure, existing Arc connection, EOL pressure, 2am toil. | `C:\src\arc-demo\config\demo-skin.json`, `docs\reskin-guide.md` | "The hard part is already done: the servers are Arc-connected. Today we turn that underused control plane into operations." | Built / locally validated |
| 1.2 Show lab shape and toggles | 2 min | Explain two RGs, workbook, default Arc fleet, optional Azure VM/Container App/AKS toggles. | `C:\src\arc-demo\docs\runsheet.md`, `README.md`, `scripts\Deploy-ArcDemo.ps1` | "This repo stands alone. SRE is optional and later." | Built / locally validated |
| 1.3 Estate overview | 4 min | Open **Arc Demo — Estate Overview** workbook and **Azure Arc → Servers**. Show OS mix and connected machines. | `docs\runsheet.md` sections 3.2-3.3; `docs\legacy-os-fleet.md` | "Start with one inventory and one operating model, not a migration debate." | Live lab required for portal data |
| 1.4 Legacy OS / ESU posture | 4 min | Filter tags `osTier`, `monitorTier`, `esuEligible`. Show represented WS2008/WS2012 tier if using mixed fleet. | `docs\legacy-os-fleet.md`; `-OnPremFleetPath`; `bicep\params\mixed-legacy-fleet.bicepparam` | "Pre-2016 Windows is not dark, but it is Arc-control-plane-only. Do not promise AMA, VM Insights, or Change Tracking there." | Built; live ESU enrollment not automated |
| 1.5 Arc cook's tour | 8 min | Inventory, Machine Configuration/TLS 1.2 posture, Update Manager, Defender for Cloud, optional Arc SQL. | `docs\runsheet.md` sections 3.3-3.8 | "Arc makes hybrid servers policy-addressable and visible to platform, security, and operations teams." | Live lab required for populated blades |
| 1.6 Azure Monitor on supported machines | 5 min | On WS2016+/WS2019/WS2022, show Heartbeat, Perf/Event, VM Insights map, Change Tracking. | AMA/DCR modules in `arc-demo`; KQL in `docs\runsheet.md` section 3.7 | "2016+ gets the full Monitor path; legacy gets governance and lifecycle value without unsupported agents." | Live lab required for telemetry |
| 1.7 Alert seam and optional workload beats | 4-5 min | Show heartbeat alert and Action Group. If deployed, show Azure-native VM, Container App `RestartCount`, optional AKS pod-restart alert. | `docs\container-app-fault.md`, `docs\aks-break-scenario.md`, `-DeployAzureVMs`, `-DeployContainerApps`, `-DeployAks` | "The Action Group is the seam the optional SRE repo consumes. Arc-demo itself stops at Monitor." | Built; live alert firing requires lab |

Act 1 close line:

> "We now have a reusable hybrid operations plane: inventory, governance, security, patch posture, Monitor, and alerts. That is useful even before any AI agent appears."

## Act 2 — SRE Agent governed loop

Goal: show the art of the possible with strict governance, while clearly separating proven local assets from pending live validation.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 2.1 Honest status reset | 1 min | State whether today's SRE portion is live or storyboarded. | This runsheet; T09/T10/T11 evidence checklists | "The SRE packages are built and locally validated. Live lab execution is pending unless we have captured evidence in this subscription." | Required honesty marker |
| 2.2 Optional SRE layer architecture | 3 min | Show `sre-agent` README, Review mode, AzMonitor incident source, RBAC profiles, and separation from `arc-demo`. | `C:\src\sre-agent\README.md`, `infra\main.bicep`, `scripts\Deploy-SreAgent.ps1` | "The agent layers on top. It reads existing Arc/Monitor resources; it does not redeploy or modify arc-demo." | Built / locally validated |
| 2.3 T09 native Container App wow | 10-12 min | If live validated: induce `SIMULATE_CRASH=true`, wait for `alert-arc-demo-containerapp-restarts`, show SRE RCA, approve reset to `false`, verify endpoint and audit. If not live validated: show the runbook and commands only. | `docs\t09-native-containerapp-closed-loop.md`, `scripts\Invoke-NativeContainerAppFault.ps1`, `C:\src\arc-demo\docs\container-app-fault.md` | "The first credible wow is Azure-native: alert, investigate, RCA with code context, human approval, real Azure fix, audit trail." | Live SRE execution pending |
| 2.4 T10 Arc-server experiment positioning | 5 min | Explain hypotheses and success/failure criteria. Show safe helper scenarios: heartbeat by backing VM, stopped service, disk/CPU signal. Do not claim verdict. | `docs\t10-sre-on-arc-experiment.md`, `scripts\Invoke-T10ArcFault.ps1` | "Arc servers are ARM resources, so this is plausible. The demo-ready claim only exists after the experiment matrix has evidence." | Pending verdict |
| 2.5 T11 LOB app on Arc bridge | 5 min | Position as the target hybrid bridge: app code repo runs on Arc server, emits Application events, alert routes to SRE, RCA can cite app code. | `docs\t11-lob-app-on-arc-bridge.md`, `samples\lob-arc-app`, `scripts\Invoke-LobArcAppOnArc.ps1`, `scripts\New-LobArcAppMonitorAlert.ps1` | "This bridges on-prem-shaped operations with the code-context SRE loop without pretending a bare legacy server can magically produce a PR." | Live validation pending |
| 2.6 Governance and audit | 2 min | Reinforce Review mode, approval card, RBAC, Activity Log, SRE thread audit. | T09 section 9; README RBAC table | "AI can recommend and execute only inside Azure RBAC, Review approval, and auditable operations." | Built design; live audit requires run |

Act 2 fallback if live SRE is not ready:

> "For today, treat Act 2 as the governed runbook package. The live lab still needs to capture the SRE incident, approval, action output, and reset evidence before we call it proven."

## Act 3 — Scale and govern

Goal: move from one demo to a reusable customer motion without changing the technical spine.

| Scene | Time | Show / do | Built assets to map to | Speaker notes / key phrases | Marker |
|---|---:|---|---|---|---|
| 3.1 Spine + skin model | 4 min | Show both `config\demo-skin.json` files and dummy-customer examples. Explain what changes per customer. | `C:\src\arc-demo\docs\reskin-guide.md`, `C:\src\sre-agent\docs\reskin-guide.md` | "The spine is the Azure build and click-path. The skin is customer name, estate mix, prefix, toggles, labels, and repo context." | Built / locally validated |
| 3.2 Two-repo separation | 3 min | Point to `arc-demo` standalone README/runsheet and optional `sre-agent` scenario docs. | `C:\src\arc-demo\README.md`; `C:\src\sre-agent\README.md` | "We can deliver Arc/Monitor alone, then add SRE only when the customer is ready." | Built / locally validated |
| 3.3 Same-tenant-new-subscription lab | 2 min | Explain subscription pattern: clean subscription, same tenant, runtime IDs, no private values in docs. | `arc-demo` README prerequisites; `scripts\Deploy-ArcDemo.ps1`; `scripts\Deploy-SreAgent.ps1` | "Make the lab easy to reset and safe to share. Keep customer-specific IDs out of source." | Built guidance |
| 3.4 Approval gates, RBAC, audit | 3 min | Show Low/High access profiles and Review-mode stance. Explain production hardening. | `sre-agent` README; `docs\t10-sre-on-arc-experiment.md` required RBAC | "Scale depends on trust: least privilege, explicit approval, Activity Log, SRE thread, and no unattended risky changes." | Built design; live proof pending |
| 3.5 OCIO / customer reuse | 2 min | Close with DTF as poster child, reusable across OCIO agencies and other hybrid-estate customers. | Reskin guides and this runsheet | "Same spine, new skin: prove once, retarget repeatedly." | Positioning |
| 3.6 Optional EDE PoC placeholder | 1 min | Mention only as a placeholder for a later packaged engagement. Do not pull or quote the datasheet in T13. | T14 backlog item only | "There is a separate PoC packaging workstream to fill in later; today is the technical storyboard." | Deferred; do not start T14 |

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
| T11 LOB-on-Arc bridge | `C:\src\sre-agent\docs\t11-lob-app-on-arc-bridge.md` |
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
```

Only include reset commands for scenarios you actually induced. Capture SRE threads, alert history, Activity Log entries, and KQL snippets before resetting.

## Remaining live-validation gaps

- T09: capture one full Container App alert -> SRE investigation -> Review approval -> repair -> audit trail.
- T10: complete the experiment matrix and decide whether any Arc-server remediation beat is demo-ready.
- T11: publish the LOB sample as its own repo, verify Application event ingestion, create the alert, and capture SRE RCA/remediation evidence.
- Act 1: before customer delivery, refresh live portal screenshots/queries after deployment because Monitor, Defender, Policy, and Update Manager blades have ingestion delays.
