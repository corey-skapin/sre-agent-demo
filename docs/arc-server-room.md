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
| 6 | The agent | Reads the run command back (plain GET, no `$expand`), reports its output line, checks the app's heartbeat in Log Analytics, and times the change from the run command's start time |
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
default app folder, `C:\ProgramData\ArcSreLobApp`.

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
Start the fault about 15 minutes before the beat (a budget, not a measurement; see
below) and rehearse once.

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
  Azure write the agent makes is a card that waits for a person. A test showed
  exactly one card, under the agent's own identity, with no new grant.
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
- **There is no deny rule for Arc.** This repo already denies `az group delete` and
  `az webapp delete` for T12. A rule for deleting an Arc machine would be the same
  kind of narrowing, but the pattern behaviour for `az rest --method delete` is not
  verified, and the Review card already gates it. So the act adds none. Check the
  claim in a rehearsal: ask the agent to delete the server and expect a refusal or a
  card that you don't approve. If it raises a card, add a deny rule then.

## What is proven and what is not

Measured on 2026-11-10 in a test of Run Command through the agent: the agent
listed the Arc machines with Resource Graph and ran the Perf, Event and Heartbeat
queries; its `az rest` PUT raised one Review card; the run command executed under the
agent's identity with its existing Contributor role; the script ended about 26
seconds after the click; a plain GET read the output back; and a read with `$expand`
was refused by the agent's read tool, so the skill says to use a plain GET.

Not measured yet, so treat it as a rehearsal item and not a demo claim:

- That the agent reproduces the body in the skill exactly, and that the card stays
  under the size limit. Parameters are stored JSON-escaped and a card was missing for
  bodies of about 4,000 escaped characters or more; the PUT here is about 540, and a
  test checks it stays under 2,500.
- That the repair script behaves on the real server: that a run command whose script
  text is only the path of an installed script runs that file under the Arc
  extension's PowerShell (execution policy, quoting), that a failure shows as a failed
  run command, and how long the whole act takes from the fault to the closing summary.
- That the T11 plan opens a new thread on a second fault with its cooldown off.
- That the Stop hook, if T12 is also on, accepts the Arc closing summary.
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

- **A freshly woken estate looks silent.** The Windows servers' heartbeats arrive
  15 to 20 minutes late (back-filled with their original `TimeGenerated`), and
  `Check` flags a server that has been Connected for under 30 minutes. Judge "stopped
  reporting" by `TimeGenerated`, never by arrival.
- **`sql-guest` was seen Disconnected.** It read Disconnected from 2026-11-10 for an
  unknown reason. `Check` lists every Arc machine that is not Connected; look before
  you take questions about the estate.
- **The LOB server is the target, not SQL.** `win-sql-01` has no Arc SQL instance
  because its extension failed, and raw SQL on port 1433 is blocked from the agent's
  sandbox.
- **Run commands accumulate.** Every T11 action and the install leave a run command
  on the server. Reset removes only the agent's.
- **Say "one Review card", never "it can't break anything".** Review mode and the
  checks above hold; the script is small and reversible, but it does restart the app.

## Cost

No resource, no second parent and no grant: the SRE parent costs 4 AAUs per
agent-hour from creation until deletion, plus active work ([the cost
reference](sre-cost-and-demo-fidelity.md)). The act needs the Arc estate awake, which
has its own cost in the Arc repository. Don't quote a price per run: the active-flow
AAUs of a run can't be read back.
