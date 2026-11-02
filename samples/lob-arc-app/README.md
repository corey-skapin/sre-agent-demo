# LOB Arc bridge sample app

This tiny PowerShell worker is the T11 sample line-of-business app. It is designed
to run on a Windows Arc-enabled server from `arc-demo` and emit Monitor-friendly
Application events.

## Fault modes

The runtime reads `C:\ProgramData\ArcSreLobApp\appsettings.json`:

| FaultMode | Behavior | Monitor signal |
|---|---|---|
| `Healthy` | Writes periodic heartbeat events and text logs. | Event ID `4000` Information |
| `Degraded` | Writes warning events but keeps running. | Event ID `4200` Warning |
| `CrashOnProcessing` | Writes an error event and exits with code 42. | Event ID `4100` Error plus stopped scheduled task |

For a separately approved warning-only incident, the existing
`Invoke-LobArcAppOnArc.ps1 -Action WarnForDuration` helper temporarily selects
Degraded on an already healthy/running worker, without restarting it or generating
CPU/memory/disk load. Preview with `-WhatIf`; execution requires
`-ApproveWarningWindow` and the explicit approved target. Default duration is
120 seconds, maximum 180. It checks local 4200 evidence and restores its own
config in `finally`. Cleanup is not guaranteed after process termination or
concurrent config edits; operator inspection/recovery remains separately scoped.
See [the operator preparation](../../docs/ai-deploy-handbook.md#host-context-and-an-optional-bounded-lob-warning).
The original InduceFault/ResetFault actions restart the task and remain distinct.

For the live demo, use the local sample in this folder. External repository URL
and commit are empty by default in both skins and `source-context.example.json`.
Optionally supply your own HTTPS repository URL and commit together, then connect
that repository to the SRE Agent knowledge base
only after explicit authentication/consent. A public URL stamped into events is
not connector authorization, and source citation is not required for the current
T11 signal-plus-operator-recovery claim. The deploy helper stamps the supplied
repository URL, commit and source path into app config/events; absent URL/commit
are explicitly reported as not configured. This is not evidence of reliable
T11 SRE RCA or SRE-executed Arc repair.
