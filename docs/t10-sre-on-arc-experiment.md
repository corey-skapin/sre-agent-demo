# T10 - SRE-on-Arc experiment package

## Current status

**Live verdict: assisted diagnostics validated; autonomous repair not currently demo-ready.** This package is a reproducible experiment harness for measuring Azure SRE Agent value against `arc-demo` Arc-enabled servers. The current customer-safe claim is SRE-assisted diagnosis plus governed operator remediation through Arc Run Command. Do **not** present autonomous or SRE-executed Arc server repair as available in this demo; treat it only as a possible future capability.

Default prefix, region, access level, and target machine are read from
`config\demo-skin.json` when scripts are run with `-SkinPath`; see
[`reskin-guide.md`](reskin-guide.md).

References used for the harness:

- Azure Arc-enabled servers Run command (preview): <https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command>
- Arc VM extensions and ConnectedMachine CLI extension: <https://learn.microsoft.com/en-us/azure/azure-arc/servers/manage-vm-extensions-cli>
- Azure Monitor VM guest data and Heartbeat verification: <https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection>

## Goal

Empirically answer: **how much value does Azure SRE Agent deliver against on-premises-shaped Arc-enabled servers?**

The answer must separate:

1. What SRE Agent can investigate from Azure Monitor / ARM / Log Analytics.
2. What a human/operator can remediate through Azure RBAC and `Microsoft.HybridCompute/machines/runCommands`.
3. What only works because `arc-demo` uses backing Azure VMs, not because real on-premises servers are directly power-controllable.
4. What fails or requires a human.

## Hypotheses to test

| ID | Hypothesis | Required proof |
|---|---|---|
| H1 | SRE Agent can ingest Azure Monitor incidents for Arc-enabled servers and correlate Heartbeat, Event, Perf, and Arc ARM metadata. | Agent incident transcript includes the target `Microsoft.HybridCompute/machines` resource, Log Analytics evidence, and a plausible RCA. |
| H2 | SRE Agent can propose or describe an Arc Run Command remediation for guest-level faults such as a stopped Windows service or cleanup of an induced disk-pressure file. | The proposed operator action is safe, bounded, and succeeds when replayed manually through the helper or Azure CLI. |
| H3 | For the `arc-demo` missed-heartbeat fault, SRE Agent may suggest starting the backing Azure VM, but that is a lab-only capability. | Agent identifies the backing VM path or correctly labels real on-prem power recovery as manual/hypervisor action. |
| H4 | For legacy/control-plane-only Arc servers without AMA, SRE Agent value is limited to inventory/governance metadata unless another telemetry source is added. | Agent cannot use Heartbeat/Perf/Event evidence for those machines and states the telemetry gap. |

## Prerequisites

- `arc-demo` deployed from `C:\src\arc-demo` with default or equivalent Arc fleet.
- `sre-agent` deployed from this repo with:
  - `accessLevel=High` for the first experiment run.
  - `incidentManagementConfiguration.type = AzMonitor`.
  - Review mode enabled.
  - The target Arc machine resource ID passed through `-AdditionalManagedResourceIds` when deploying the agent.
- Azure CLI signed in to the lab tenant/subscription.
- Azure CLI `connectedmachine` extension available:

  ```powershell
  az extension add --name connectedmachine
  ```

- Target Arc server Connected Machine agent version supports Run command. Microsoft docs state Run command is built into Connected Machine agent version 1.33+.
- Wait windows:
  - Heartbeat alert: `alert-arc-demo-host-missing-heartbeat` evaluates every 5 minutes over a 15-minute window and fires when latest heartbeat is older than 10 minutes.
  - Log/Perf data: allow at least 5 minutes for Monitor ingestion.

## Required RBAC

Use least privilege for production-style validation, but the current T08 `High` profile assigns Contributor at the `arc-demo` Arc and infra resource-group scopes.

| Capability | Minimum permission / role to validate |
|---|---|
| Read Arc machine and alert metadata | Reader on `rg-arc-demo`. |
| Query Log Analytics | Log Analytics Reader on the workspace. |
| Run command on Arc server | `Microsoft.HybridCompute/machines/runCommands/read` and `Microsoft.HybridCompute/machines/runCommands/write`; built-in **Azure Connected Machine Resource Administrator** includes this. |
| Start/deallocate backing Azure VM in the lab | VM Contributor or Contributor on `rg-arc-demo-infra`. |
| SRE Agent governed actions | SRE Agent action identity has the relevant scope; SRE Agent remains in Review mode for human approval. |

## Target Arc server selection

Start with `win-app-01`:

- Default `arc-demo` fleet member.
- Windows Server 2016 tier with full Azure Monitor support in the demo.
- Non-SQL app role, so service and disk experiments avoid SQL-specific side effects.
- Backing Azure VM name matches the Arc machine name in `rg-arc-demo-infra`.

Secondary targets:

- `win-app-02` or `win-app-03` for repeat Windows tests.
- `lnx-app-01` only after adapting guest scripts to Linux shell commands.

Avoid for first run:

- `win-sql-01` / `win-sql-02` unless validating SQL-specific evidence.
- Any `represent-not-run` or pre-2016 control-plane-only machine for Monitor-based scenarios.

## Safety boundaries

- Run only in the `arc-demo` lab subscription/resource groups.
- Keep SRE Agent in **Review** mode; do not enable or imply unattended Arc server remediation.
- Do not stop `azcmagent`, AMA, networking, firewall, or RDP/SSH access during the first pass. If those are needed later, require console/hypervisor access and a reset plan first.
- `HeartbeatByBackingVm` deallocates the backing Azure VM and is safe only because `arc-demo` simulates on-prem servers with Azure VMs.
- `StopService` defaults to `Spooler`, not a business-critical service.
- `DiskPressure` creates one bounded marker file under `C:\ProgramData\ArcSreT10` and refuses to reduce free space below the configured floor.
- `CpuPressure` starts a bounded-duration local worker and records its PID for reset.
- Every induced fault must be reset before hibernating or handing off the lab.

## Deploy SRE Agent with the target machine in scope

```powershell
$targetArcId = az connectedmachine show `
  --resource-group rg-arc-demo `
  --name win-app-01 `
  --query id `
  -o tsv

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -AdditionalManagedResourceIds $targetArcId
```

## Baseline evidence queries

Run before inducing a fault.

```kql
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastHeartbeat=max(TimeGenerated) by Computer, OSType
| order by Computer asc
```

```kql
Perf
| where TimeGenerated > ago(30m)
| where Computer =~ "win-app-01"
| summarize AvgValue=avg(CounterValue) by ObjectName, CounterName, InstanceName, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

```kql
Event
| where TimeGenerated > ago(2h)
| where Computer =~ "win-app-01"
| project TimeGenerated, Computer, EventLog, Source, EventID, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

## Fault scenarios and helper commands

Helper script:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario <SCENARIO> `
  -Action <Induce|Reset|Status>
```

### Scenario A - missed heartbeat / deallocated backing VM

Purpose: validate the existing `alert-arc-demo-host-missing-heartbeat` path and whether SRE Agent treats the Arc machine as the incident resource.

Induce:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario HeartbeatByBackingVm `
  -Action Induce
```

Reset:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario HeartbeatByBackingVm `
  -Action Reset
```

Expected evidence:

- Heartbeat stops for `win-app-01`.
- Alert fires after the configured evaluation window.
- SRE Agent can investigate the alert and show latest heartbeat.
- Remediation verdict must distinguish:
  - Lab: start backing Azure VM.
  - Real on-prem: human/hypervisor/power/network action.

### Scenario B - stopped Windows service via operator Arc Run command

Purpose: test guest-level operator action through `Microsoft.HybridCompute/machines/runCommands`.

Induce:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario StopService `
  -ServiceName Spooler `
  -Action Induce
```

Reset:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario StopService `
  -ServiceName Spooler `
  -Action Reset
```

Expected evidence:

- Run command output shows service stopped/started.
- Windows System/Application events may appear depending on DCR filters and service behavior.
- SRE Agent should help diagnose and suggest the operator Arc Run Command path. The demo claim is not that SRE executes this repair autonomously.

### Scenario C - disk-pressure Perf signal

Purpose: test whether SRE Agent can reason over Perf counter movement and suggest cleanup through operator Arc Run Command.

Induce:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario DiskPressure `
  -DiskFileSizeMB 512 `
  -MinimumFreeGB 5 `
  -Action Induce
```

Reset:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario DiskPressure `
  -Action Reset
```

Expected evidence:

- Marker file exists at `C:\ProgramData\ArcSreT10\t10-disk-pressure.bin`.
- Perf `LogicalDisk(_Total)\% Free Space` moves after ingestion.
- No default alert exists for this in `arc-demo`; create a temporary alert or use manual SRE prompt if needed.

### Scenario D - bounded CPU/log signal

Purpose: produce a visible Perf/Event trail without breaking the host.

Induce CPU:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario CpuPressure `
  -CpuDurationSeconds 300 `
  -Action Induce
```

Write error event:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario WriteEvent `
  -Action Induce
```

Reset CPU:

```powershell
.\scripts\Invoke-T10ArcFault.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -MachineName win-app-01 `
  -Scenario CpuPressure `
  -Action Reset
```

Expected evidence:

- CPU Perf counter rises during the configured window.
- Application event with source `T10ArcFault` appears if event source creation succeeds.
- Any autonomous SRE remediation claim remains out of scope for the current demo.

## Success criteria

An Arc-server **assisted diagnostics + operator remediation** beat is demo-ready only if all of these are true:

1. Azure Monitor produces a real incident visible to SRE Agent.
2. SRE Agent names the Arc machine and cites useful ARM/Log Analytics evidence.
3. SRE Agent proposes or describes a safe action that maps to `az connectedmachine run-command` or another governed Azure action.
4. The operator action succeeds when replayed manually through the helper or Azure CLI.
5. Reset returns Heartbeat/Perf/Event state to healthy.
6. Evidence is captured in the matrix below.

## Failure criteria

Mark the assisted Arc scenario **not demo-ready** if any of these occur:

- SRE Agent cannot see the Azure Monitor incident.
- SRE Agent treats the Arc machine only as inert metadata and cannot inspect relevant logs/metrics.
- Operator Run Command execution fails because of missing Connected Machine agent capability, RBAC, local blocklist, or network egress.
- The remediation depends on `arc-demo` backing Azure VM power control and cannot be explained honestly for real on-prem servers.
- Reset is not reliable.

## Experiment matrix template

| Scenario | Alert / prompt source | Agent can investigate? | Evidence used by agent | Proposed remediation | Remediation mechanism | Executed? | Result | Human/manual required | Verdict | Evidence link |
|---|---|---|---|---|---|---|---|---|---|---|
| HeartbeatByBackingVm | `alert-arc-demo-host-missing-heartbeat` | Pending live run | Pending | Pending | Lab: `az vm start`; real on-prem: manual/hypervisor | Pending | Pending | Pending | Pending | Pending |
| StopService | Manual prompt or temporary log alert | Pending live run | Pending | Pending | `az connectedmachine run-command create --script "Start-Service ..."` | Pending | Pending | Pending | Pending | Pending |
| DiskPressure | Manual prompt or temporary Perf alert | Pending live run | Pending | Pending | `az connectedmachine run-command create --script "Remove-Item ..."` | Pending | Pending | Pending | Pending | Pending |
| CpuPressure / WriteEvent | Manual prompt or temporary Perf/Event alert | Pending live run | Pending | Pending | Stop PID / inspect event via Run command | Pending | Pending | Pending | Pending | Pending |
| Legacy/control-plane-only server | Manual prompt | Pending live run | Arc tags/ARG only expected | Pending | Likely manual/no Monitor remediation | Pending | Pending | Likely yes | Pending | Pending |

## Evidence template

Copy one block per run:

```text
Run ID:
Date/time:
Subscription / tenant:
SRE Agent resource:
Agent access level:
Target Arc machine:
Target OS / monitorTier tags:
Scenario:
Fault command:
Reset command:
Azure Monitor alert ID / time:
Relevant KQL evidence:
SRE Agent incident URL or transcript:
Agent RCA summary:
Agent proposed action:
Action approved/executed:
Execution output:
Reset verification:
Verdict:
Follow-up:
```

## Live-verdict status

Status as of 2026-10-10:

- SRE Agent `sre-arc-demo` was redeployed with `accessLevel=High`.
- `win-app-01` was used as the target Arc server.
- Arc Run Command successfully executed against `win-app-01` for `WriteEvent`.
- Guest-local evidence was confirmed through Arc Run Command:
  - Event `1010` / Provider `T10ArcFault` / Level `Error`
  - Reset marker event `1011` / Provider `T10ArcFault` / Level `Information`
- SRE Agent manual investigation thread `49acabac-7d88-402f-895f-d774085e985e`
  started and attempted evidence collection, but tool result messages were often
  blank and no final RCA was produced without repeated prompting.

Current verdict:

| Area | Verdict |
|---|---|
| Arc Run Command as a remediation/investigation mechanism | **Works** from the lab using `Microsoft.HybridCompute/machines/runCommands` |
| SRE Agent can target the Arc machine resource in a manual investigation | **Works** - it accepts the Arc resource and produces a useful RCA when given the Arc Run Command evidence |
| SRE Agent produces a clean, evidence-backed Arc-server RCA automatically | **Partial** - the final RCA is good, but tool-result messages can be blank and Log Analytics Event/Heartbeat evidence was not available in this run |
| SRE Agent can execute Arc Run Command remediation | **Not yet** - it attempted the approved reset action, but EventID 1011 was not observed from the agent action; manual replay succeeded |
| Automatic Azure Monitor -> SRE incident handoff for Arc server alert | **Not yet validated** |

Customer-facing stance:

- **Say:** SRE Agent is useful for Arc/on-prem diagnostics and can guide an operator to safe Arc Run Command recovery.
- **Say:** Arc Run Command gives Azure-governed remote action for supported Arc machines.
- **Do not say:** SRE Agent autonomously repairs Arc servers.
- **Future-looking only:** autonomous Arc server repair may become possible later if a supported product path reliably executes and verifies Arc Run Command actions.

Live run evidence on 2026-10-12:

| Evidence | Result |
|---|---|
| Fault command | `t10-writeevent-induce-1012015102` |
| Fault output | `Wrote Application Error event source=T10ArcFault eventId=1010.` |
| SRE thread | `eb16884a-8769-4dfb-a471-235b7726ab92` |
| SRE RCA | Identified `win-app-01` as Connected/healthy and the event as deliberate fault injection; confirmed Arc Run Command is viable |
| Agent reset attempt | Agent attempted to execute reset via Arc Run Command, but no EventID 1011 was observed from the agent action |
| Manual reset command | `t10-writeevent-reset-1012020229` |
| Manual reset output | `Wrote reset marker event source=T10ArcFault eventId=1011.` |
| Final status command | `t10-writeevent-status-1012020520` confirmed EventID 1011 and prior EventID 1010 |

Remaining live work:

1. Configure/validate a real Arc-server Azure Monitor alert or incident response plan.
2. Keep T10 as SRE-assisted diagnosis with manual/operator-approved Arc Run Command
   replay. Track SRE-executed Arc repair as future investigation only.
3. Capture Log Analytics `Event`/`Heartbeat` evidence if ingestion and tool access are
   required for the final customer-facing run.
