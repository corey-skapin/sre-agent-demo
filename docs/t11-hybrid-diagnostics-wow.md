# T11 hybrid diagnostics wow - LOB app on Arc

**Optional story/operator reference.** The
[SRE guide source](delivery-runsheet.md) contains the short read-only scene;
present from the generated `.local/presenter-runsheet.md`. It requires no command below.
Historical evidence here does not certify a newly reconstructed SRE instance.

## Purpose

This is the customer-facing Arc/on-prem SRE moment.

T09 proves full Azure-native closed-loop remediation. T11 proves the hybrid value:
an on-prem-shaped line-of-business app running on an Arc-enabled Windows server can
enter Azure Monitor and produce a safe operator recovery path without RDP, war
rooms, or tribal knowledge. In the latest live run, SRE incident creation worked
but SRE RCA generation stalled, so treat the RCA as the quality bar rather than a
reliable live claim.

Do **not** sell this as autonomous Arc server repair. The wow is assisted
diagnosis and governed operator action.

## Three-minute setup story

Use this setup before touching the portal:

> A customer has a line-of-business order-processing app running on a Windows
> server in the datacenter. The server is Arc-enabled, so Azure sees the machine,
> policy posture, logs, and alerts. At 2 AM, order processing starts failing. In
> the old world, the first hour is figuring out which server, which logs, who owns
> the app, and what changed. In this demo, Azure Monitor catches the application
> event from the Arc server and opens an SRE incident. The event/log evidence
> gives the operator a clear recovery action through Arc Run Command; final SRE
> RCA is not yet a reliable live claim.

Key line:

> We are not claiming the agent autonomously repairs on-prem servers. We are
> showing that Arc and Azure Monitor make hybrid diagnostics dramatically better,
> and that the operator can act through Azure instead of logging into the server.

## What to show

| Step | Show | Message |
|---|---|---|
| 1 | Arc server `win-app-01` | The affected machine is a `Microsoft.HybridCompute/machines` resource, not a native app service. |
| 2 | LOB app code context | Local sample: `samples/lob-arc-app/LobArcBridgeApp.ps1`; external source context is optional and operator-supplied. |
| 3 | Existing, dated fault evidence if available | Explain that `FaultMode=CrashOnProcessing` creates sample Event ID `4100` from `ArcLobBridgeApp`; do not induce it during the ordinary walkthrough. |
| 4 | Azure Monitor alert | Alert title contains `lob-arc-app-fault`; source is Log Analytics `Event`. |
| 5 | SRE Agent thread | A historical instance created an incident, but final T11 RCA stalled. A missing current thread is an evidence limit, not permission to generate a new one. |
| 6 | Operator recovery | Arc Run Command resets app config to `Healthy` and restarts the scheduled task. |
| 7 | Verification | Event ID `4000` healthy heartbeat returns. |

## Optional operator rehearsal commands, not presenter actions

Assumes `arc-demo` and `sre-agent` are deployed and the SRE response plan is ready.
These are separately authorized guest/config/fault writes, not read-only
preflight. Use a bounded recovery owner; prefer captured evidence unless the
specific new fault/reset window is approved.
Even `-Action Status` executes an Arc guest Run Command. For a read-only
navigation rehearsal use existing workspace events and recorded results instead.

```powershell
# Run from the SRE checkout.
$subscriptionId = '<SUBSCRIPTION_ID>'
$tenantId = '<TENANT_ID>'

# Deploy the LOB app to the Arc Windows server.
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -MachineName win-app-01 `
  -Action Deploy

# Create or verify the Azure Monitor scheduled-query alert.
.\scripts\New-LobArcAppMonitorAlert.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -Action Create

# Induce the customer incident.
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -MachineName win-app-01 `
  -Action InduceFault `
  -FaultMode CrashOnProcessing
```

Wait for the Azure Monitor alert. If the SRE response plan is configured and
fires, use the SRE Agent thread as supporting evidence. If the SRE handler stalls,
use Log Analytics plus the operator recovery command as the main stage.

Reset only after capturing the alert/evidence, and after the SRE thread if it
produces useful output:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -MachineName win-app-01 `
  -Action ResetFault
```

Verify:

```powershell
.\scripts\Invoke-LobArcAppOnArc.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -SkinPath .\config\demo-skin.json `
  -MachineName win-app-01 `
  -Action Status
```

Expected reset evidence:

- `FaultMode=Healthy`
- task running
- process running
- recent Event ID `4000` heartbeat

## RCA excerpt to aim for

Use this as the quality bar for the SRE response. The exact wording will vary:

> The alert was generated by `ArcLobBridgeApp` on Arc-enabled machine
> `win-app-01`. The Application event shows a fatal order-processing fault with
> `FaultMode=CrashOnProcessing`. The app is deployed as scheduled task
> `ArcSreLobApp` and reads configuration from
> `C:\ProgramData\ArcSreLobApp\appsettings.json`. The source context points to
> `samples/lob-arc-app/LobArcBridgeApp.ps1`, where `CrashOnProcessing` writes
> Event ID 4100 and exits with code 42. Recommended operator action: use Arc Run
> Command to set `FaultMode=Healthy`, reset `IncidentId`, and restart the task.

If SRE does not produce the RCA, use the event payload and run-command history as
the proven evidence, and state that response-plan RCA reliability is still being
hardened.

## Recovery line

Say:

> The operator performs the authorized recovery through Arc Run Command. The
> important point is not that the agent magically repairs a datacenter server. The
> important point is that the incident moved from an opaque server problem to a
> precise diagnosis and governed Azure-side action.

Do not say:

> SRE Agent autonomously repaired the on-prem server.

## Fallback storyboard

If automatic SRE handoff does not fire during the meeting:

1. Show the fault event in Log Analytics.
2. Show the T11 evidence table in `t11-lob-app-on-arc-bridge.md`.
3. Open the prior SRE thread evidence if available.
4. Run `Status`; use `ResetFault` only for the authorized, actually induced fault.
5. State that the response-plan route is the part being troubleshot, not the Arc
   diagnostic model.

## Evidence checklist

Current customer-ready claim is signal plus operator recovery. To expand the
claim to reliable SRE RCA later, capture:

| Evidence | Required |
|---|---|
| Public source connected | Optional for current claim; useful when hardening RCA quality. |
| App deployed | `Invoke-LobArcAppOnArc.ps1 -Action Deploy` succeeds. |
| Fault induced | Event ID `4100` from `ArcLobBridgeApp`. |
| Alert fired | Azure Monitor alert title contains `lob-arc-app-fault`. |
| SRE RCA | Future quality bar: thread identifies Arc machine, fault mode, config path, source path, and recovery action. Latest live run stalled before this. |
| Operator recovery | `ResetFault` returns app to `Healthy`. |
| Healthy heartbeat | Event ID `4000` observed after reset. |
