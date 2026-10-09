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

For the live demo, publish this folder as its own GitHub repository (for example
`lob-arc-app-demo`) and connect that repository to the SRE Agent knowledge base.
The deploy helper stamps the repository URL, commit, and source path into the
app config and event messages so an SRE investigation has code context that is
separate from both `arc-demo` and `sre-agent`.
