# T11 - LOB-app-on-Arc bridge package

## Current status

**Live validation complete for SRE-assisted diagnosis and operator Arc recovery.**
The LOB app was deployed on `win-app-01`, emitted a real Application Event fault,
triggered an Azure Monitor scheduled-query alert, and opened an SRE Agent incident.
SRE produced a useful RCA and proposed Arc Run Command remediation. The SRE action
execution path remained partial: one generated command was too long, and the
shorter follow-up produced a blank action result and did not change the guest
state. The operator helper then reset the app through Arc Run Command and verified
healthy heartbeats. Present this as a proven hybrid RCA bridge with manual/operator
Arc Run Command recovery, not as a fully closed-loop SRE remediation.

Default prefix, target machine, LOB app labels, and code-context repository values
come from `config\demo-skin.json` when scripts are run with `-SkinPath`; see
[`reskin-guide.md`](reskin-guide.md).

## Bridge architecture

```text
samples/lob-arc-app source repo
  -> deployed by scripts/Invoke-LobArcAppOnArc.ps1
  -> Windows Arc server from arc-demo, default win-app-01
  -> Application log source ArcLobBridgeApp + text log under C:\ProgramData\ArcSreLobApp
  -> Log Analytics Event table through arc-demo AMA/DCR
  -> scheduled-query alert routed to ag-arc-demo
  -> SRE Agent AzMonitor incident source + connected app code repository
```

This is intentionally different from the earlier tasks:

- **T09** is the Azure-native "wow" loop: Container App crash/restart alert,
  cloud resource remediation, and code context from the cloud workload.
- **T10** is a server-only Arc experiment: service/disk/CPU/heartbeat faults on
  the Arc machine, with no first-class app repository.
- **T11** bridges both: an app with its own GitHub/code context runs **on** the
  Arc server, so the alert is on the hybrid estate while the RCA can cite app code.

## App source and code context

The sample app lives in `samples\lob-arc-app`. For the final customer demo, publish
that folder as a separate GitHub repository, for example `lob-arc-app-demo`, and
connect that repository in the SRE Agent portal:

1. Open the SRE Agent.
2. Go to **Builder** > **Knowledge base**.
3. Add the LOB app repository, not `arc-demo`.
4. Deploy with `-SourceRepositoryUrl`, `-SourceCommit`, and `-SourcePath` so those
   values appear in the emitted Application events.

The 2026-10-12 lab run stamped events with `corey-skapin/sre-agent-demo` at commit
`5e09e53d3ddf4305590b86d6f2389b5aa6e137af`. The SRE Agent could not read the private
GitHub repo directly, but it still correlated the event payload, Arc Run Command
history, config path, scheduled task, and fault mode well enough to produce RCA.

The app reads `C:\ProgramData\ArcSreLobApp\appsettings.json`:

| Fault mode | Behavior | Signal |
|---|---|---|
| `Healthy` | Periodic business heartbeat | Event ID `4000` Information |
| `Degraded` | Warning events, task keeps running | Event ID `4200` Warning |
| `CrashOnProcessing` | Error event and process exit code 42 | Event ID `4100` Error and stopped task |

## Prerequisites

- `arc-demo` deployed with a Monitor-supported Windows Arc server. Use `win-app-01`
  first; it is WS2016/full-monitor in the default fleet.
- Existing SRE Agent from this repo in Review mode with Azure Monitor incidents.
- Azure CLI signed in to the lab tenant/subscription.
- Azure CLI `connectedmachine` extension available.
- Target Arc Connected Machine agent supports Run command.
- The target machine's AMA/DCR collects Windows Application events into the
  Log Analytics `Event` table. If this is not visible in the lab, update the
  arc-demo DCR before claiming the signal path.

## 1. Resolve target resource IDs

```powershell
$subscriptionId = '<SUBSCRIPTION_ID>'
$tenantId = '<TENANT_ID>'
$namePrefix = 'arc-demo'
$machineName = 'win-app-01'

$targetArcId = az connectedmachine show `
  --resource-group rg-arc-demo `
  --name $machineName `
  --query id `
  --output tsv
```

Deploy or update the SRE Agent with the target Arc machine in scope:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($targetArcId)
```

`High` assigns broad Contributor in the lab; keep the response plan in Review mode.
For production-style hardening, reduce this to Reader + Log Analytics Reader +
Arc Run command permissions.

## 2. Deploy and start the LOB app on the Arc server

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -Action Deploy `
  -SourceCommit '<commit-sha>'
```

Useful operations:

```powershell
# Status / evidence
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId -MachineName $machineName -Action Status

# Stop and start without changing config
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId -MachineName $machineName -Action Stop
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId -MachineName $machineName -Action Start

# Manual fallback: create the guest script for copy/paste into an elevated session
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -MachineName $machineName `
  -Action Deploy `
  -GuestScriptOutputPath .\lob-arc-app-deploy.guest.ps1
```

## 3. Create the Azure Monitor signal

Preview the query:

```powershell
.\scripts\New-LobArcAppMonitorAlert.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -Action ShowQuery
```

Core KQL:

```kql
Event
| where TimeGenerated > ago(10m)
| where EventLog =~ "Application"
| where Source == "ArcLobBridgeApp"
| where EventID in (4100, 4101, 4200)
| where Computer =~ "win-app-01" or _ResourceId has "/machines/win-app-01"
| project TimeGenerated, Computer, EventLog, Source, EventID, EventLevelName, RenderedDescription, _ResourceId
```

Create the scheduled-query alert routed to the existing arc-demo Action Group:

```powershell
.\scripts\New-LobArcAppMonitorAlert.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -Action Create
```

Then add the alert resource ID to the SRE Agent managed resources on the next
SRE deployment/update, or at minimum ensure the response plan matches Azure Monitor
alerts whose title contains `lob-arc-app-fault`.

## 4. Induce and reset the app fault

Induce a crash:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -MachineName $machineName `
  -Action InduceFault `
  -FaultMode CrashOnProcessing
```

Expected signal:

- `ArcLobBridgeApp` Application Error event ID `4100`.
- Log Analytics `Event` row within the ingestion window.
- Scheduled-query alert fires and routes through `ag-arc-demo`.
- SRE Agent opens an Azure Monitor incident and can inspect the Arc machine,
  Log Analytics evidence, and the connected LOB app code repository.

Reset:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -MachineName $machineName `
  -Action ResetFault
```

Collect logs/events:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -MachineName $machineName `
  -Action CollectLogs
```

## 5. SRE Agent response plan

In the SRE Agent portal:

1. Open `sre-arc-demo`.
2. Create or update an Azure Monitor response plan.
3. Match alert title contains `lob-arc-app-fault`.
4. Set severity `Sev2`.
5. Keep autonomy level **Review**.
6. Confirm the LOB app GitHub repository is connected in the knowledge base.

Desired investigation evidence:

- Incident source is Azure Monitor.
- Alert query names `ArcLobBridgeApp` and `win-app-01`.
- The affected Azure resource is an Arc machine
  (`Microsoft.HybridCompute/machines`), not a native Container App.
- RCA cites `LobArcBridgeApp.ps1` and the `CrashOnProcessing` branch.
- Any proposed remediation is governed and limited to resetting the app config to
  `FaultMode=Healthy` and restarting the scheduled task via Arc Run command.

## Evidence capture checklist

| Evidence | Captured? | Notes |
|---|---:|---|
| LOB app source published as separate repo | Partial | Source stayed in `corey-skapin/sre-agent-demo`; publish `samples\lob-arc-app` separately or connect the private repo before customer delivery. |
| SRE Agent knowledge base connected to LOB app repo | No | SRE could not access the private GitHub repo; event/run-command context still enabled RCA. |
| Target Arc machine ID added to SRE Agent managed resources | Yes | `win-app-01` was in SRE scope through the `rg-arc-demo`/managed-resource configuration. |
| App deployed on `win-app-01` with repository/commit stamped | Yes | Deploy run command `t11-lob-deploy-1012021324`; events stamped repo, commit `5e09e53d3ddf4305590b86d6f2389b5aa6e137af`, and source path. |
| Healthy Application event/log heartbeat visible | Yes | Healthy Event ID `4000` heartbeats observed before fault and after reset. |
| Scheduled-query alert created and routed to `ag-arc-demo` | Yes | Created through `New-LobArcAppMonitorAlert.ps1` ARM REST path; alert name `alert-arc-demo-lob-arc-app-fault`. |
| `CrashOnProcessing` induced | Yes | Fault event Event ID `4100`, incident `t11-20261012022201`, generated from `win-app-01`. |
| Log Analytics `Event` row observed | Yes | SRE RCA cited the 2026-10-12 `ArcLobBridgeApp` Error row from Log Analytics. |
| SRE Agent incident opened | Yes | Thread `b2e5a213-b4ed-45c2-a3c1-28bd7f2d653f` opened from Azure Monitor alert ID `fa2d5357-846b-ee76-c972-4745ac76001f`. |
| RCA cites Arc machine + app code context | Yes | RCA identified `win-app-01`, Connected Machine agent 1.68, Windows Server 2016, `ArcSreLobApp`, config path, `CrashOnProcessing`, commit, and source path. |
| Review-mode remediation proposed/executed | Partial | SRE proposed Arc Run Command reset. First generated command was too long; shorter follow-up returned a blank action result and did not reset the app. |
| Reset verified healthy | Yes | Operator helper run command `t11-lob-resetfault-1012025040` set `FaultMode=Healthy`; status `t11-lob-status-1012025316` showed task Running, process alive, and healthy Event ID `4000` heartbeats. |

## Limitations and remaining work

- The helper uses scheduled tasks rather than installing a Windows Service, avoiding
  third-party service wrappers. If a customer requires a real Windows Service,
  port the worker to a .NET Worker Service before the live demo.
- Application-log collection depends on the existing arc-demo DCR. This worked in
  the 2026-10-12 lab, but re-verify the `Event` table after every clean deployment.
- SRE remediation through Arc Run Command is still partial. The demo-ready claim is
  SRE-assisted RCA plus operator-approved/manual Arc Run Command recovery unless
  a later run captures a successful SRE-executed Arc command.
- Connect or publish the LOB app repo before using this as a code-context demo.
- Keep `arc-demo` standalone: no files in `C:\src\arc-demo` are changed for T11.

## Local validation completed for this package

- PowerShell parser checks for the sample app and T11 helper scripts.
- `az bicep build --file .\infra\main.bicep --stdout`.
- `git diff --check`.
