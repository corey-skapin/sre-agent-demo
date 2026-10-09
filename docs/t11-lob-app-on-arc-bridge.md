# T11 - LOB-app-on-Arc bridge package

## Current status

**Live validation pending.** This package provides the app source, Arc Run command
operator script, Azure Monitor alert definition helper, SRE Agent setup steps, and
evidence checklist for a line-of-business app running on an Arc-enabled Windows
server. It does **not** claim a live SRE Agent investigation or remediation until
the lab is run and evidence is captured.

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

The sample app lives in `samples\lob-arc-app`. For a live SRE demo, publish that
folder as a separate GitHub repository, for example `lob-arc-app-demo`, and connect
that repository in the SRE Agent portal:

1. Open the SRE Agent.
2. Go to **Builder** > **Knowledge base**.
3. Add the LOB app repository, not `arc-demo`.
4. Deploy with `-SourceRepositoryUrl`, `-SourceCommit`, and `-SourcePath` so those
   values appear in the emitted Application events.

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
  -NamePrefix $namePrefix `
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
  -NamePrefix $namePrefix `
  -MachineName $machineName `
  -Action Deploy `
  -SourceRepositoryUrl 'https://github.com/<org>/lob-arc-app-demo' `
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
  -NamePrefix $namePrefix `
  -MachineName $machineName `
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
  -NamePrefix $namePrefix `
  -MachineName $machineName `
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
| LOB app source published as separate repo | No | Pending live lab |
| SRE Agent knowledge base connected to LOB app repo | No | Pending live lab |
| Target Arc machine ID added to SRE Agent managed resources | No | Pending live lab |
| App deployed on `win-app-01` with repository/commit stamped | No | Pending live lab |
| Healthy Application event/log heartbeat visible | No | Pending live lab |
| Scheduled-query alert created and routed to `ag-arc-demo` | No | Pending live lab |
| `CrashOnProcessing` induced | No | Pending live lab |
| Log Analytics `Event` row observed | No | Pending live lab |
| SRE Agent incident opened | No | Pending live lab |
| RCA cites Arc machine + app code context | No | Pending live lab |
| Review-mode remediation proposed/executed | No | Pending live lab |
| Reset verified healthy | No | Pending live lab |

## Limitations and pending validation

- No live Azure/SRE portal run was performed while authoring this package.
- The helper uses scheduled tasks rather than installing a Windows Service, avoiding
  third-party service wrappers. If a customer requires a real Windows Service,
  port the worker to a .NET Worker Service before the live demo.
- Application-log collection depends on the existing arc-demo DCR. Verify the
  `Event` table before using this as the incident trigger.
- SRE remediation through Arc Run command remains governed and unverified until a
  Review-mode action is observed in the lab.
- Keep `arc-demo` standalone: no files in `C:\src\arc-demo` are changed for T11.

## Local validation completed for this package

- PowerShell parser checks for the sample app and T11 helper scripts.
- `az bicep build --file .\infra\main.bicep --stdout`.
- `git diff --check`.
