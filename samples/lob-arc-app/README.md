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

For the live demo, use the public copy in
`https://github.com/corey-skapin/arc-demo/tree/main/samples/lob-arc-app` and
optionally connect the `arc-demo` repository to the SRE Agent knowledge base
only after explicit authentication/consent. A public URL stamped into events is
not connector authorization, and source citation is not required for the current
T11 signal-plus-operator-recovery claim. The deploy helper stamps repository URL,
commit and source path into app config/events. This is not evidence of reliable
T11 SRE RCA or SRE-executed Arc repair.
