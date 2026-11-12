# T11: LOB app on an Arc server

A small PowerShell line-of-business app runs on a Windows Arc server from
`arc-demo` (`win-app-01` by default). Break it and it writes an Application event,
Azure Monitor raises an alert and the SRE agent opens an incident. In Review mode
the agent investigates and recommends; you recover the app yourself through Arc
Run Command. Present the SRE scene from `.local/presenter-runsheet.md`. This page
is the how-to for the app, its alert and its faults.

Every guest action below, including `Status`, runs an Arc Run Command on the
server, so none of them is a read-only check.

## What it shows

- A fault in an on-prem-shaped app reaches Azure Monitor, creates an SRE incident,
  and you recover it from Azure instead of logging on to the server.
- It does not show the agent repairing an Arc server, and a reliable automatic SRE
  RCA is not proven. An earlier crash run stalled before the final RCA. A later
  bounded warning run completed five queries and a final investigation, but it
  read stale evidence as an ongoing warning and ruled out host pressure from
  sparse counters too confidently. The handler instructions were tightened
  afterwards (evidence age, ingestion lag, "not observed in the available
  counters" instead of "ruled out") and that change hasn't been re-run live.
  Treat SRE-executed Arc repair as a possible future capability. The optional `ARC`
  module ([Act 6](arc-server-room.md)) builds that path on this setup, as one Review
  card you approve; it hasn't run live end to end.

## How it fits together

```text
samples/lob-arc-app source
  -> deployed by scripts/Invoke-LobArcAppOnArc.ps1
  -> Windows Arc server from arc-demo, default win-app-01
  -> Application log source ArcLobBridgeApp + text log under C:\ProgramData\ArcSreLobApp
  -> Log Analytics Event table through arc-demo AMA/DCR
  -> scheduled-query alert routed to ag-arc-demo
  -> SRE Agent AzMonitor incident source (+ optional code repository)
```

T09 is the Azure-native loop: a Container App in Azure, repaired through Azure.
T11 runs on an Arc server, so the alert is on the hybrid estate while the RCA can
cite the app's code.

## App source and code context

The sample source is `samples\lob-arc-app\LobArcBridgeApp.ps1`. Its fault modes
(`Healthy`, `Degraded`, `CrashOnProcessing`) and event IDs are in
[its README](../samples/lob-arc-app/README.md). External repository URL and commit
are empty by default. To connect your own repository to the agent:

1. Open the SRE Agent.
2. The [source-code connection guide](https://learn.microsoft.com/azure/sre-agent/connect-source-code)
   documents **Builder** > **Knowledge base** > **Add repository** for an existing
   agent. Authenticated controls were not observed; use the visible documented
   layout, not a guessed menu.
3. Add your own repository URL.
4. Deploy with `-SourceRepositoryUrl`, `-SourceCommit` and `-SourcePath` so those
   values appear in the emitted Application events.

A public URL in an event is not connector authentication, and neither the
connection nor a source citation is needed for the signal-plus-recovery scene.

| Field | Value |
|---|---|
| Repository | Empty, or your HTTPS repository URL. |
| Commit | Empty with no repository; otherwise the matching revision. |
| Source path | `samples/lob-arc-app/LobArcBridgeApp.ps1` |

## Prerequisites

- `arc-demo` deployed with a Monitor-supported Windows Arc server. Use `win-app-01`
  first; it is Windows Server 2016 with full monitoring in the default fleet.
- The SRE agent from this repo, in Review mode with Azure Monitor incidents. The
  complete build already puts the target machine in scope through the skin's
  `sre.targetArcMachine`; the README shows the parent-only route for custom names.
- Azure CLI signed in to the right tenant and subscription, with the
  `connectedmachine` extension.
- A Connected Machine agent that supports Run command.
- The machine's AMA/DCR collecting Windows Application events into the Log
  Analytics `Event` table. If you don't see them, update the arc-demo DCR first.

Guest deployment, fault and reset commands need an active Arc target. Don't run
them as part of a read-only readiness check, and don't run them while the Arc
estate is parked.

## 1. Deploy and start the app

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -Action Deploy
```

The default local-sample path needs no external source. If you want source
context, pass `-SourceRepositoryUrl` and `-SourceCommit` together, with the
optional `-SourcePath`; a commit alone is not valid.

Other actions (`win-app-01` is the default target; pass `-MachineName` to use
another machine):

```powershell
# Status and evidence
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> -MachineName win-app-01 -Action Status

# Stop and start without changing config
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> -MachineName win-app-01 -Action Stop
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> -MachineName win-app-01 -Action Start

# Manual fallback: write the guest script to run in an elevated session on the server
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Action Deploy `
  -GuestScriptOutputPath .\lob-arc-app-deploy.guest.ps1
```

`-Action WarnForDuration` runs a short warning-only incident without restarting
the app; see [the handbook](ai-deploy-handbook.md#host-context-and-an-optional-bounded-lob-warning).

## 2. Create the Azure Monitor alert

Preview the query:

```powershell
.\scripts\New-LobArcAppMonitorAlert.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
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

Create the scheduled-query alert, routed to the existing arc-demo Action Group:

```powershell
.\scripts\New-LobArcAppMonitorAlert.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json `
  -Action Create
```

Then check that the alert is in the agent's managed-resource scope and that the v3
AzMonitor filter matches the literal `lob-arc-app-fault` and Sev2, is enabled and
routes to the custom handler in Review. A title match alone doesn't prove access or
end-to-end readiness.

## 3. Break and reset the app

Crash the app:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Action InduceFault `
  -FaultMode CrashOnProcessing
```

What you should see:

- An `ArcLobBridgeApp` Application Error event with ID `4100`.
- A Log Analytics `Event` row within the ingestion window.
- The scheduled-query alert fires and routes through `ag-arc-demo`.
- The SRE agent opens an Azure Monitor incident. Arc and Log Analytics evidence
  supports your diagnosis; code inspection also needs a connected repository.

Reset, then collect logs and events:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> -MachineName win-app-01 -Action ResetFault
.\scripts\Invoke-LobArcAppOnArc.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> -MachineName win-app-01 -Action CollectLogs
```

A healthy reset shows `FaultMode=Healthy`, the task running, the process alive and
Event ID `4000` heartbeats again.

## 4. Check the response plan

Use the initializer in
[the response-plan reference](sre-response-plan-automation.md) to converge and read
back the existing `lob-arc-app-review-v3` filter rather than creating a duplicate.
In the SRE portal, look (don't edit):

1. Open `sre-arc-demo`.
2. Open the `lob-arc-app-review-v3` Azure Monitor route.
3. The alert title contains `lob-arc-app-fault`.
4. Severity is `Sev2`.
5. Autonomy is **Review**.
6. The custom handling agent holds the instructions and tools, with no
   response-level fields and no competing enabled v2 route.

A good RCA for this incident would show that the incident source is Azure Monitor,
the alert query names `ArcLobBridgeApp` and `win-app-01`, the affected resource is
an Arc machine (`Microsoft.HybridCompute/machines`), and, with code connected, it
cites `LobArcBridgeApp.ps1` and the `CrashOnProcessing` branch. The only
remediation it should propose is resetting the app config to `FaultMode=Healthy`
and restarting the scheduled task through Arc Run Command, which you run. That is
the aim, not a promise: not all of it is reliable yet. With the `ARC` module on, the
agent proposes that recovery itself as a Review card you approve
([Act 6](arc-server-room.md)).

## Limits

- The helper uses a scheduled task, not a Windows Service, to avoid third-party
  service wrappers. If you need a real Windows Service, port the worker to a .NET
  Worker Service first.
- Application-log collection depends on the arc-demo DCR. Re-check the `Event`
  table after every clean deployment.
- SRE RCA and remediation through Arc Run Command are still partial, so the
  scene is the Azure Monitor signal plus a recovery you run yourself.
- Keep `arc-demo` standalone: nothing in its checkout changes for T11.
