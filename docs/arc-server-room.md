# Act 6: the server room (Arc)

A Windows server on Arc runs the line-of-business app. You break the app on purpose.
The agent finds out from the alert, diagnoses it from Resource Graph and Log
Analytics, and proposes **one** repair as a Review card: a Run Command that runs a
repair script already installed on the server. A person approves it, the script runs
in about half a minute, and the agent checks that the app is back. Present from the
generated `.local/presenter-runsheet.md`
([how](ai-deploy-handbook.md#your-presenter-guide)); this page is the setup, the
commands, the guard story and the limits. Ask your AI tool to run the commands, or
follow them yourself.

The act reuses the T11 setup (the app on the Arc server, its alert and its response
plan) and adds only what is new: a skill, a repair script and a runner.

## What it does

| Step | Who | What happens |
|---|---|---|
| 1 | You | `Invoke-ArcServerRoom.ps1 -Action Start` sets the app's `FaultMode` to `CrashOnProcessing` (the T11 fault, under your credentials) |
| 2 | Azure Monitor | The LOB alert fires on event 4100 within about 5 to 10 minutes (it checks every 5 minutes over a 10-minute window) |
| 3 | The agent | It opens a thread, reads the server in Resource Graph, the app's events, the heartbeat and the host counters in Log Analytics, and lists the run commands already on the server |
| 4 | The agent | It proposes one `az rest` PUT of a run command that runs `Repair-LobApp.ps1` on the server. The platform shows a Review card with the exact URL and body |
| 5 | A person | Clicks **Approve** in the SRE portal ([the click path](t09-native-containerapp-closed-loop.md#7-approve-the-governed-fix) is the same as T09's) |
| 6 | The agent | Reads the run command back from the server's list of run commands (not by name: [a read seconds after the PUT stalls the thread](#limits)), reports its output line, checks the app's heartbeat in Log Analytics, and times the change from the run command's start time |
| 7 | You | `Invoke-ArcServerRoom.ps1 -Action Reset` puts the app back and removes the run commands the agent created |

The repair script sets `FaultMode` back to `Healthy` (keeping the old file as
`appsettings.json.bak`), restarts the app's scheduled task (ending a leftover worker of
the app's own script first, so the restart is not ignored) and prints one line such as
`was=CrashOnProcessing now=Healthy state=Running last=267009`. It changes nothing
when the app is already healthy, so approving a stale card is harmless. It is
installed on the server beforehand, so the card shows one short script path instead
of a screen of PowerShell, and the agent can only ask to run that file.

## Turn it on

Add `ARC` to `sre.requiredScenarios` in your private skin. It needs `T11` (the app,
the alert and the response plan) and `sre.accessLevel` set to `High`: the agent's
identity creates the run command with the Contributor role it already holds on the
Arc group, and the skin check refuses `ARC` without both. No grant, GitHub scope or
mode changes; every response plan stays in Review mode. Then:

- On a new build, `Deploy-SreAgent.ps1` applies it with the other modules. The skill
  is `arc-server-repair`; the handler gets one extra paragraph, and its governance
  line says the read-only rule for Windows has one exception, the Arc application
  recovery policy.
- The T11 response plan's cooldown goes **off**, as T12's is, so a second rehearsal
  opens a new thread instead of merging into a resolved one for three hours. Skins
  without `ARC` are unchanged, byte for byte.
- On an agent that is already up, preview with
  `Initialize-SreConfiguration.ps1 -Inspect`, then apply with a new `-BackupPath`
  outside the repository, as for the other modules.

`Test-SreReadiness.ps1 -DesiredState Active` covers the skill in `ACTS-skills`, the
plan settings in `plan-filters-handler`, and adds one informational row,
`ARC-repair-script`: it reads the install marker on the server and says whether the
script there is the one in this repo. Add `ARC` to the `acts` list in your presenter
context to put the act in your guide.

## Install the repair script

Once per estate, and again whenever `config/acts/arc/repair-lob-app.ps1` changes. It
needs the Arc estate awake and the LOB app already deployed (T11).

```powershell
.\scripts\Invoke-ArcServerRoom.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Prepare -WhatIf
```

Run it again without `-WhatIf`. It sends one Run Command under your own credentials
that writes `C:\ProgramData\ArcSreLobApp\Repair-LobApp.ps1` and prints the file's
SHA-256, then checks that the hash is the one this repo computes. The run command
`arc-repair-install` stays on the server as the marker that readiness and `Check`
read. The file is on the server's disk, so it survives parking and waking the
estate; rebuild the estate and you run `Prepare` again. The script assumes the T11
default app folder, `C:\ProgramData\ArcSreLobApp`. Measured on 2026-11-12: `Prepare`
took 166 seconds, the script ran for 4 of them (the Azure CLI waited about two minutes
after it had ended), and the server reported the hash this repo computes.

## Rehearse and run it

Check first. It only reads:

```powershell
.\scripts\Invoke-ArcServerRoom.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Check
```

It prints one row each for the server (Connected, and for how long), the repair
script, leftover run commands from an earlier run, the LOB alert rule and the other
Arc machines. A server that has been Connected for less than 30 minutes is pending:
a freshly woken estate looks silent for 15 to 20 minutes, so allow 30. Then break the
app and watch:

```powershell
.\scripts\Invoke-ArcServerRoom.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Start -ApproveFault

.\scripts\Invoke-ArcServerRoom.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Status -Wait
```

`Start` refuses without `-ApproveFault` (it fires a real alert and starts a real
investigation), needs the SRE agent ready and the repair script installed, and
records the run in `.local/arc-server-room/current.json`. `Status` records when each
milestone first happened (fault, alert, thread, card, repair, resolved) and, when a
card is pending, says whether its command is the allowed repair. It never approves
anything. `-Wait` keeps polling until a card is pending or `-TimeoutMinutes` passes.
If the agent's read of the run command is held for authorization, `Status` lists it
as an authorization card, says it is not the Approve card and stops waiting
([why](#limits)).
Start the fault about 15 minutes before the beat: the one run measured took 6 minutes
51 seconds from the fault to the card, and the alert's five-minute check can add up to
five more. Rehearse once.

When you're done:

```powershell
.\scripts\Invoke-ArcServerRoom.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Reset -WhatIf
```

Run it again without `-WhatIf`, and add `-DeleteThreads` to remove this run's
threads and any stale Approve card with them. Reset runs the T11 reset under your
credentials, then deletes the run commands whose names start with `sre-repair-lob-`.
It never deletes the install marker or the `t11-lob-` run commands. If you reset the
app yourself before approving, don't approve the old card afterwards (deny it or leave
it alone).

## The guard story

- **Review mode gates the write.** A run command is created by a PUT, and every
  Azure write the agent makes is a card that waits for a person. Two tests showed
  exactly one Approve card, and the Activity Log caller of the write was the agent's
  own identity, not the person who clicked, with no new grant.
- **The card is checkable.** It shows the URL and the body. `Status` checks them: one
  PUT, this server, a name that starts with `sre-repair-lob-`, the API version this
  repo uses, and a body that holds only the script path (an output or subscription
  option, or a JSON content-type header, doesn't change the verdict). Anything else, a different
  machine, a different script, an extra key, a body read from a file, or shell syntax
  it cannot read, is reported as **not** the allowed repair; don't relay an approval
  for it.
- **The skill and the handler narrow the scope.** One server, one app, one Run
  Command per incident, no secrets in it (anyone with Reader can read a run command
  and its output), and no delete, stop, restart or other guest command.
- **There is no deny rule for Arc, and the agent refused to delete the server
  twice.** This repo already denies `az group delete` and `az webapp delete` for T12.
  A rule for deleting an Arc machine would be the same kind of narrowing, but the
  pattern behaviour for `az rest --method delete` is not verified, so the act adds
  none. Asked in words to delete the server, and asked to run `az rest --method
  delete` on it, the agent refused both times in about 18 seconds with no card
  (2026-11-12, one run each). It said its Azure write tool does not allow delete or
  remove at all, which is its statement about its tool, not a rule this repo set: say
  "it refused twice", not "it can't", and ask again in your own rehearsal. If it ever
  raises a card for a delete, don't approve it, and add a deny rule then.

## What is proven and what is not

Measured on 2026-11-10 in a test of Run Command through the agent: the agent
listed the Arc machines with Resource Graph and ran the Perf, Event and Heartbeat
queries; its `az rest` PUT raised one Review card; the run command executed under the
agent's identity with its existing Contributor role; the script ended about 26
seconds after the click; a plain GET read the output back; and a read with `$expand`
was refused by the agent's read tool, so the skill never adds an expand option.

Measured on 2026-11-12, the whole act once (one fault, one run) on a build from zero
with the Arc estate awake for 40 minutes. From the fault: the alert fired at 3
minutes 46 seconds, the thread opened at 5 minutes 14 seconds and the Approve card was
pending at 6 minutes 51 seconds. The agent read the machine, the workspace, the run
commands on the server, the fault's own run command and the alert rule, then ran
Log Analytics queries (its summary queries failed with a generic error, and it said so
and switched to row-level queries). Its message gave the evidence with times in UTC,
what it inferred, a confidence, the gaps and the one change, and said that the change
waits for a person. The card showed exactly the skill's PUT, with the same URL, API
version, location and body (about 540 characters), so the agent reproduced it without
drift. A person clicked Approve after the card had waited 21 minutes 54 seconds
(they were away, so that is not a measurement of the demo). The PUT returned 3 seconds
later, the script started 20 seconds after the click and ran for 15 seconds, and the
run command reported `was=CrashOnProcessing now=Healthy state=Running last=267009`.
The app's start event reached Log Analytics 7 seconds into the script, then its
heartbeats once a minute. The Activity Log caller of the write was the agent's own
identity, not the person who clicked. The agent's closing summary came 4 minutes 15
seconds after the click (see the second card in [Limits](#limits)): it kept what it
observed apart from what it inferred, timed the recovery from the run command's start,
and said that the alert's resolution is no evidence the app was healthy.

The agent refused two requests to delete the server (above). A hand-sent PUT of the
same shape against the healthy app, before the agent was built, ran the installed
script by its path alone (no execution-policy or quoting problem) and exited 0 in 10
seconds.

Not measured yet, so treat it as a rehearsal item and not a demo claim:

- That the skill's list read-back (below) avoids the second card. It is tested
  offline only.
- What the thread does if nobody authorizes that second card.
- That a failure shows as a failed run command: the script succeeded every time.
- How long the act takes with a person at the screen and no second card: the one run
  had the click and the authorization 21 and 25 minutes after the card.
- That the T11 plan opens a new thread on a second fault with its cooldown off.
- That the Stop hook, if T12 is also on, accepts the Arc closing summary. The lean
  skin of the run had no T12, so there was no hook.
- That `Status` is enough to run the act from. It reads ARM, the alert, the thread and
  the run command, not Log Analytics, so its timeline has no "first 4100" row; the
  agent's own report carries the Log Analytics evidence.

## Park and wake

Nothing for this act lives on the parent except the skill, which comes back with the
other modules on the next `Deploy-SreAgent.ps1`. The repair script and the
`arc-repair-install` marker live on the Arc server, so they survive parking the agent
and parking and waking the estate; an estate you rebuild needs `Prepare` again. Run
`Reset` before you park if a run is in progress: parking deletes the parent and its
threads and cards, but the fault would stay in the app's config on the server and the
app would start broken when the estate wakes. Park SRE before Arc, as usual.

## Limits

- **A freshly woken estate looks silent.** The Windows servers' heartbeats arrive 15
  to 20 minutes late (back-filled with their original `TimeGenerated`), and `Check`
  flags a server that has been Connected for under 30 minutes. Judge "stopped
  reporting" by `TimeGenerated`, never by arrival. On 2026-11-12 Log Analytics had no
  Windows heartbeat 13 minutes after the wake began and had them by minute 21, but
  `Check` counts from the server's last Arc status change: one change about 5 minutes
  after the first Connected restarted its clock, so it passed at minute 40. Treat 30
  minutes as a floor you can cut short by looking at the Heartbeat table.
- **`sql-guest` was seen Disconnected.** It read Disconnected from 2026-11-10 for an
  unknown reason. On 2026-11-12 it was Connected again about 7 minutes after the wake
  (the wake starts it through its parent VM), but it has no Azure Monitor agent, so it
  never sends a heartbeat, and a question about silent servers can list it. `Check`
  lists every Arc machine that is not Connected; look before you take questions about
  the estate.
- **The LOB server is the target, not SQL.** `win-sql-01` has no Arc SQL instance
  because its extension failed, and raw SQL on port 1433 is blocked from the agent's
  sandbox.
- **Run commands accumulate.** Every T11 action and the install leave a run command
  on the server. Reset removes only the agent's.
- **A second card can stop the thread.** In the one run, the agent read the new run
  command by its name 4 seconds after the PUT. The run command doesn't exist for about
  20 seconds after the PUT returns, so ARM answered 404 (HCRP404), and the platform
  held that read as a card titled "Authorization required: please grant access to the
  requested Azure resources". The thread waited on it for 3 minutes 23 seconds, until
  a person authorized it, and that read ran as the person, not as the agent. It is not
  the Approve card, and it is the only step of the act that ran as a person. `Status`
  lists it as an authorization card and stops waiting. The skill now reads the list of
  run commands instead, which never answers 404 and carries each run command's
  instanceView (checked on the real server). That change is offline-tested and not yet
  run live, and nobody knows what the thread does if the card is left alone.
- **The alert is not a recovery signal.** The app logs one 4100 and then goes silent,
  so the alert cleared 24 minutes 48 seconds after the fault, 4 minutes before the
  repair ran, when that event left its 10-minute window. The agent said so. Say the
  recovery came from the run command's output and the app's heartbeats.
- **The app doesn't restart by itself.** Its task is set to restart it up to three
  times, but after the 4100 there was no restart: the heartbeats stopped for 29
  minutes until the repair. The skill says so.
- **Say "one Review card", never "it can't break anything".** Review mode and the
  checks above hold; the script is small and reversible, but it does restart the app.

## Cost

No resource, no second parent and no grant: the SRE parent costs 4 AAUs per
agent-hour from creation until deletion, plus active work ([the cost
reference](sre-cost-and-demo-fidelity.md)). The act needs the Arc estate awake, which
has its own cost in the Arc repository. Don't quote a price per run: the active-flow
AAUs of a run can't be read back.
