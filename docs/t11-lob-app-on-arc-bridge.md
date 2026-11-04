# T11 - LOB-app-on-Arc bridge package

**Engineering reference and historical evidence ledger, not the presenter path.**
Use the generated `.local/presenter-runsheet.md` for the SRE scene.
[The docs map](README.md) keeps this file outside that path; the optional
[hybrid talk track](t11-hybrid-diagnostics-wow.md) expands the story.
Guest operations here, including `Status`, execute Run Command and are not
navigation-only preparation.

The generated presenter guide now includes a bounded human-invoked SRE
investigation of existing LOB events and configured host Perf counters, with
suggested operator steps only. The expanded query and optional bounded Degraded
warning received a separately authorized rehearsal on 2026-11-02. Source handler
instructions cover 4200 and host context. The bounded warning restored config
without restarting the worker; no route, tool or access grant was changed.
This does not establish why the earlier automatic RCA stalled. The manual
presenter query still needs its own live completion evidence.

## Current status

**Live validation complete for Arc signal, Azure Monitor alerting, SRE incident
creation, and operator Arc recovery.**
The LOB app was deployed on `win-app-01`, emitted a real Application Event fault,
triggered an Azure Monitor scheduled-query alert, and opened an SRE Agent incident.
An earlier crash run showed the response-plan handler can stall before final RCA.
The 2026-11-02 bounded warning did complete five automatic KQL calls and a final
investigation, but incorrectly inferred an ongoing warning from stale evidence
and overconfidently excluded host pressure from sparse counters. Guest and LAW
evidence independently verified healthy recovery. See the
[current rehearsal ledger](sre-response-plan-automation.md#observed-lob-warning-and-reporting-limits).
Present hybrid evidence plus operator recovery, not a proven reliable SRE RCA,
fully closed-loop, or autonomous Arc remediation story. New evidence-age and
sparse-counter instructions are applied but await the coordinated step-7 live
test from merged main; this rehearsal did not include another LOB run.
Treat SRE-executed Arc app repair only as a possible future capability.

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
  -> SRE Agent AzMonitor incident source + optional explicitly authenticated code repository
```

This is intentionally different from the earlier tasks:

- **T09** is the Azure-native "wow" loop: Container App crash/restart alert,
  cloud resource remediation, and code context from the cloud workload.
- **T10** is a server-only Arc experiment: service/disk/CPU/heartbeat faults on
  the Arc machine, with no first-class app repository. It is positioned as assisted
  diagnostics plus operator remediation.
- **T11** bridges both: an app with its own GitHub/code context runs **on** the
  Arc server, so the alert is on the hybrid estate while the RCA can cite app code.

## App source and code context

The sample source is local at `samples\lob-arc-app\LobArcBridgeApp.ps1`.
External repository URL and commit are empty by default. Optionally publish your
own copy and connect that repository only after separate authentication/consent:

1. Open the SRE Agent.
2. The current [source-code connection guide](https://learn.microsoft.com/azure/sre-agent/connect-source-code)
   documents **Builder** > **Knowledge base** > **Add repository** for an existing
   agent. Authenticated controls were not observed in this review; use the
   visible documented layout, not a guessed menu.
3. Add your own authorized repository URL.
4. Deploy with `-SourceRepositoryUrl`, `-SourceCommit`, and `-SourcePath` so those
   values appear in the emitted Application events.

A public URL in an event is not connector authentication. Neither connection nor
source citation is required for the current signal-plus-operator-recovery claim.

Historical runs used operator-specific source context, which is not a handoff
default or proof of current access. Use the following configuration contract:

| Field | Value |
|---|---|
| Repository | Empty unless the operator supplies an authorized HTTPS repository URL. |
| Commit | Empty with no repository; otherwise supply the matching source revision. |
| Source path | `samples/lob-arc-app/LobArcBridgeApp.ps1` |

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
  --subscription $subscriptionId `
  --resource-group rg-arc-demo `
  --name $machineName `
  --query id `
  --output tsv
```

Deploy the SRE Agent with the target Arc machine in scope (first creation; an
existing parent is refused):

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -ParentOnly `
  -ApproveParentCreation `
  -AccessLevel High `
  -AdditionalManagedResourceIds @($targetArcId)
```

`High` assigns broad Contributor in the lab; keep the response plan in Review mode.
Parent-only is not complete setup: Inspect and apply approved current-schema
agent/v3 filters through `sre-response-plan-automation.md`, then read back routing.
Do not redeploy merely to inspect an already configured running demo.
For production-style hardening, reduce this to Reader + Log Analytics Reader +
Arc Run command permissions.

## 2. Deploy and start the LOB app on the Arc server

Guest deployment/fault/reset commands require separate authorization, an active
Arc target and a bounded recovery owner. Do not run them during read-only
readiness or as an unconditional hibernation step.

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -Action Deploy
```

The default local-sample path needs no external source. If separately authorized
source context is wanted, supply `-SourceRepositoryUrl` and `-SourceCommit`
together, with the optional `-SourcePath`; a commit alone is not valid context.

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

Verify the alert is in the intended managed-resource/access scope and that the
existing v3 AzMonitor filter matches literal `lob-arc-app-fault`/Sev2, is enabled
and routes to the intended custom handler in Review. A title match alone does not
prove access or end-to-end readiness.

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
- SRE Agent opens an Azure Monitor incident. Arc/Log Analytics evidence supports
  operator diagnosis; code inspection additionally depends on an authenticated
  optional connector. Reliable final SRE RCA is not yet proven.

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

Use the initializer in `sre-response-plan-automation.md` to converge and read back
the existing `lob-arc-app-review-v3` filter rather than create a duplicate.
In the SRE Agent portal, inspect:

1. Open `sre-arc-demo`.
2. Open the existing `lob-arc-app-review-v3` Azure Monitor route.
3. Match alert title contains `lob-arc-app-fault`.
4. Set severity `Sev2`.
5. Keep autonomy level **Review**.
6. Confirm the intended custom handling agent owns instructions/tools; no legacy
   response-level fields or competing enabled v2 route.
7. Inspect code knowledge only if separately connected and authorized.

Desired future RCA evidence (not all currently reliable):

- Incident source is Azure Monitor.
- Alert query names `ArcLobBridgeApp` and `win-app-01`.
- The affected Azure resource is an Arc machine
  (`Microsoft.HybridCompute/machines`), not a native Container App.
- RCA cites `LobArcBridgeApp.ps1` and the `CrashOnProcessing` branch.
- Any proposed remediation is governed and limited to resetting the app config to
  `FaultMode=Healthy` and restarting the scheduled task via operator Arc Run Command.

## Historical 2026-10-12 evidence ledger - not current readiness

| Evidence | Captured? | Notes |
|---|---:|---|
| LOB app source available to SRE code context | Historical only | Original repository/revision retained privately. Handoff uses the local sample and no external repository by default. |
| SRE Agent knowledge base connected to LOB app repo | Optional / not required for current claim | Supplied source context can be stamped into events. Repo knowledge can improve RCA, but the proven claim does not depend on source citation. |
| Target Arc machine ID added to SRE Agent managed resources | Yes | `win-app-01` was in SRE scope through the `rg-arc-demo`/managed-resource configuration. |
| App deployed on `win-app-01` with repository/commit stamped | Yes | Original run-command and source revision retained privately; events carried configured source context. |
| Healthy Application event/log heartbeat visible | Yes | Healthy Event ID `4000` heartbeats observed before fault and after reset. |
| Scheduled-query alert created and routed to `ag-arc-demo` | Yes | Created through `New-LobArcAppMonitorAlert.ps1` ARM REST path; alert name `alert-arc-demo-lob-arc-app-fault`. |
| `CrashOnProcessing` induced | Yes | Fault Event ID `4100` generated from the demo machine; original incident ID retained privately. |
| Log Analytics `Event` row observed | Yes | Event ID `4100` observed from `ArcLobBridgeApp` with repo, commit, source path, and incident ID in the payload. |
| SRE Agent incident opened | Yes | Historical thread and Azure Monitor alert IDs retained in private evidence. |
| RCA cites Arc machine + app code context | Not reliable yet | Earlier SRE output had useful details, but the latest response-plan run stalled before final RCA. Do not use this as a live demo claim. |
| Review-mode remediation proposed/executed | Partial | SRE proposed Arc Run Command reset. First generated command was too long; shorter follow-up returned a blank action result and did not reset the app. |
| Reset verified healthy | Yes | Operator helper set `FaultMode=Healthy`; status showed task Running, process alive and Event ID `4000` heartbeats. Original command IDs retained privately. |

## Limitations and remaining work

- The helper uses scheduled tasks rather than installing a Windows Service, avoiding
  third-party service wrappers. If a customer requires a real Windows Service,
  port the worker to a .NET Worker Service before the live demo.
- Application-log collection depends on the existing arc-demo DCR. This worked in
  the 2026-10-12 lab, but re-verify the `Event` table after every clean deployment.
- SRE RCA generation and remediation through Arc Run Command are still partial and
  are not part of the customer-facing demo claim. The demo-ready claim is Azure
  Monitor signal plus operator-approved/manual Arc Run Command recovery.
  SRE-executed Arc app repair is future investigation only.
- Connect your own authorized repository in the SRE Agent knowledge base
  only with separate explicit authentication/consent when hardening code-context RCA.
- Keep `arc-demo` standalone: no files in its checkout are changed for T11.

## Local validation completed for this package

- PowerShell parser checks for the sample app and T11 helper scripts.
- `az bicep build --file .\infra\main.bicep --stdout`.
- `git diff --check`.
