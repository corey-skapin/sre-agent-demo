# SRE demo: investigate, review, verify

Follow this guide from top to bottom. Setup fills the names and links into
`.local/presenter-runsheet.md`; open that local copy for the presentation.
Context recorded: **{{recordedAtUtc}}**. These saved links do not certify current health.

## 1. Pick up from Arc

{{arcStep}}

**Say:** "Arc gives the servers an Azure identity and monitoring. SRE Agent uses
those signals to investigate an incident and propose a controlled action."

This section takes about 15 minutes. Keep navigation read-only. The optional
live incident in step 6 requires its own approval.

## 2. Show the healthy Container App

Open [{{containerAppResourceIdName}}]({{containerAppResourceIdUrl}}), then open
[the application]({{applicationUrl}}). Show the page loading. In the resource,
check the serving revision and replicas in **Revisions and replicas**.
If the page is unhealthy, stop the live-ready claim and notify the operator.

**Say:** "This Azure Container App is the repair demonstration. The application
can simulate a crash, and the proposed repair resets that one flag."

The Container App runs in Azure. The LOB sample in step 5 runs on an Arc-enabled
Windows server. Keep those two workloads distinct.

## 3. Show the configured response

Open [{{agentName}}]({{agentUrl}}). Open the existing response plans using the
navigation visible in this portal. Current Learn describes
[Builder > Incident response plans](https://learn.microsoft.com/azure/sre-agent/response-plan);
if the deployed layout differs, use its visible response-plan list.

Inspect these existing entries without editing:

| Plan | Signal | Check |
| --- | --- | --- |
| {{containerResponsePlan}} | Container App restart alert | On, Azure Monitor, Sev2, Review, three-hour cooldown |
| {{lobResponsePlan}} | {{lobAlertTitleContains}} | On, Azure Monitor, Sev2, Review, three-hour cooldown |

Both use **{{agentName}}** as the handling agent. Open that agent's instructions
to show the narrow app reset and the operator-led Arc recovery boundary.

**Say:** "The response plan selects the alert and handling agent. Review asks a
human to approve Azure infrastructure operations. Resource permissions still
limit what the agent can access."

[Review applies to Azure infrastructure actions](https://learn.microsoft.com/azure/sre-agent/run-modes).
Only an SRE Agent Administrator can approve those actions. Do not approve a
card during this walkthrough or accept a request for additional permissions.

## 4. Walk through an existing investigation

In the agent's incident list, open an existing Container App incident if one is
available. Check its title and timestamp before describing it. Walk through
the alert, evidence, proposed reset and recorded execution result in that order.

**Say:** "A proposed command shows intent. The completed tool result and the
application health checks show what actually happened."

If there is no investigation, explain the same flow using the configured plan
and healthy app. Do not send a new chat message or create an incident just to
fill this view. Label any previous-run evidence with its actual date.

## 5. Show the LOB signal and action evidence

Open [{{logAnalyticsWorkspaceIdName}}]({{logAnalyticsWorkspaceIdUrl}}), select
**Logs**, switch to KQL mode if needed, and run:

```kusto
Event
| where TimeGenerated > ago(24h)
| where _ResourceId =~ "{{arcMachineResourceId}}"
| where Source == "{{lobEventSource}}"
| where EventID in (4000, 4100)
| project TimeGenerated, Computer, EventID, RenderedDescription
| top 20 by TimeGenerated desc
```

**Say:** "Event 4000 is the sample application's heartbeat. Event 4100 is its
simulated processing failure. Arc recovery uses an operator's governed Run
Command. The Container App is the SRE repair path."

Empty rows are an observation to disclose. Do not run guest commands or induce
a LOB failure to populate the query.

For an existing SRE execution, open
[{{applicationInsightsResourceIdName}}]({{applicationInsightsResourceIdUrl}}),
select **Logs**, and run:

```kusto
customEvents
| where timestamp > ago(24h)
| where name in ("AgentToolExecution", "AgentAzCliExecution", "ApprovalDecision")
| project timestamp, Event = name,
    Phase = tostring(customDimensions.EventType),
    Tool = tostring(customDimensions.ToolName),
    Thread = tostring(customDimensions.ThreadId)
| top 30 by timestamp desc
```

Match the actual incident/thread and command before attributing an action.
ToolStart alone does not establish completion; missing approval telemetry leaves
an audit limit. See [the audit reference](https://learn.microsoft.com/azure/sre-agent/audit-agent-actions).
Keep raw context and payloads off the projected screen.

## 6. Optional: one approved live incident

Skip this step unless the user has explicitly approved one Container App fault,
an observation deadline and the narrow reset fallback. The AI runs the
[existing T09 procedure]({{operatorGuideUrl}}); the presenter does not choose scripts.
The signed-in human approves only the current run's exact reset card.
Never approve a stale card after operator recovery.

After execution, verify the false fault flag, serving revision and HTTP 200.
Check the alert's Monitor condition separately from its workflow status.
Describe operator fallback as operator-assisted recovery if it was needed.

## 7. Close

Return to [the application]({{applicationUrl}}).

**Say:** "The sequence is signal, investigation, proposed action, human review
and verified recovery. This demo keeps the two workloads and their recovery
owners explicit."

Leave the requested Active demo running. Parking is a separately approved
[operator task]({{lifecycleGuideUrl}}), with SRE parked before Arc.
