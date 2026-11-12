# Act 4: it works when nothing is broken

Three scheduled tasks give the agent work to do while nothing is broken: an estate
health check, a drift scan that compares the ticketing web app with what the Bicep
declares and grades each difference, and a governance deck built as a PowerPoint.
A small helper puts three harmless drifts on the web app so the scan has something
to find, and puts them back. Present from the generated
`.local/presenter-runsheet.md` ([how](ai-deploy-handbook.md#your-presenter-guide));
this page is the setup, the commands and the limits. Ask your AI tool to run the
commands, or follow them yourself.

## What it does

Two custom agents hold the work. Neither has an Azure write tool or a GitHub tool.
Every task is in Review mode and **Paused**: nothing runs until you run it or resume
its schedule. (The platform starts every new task Active whatever the create call
says, so the apply pauses each task it creates.)

| Task | Agent | Schedule when Active (UTC) | What it reports |
|---|---|---|---|
| `estate-health-check` | `estate-auditor` | `0 8 * * 1-5` | One verdict per area (Healthy, Degraded, Down, Parked or Unknown) with the query behind it: the ticketing web app and its checkout success rate, the two alert rules (exactly one should be enabled), the Arc estate (Parked when every VM is deallocated) and, with T09, the Container App |
| `bicep-drift-scan` | `estate-auditor` | `30 8 * * 1-5` | Each difference between the live ticketing workload and its Bicep, graded Benign, Risky or Critical, with the revert it proposes and did not run |
| `governance-deck` | `deck-builder` | `0 9 * * 1` | A six-slide PowerPoint: access, network exposure, tag coverage, how the agent itself is governed, and three recommendations. If it can't build the file it gives the same slides as Markdown |

The drift scan checks the web app's tags, FTP state, minimum TLS version, HTTPS-only
setting, always-on setting and health-check path, the plan's SKU and capacity, and
the two alert rules. It doesn't compare app settings such as
`WEBSITE_RUN_FROM_PACKAGE`, because a release changes those on purpose.

## Turn it on

Add `PROACTIVE` to `sre.requiredScenarios` in your private skin. It also needs
`T12`: the health check and the drift scan read the ticketing workload, and the skin
check refuses `PROACTIVE` without it. There is nothing else to fill in. Then:

- On a new build, `Deploy-SreAgent.ps1` applies it. The two agents come first, then
  the skills, then the three tasks, all before the GitHub repository stage that waits
  for your sign-in.
- On an agent that is already up, preview with
  `Initialize-SreConfiguration.ps1 -Inspect`, then apply with a new `-BackupPath`
  outside the repository. The acts stage writes its own backup beside it, named
  `<your path>.acts.json`. Nothing is deleted, and a task that exists keeps whatever
  Active or Paused setting it has.

`Test-SreReadiness.ps1 -DesiredState Active` then has two required rows,
`ACTS-skills` and `ACTS-tasks` (every task present, current and in Review mode), and
an informational row, `ACTS-schedules`, that shows each task as Paused or Active. Add
`PROACTIVE` to the `acts` list in your presenter context to put the act in your
guide. No grant or GitHub permission changes: the agents use the identity's
existing read access.

## Run the tasks

```powershell
.\scripts\Invoke-ScheduledTask.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Status
```

`Status` shows each task as Paused or Active, its schedule, how many times it has run,
when it last ran and runs next (a paused task shows "not scheduled"), and its mode.
To run one now, add `-Action Run -Name <task>`:

```powershell
.\scripts\Invoke-ScheduledTask.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Run -Name estate-health-check
```

It starts one agent thread and prints its ID; the agent runs a paused task without
resuming it, and the task stays paused. Add `-Wait` to follow the thread until
the agent is idle (15 minutes at most, or set `-TimeoutMinutes`). Nothing waits for
a click, because neither agent has a write tool. Open the thread in the SRE portal to
read the result. `-WhatIf` shows what Run, Enable or Disable would do.

To resume or pause a schedule, use `-Action Enable` (resume) or `-Action Disable`
(pause) with `-Name`. A schedule that is Active starts agent threads by itself, and
each one spends AAUs, so pause it again when you're done. The apply never changes
this setting after a task exists.

To change a task's schedule, edit the `cron:` line in its file under `config\acts\proactive\tasks\` (UTC, five fields) and run the apply again; it updates the schedule and leaves the task's Paused or Active state alone. Put the original back afterwards.

If a future platform version refuses to run a paused task, run `-Action Enable`, then
`-Action Run`, then `-Action Disable`. The script says so when the call fails.

## The drift demo

`Invoke-DriftDemo.ps1` puts three small drifts on the ticketing web app with your
own credentials, so the drift scan finds one of each grade:

| Drift | Declared | Start sets | Grade |
|---|---|---|---|
| Two extra tags, `manual_update` and `changed_by` | The deploy tags only | Both tags | Benign |
| FTP state | `Disabled` | `FtpsOnly` | Risky |
| HTTPS only | `true` | `false` | Critical |

Start takes about 50 seconds and Reset about 45. The web app kept answering: baseline
traffic began 14 seconds after a Reset and its first 27 checkouts all returned 200.
Nobody sent traffic during the drift itself, so "no restart" is not proven. The agent
never makes this change or reverts it.

```powershell
.\scripts\Invoke-DriftDemo.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin -Action Start
```

`-Action Status` shows the three settings, declared against observed. `-Action Reset`
removes exactly those two tags, sets the FTP state back to `Disabled` and turns HTTPS
only back on. Use `-WhatIf` on Start or Reset first. The script refuses to change a
web app that doesn't carry the tag `sreScenario=T12`, which is how it knows
`Deploy-TicketingWorkload.ps1` created it. If you added a tag of your own, Reset
leaves it alone and reports that the app still differs: remove your tag or ignore
the message.

Reset the drift after the scan, so the next run starts from the declared state.

## The governance deck

The deck builder gathers facts read-only, then runs Python with `python-pptx` to
build the file and saves it in the thread's files. To fetch it, take the thread ID
that Run printed:

```powershell
.\scripts\Export-SreAgentFiles.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Source Thread -ThreadId <thread ID> -OutputPath <a new folder outside the repository>
```

On the live agent the deck took 2 minutes 42 seconds, `python-pptx` 1.0.2 was
already in the sandbox, and the download took 22 seconds: a 36,596-byte file that
starts with `PK`, opens as a zip and holds six slides (Governance review, Posture,
Findings, How this agent is governed, Recommendations, and a closing slide). The
agent says it checked the file opens but didn't render it, so look at it before you
present it: a long table can wrap. The script warns when a downloaded `.pptx` doesn't
start like a zip file. If there is no file, the deck builder reports the same slides
as Markdown in the thread.

## What you can and can't claim

- **Say "read-only by design", not "it can't change anything".** The two agents
  have no Azure write tool and no GitHub tool, and their instructions say never to
  change anything. But the deck builder runs Python, and Review mode governs the
  Azure write tool, not Python. What holds is the instructions and the agent's
  grants. The deck builder's instructions forbid calling Azure from Python,
  installing packages and reading credentials.
- **The grades are the agent's judgement.** Benign, Risky and Critical follow the
  table in the drift-scan skill, against what the repository's Bicep declares. They
  aren't a compliance verdict, and a check the agent couldn't read is reported as
  unknown, not as no drift.
- **You ran them.** The tasks are Paused. If you ran them by hand, say so: "these are
  scheduled tasks; I ran them a few minutes ago." Don't say it ran by itself unless
  you resumed a schedule and it fired.
- **A parked Arc estate reads Parked.** That's the right answer, not a failure. The
  health check found all eight VMs deallocated and the nine Arc machines
  Disconnected, and said so without calling it a fault.
- **The agent proposes, a person decides.** The drift scan prints the revert and
  marks it "proposed, not run". Its last slide says nothing in the deck was changed.

## Keep it out of the incident story

- The T12 Stop hook checks the closing summary of an investigation. Its prompt says
  that scheduled reports, drift scans, governance reports, deck notes and estate
  answers aren't investigation summaries. Measured: the hook ran after each of the
  three task threads and allowed all three (about 1.3 to 1.5 seconds each).
- Don't ask a task to create a GitHub issue. An agent-created issue body over about
  4,000 escaped characters gets no approval card
  ([T12](t12-friday-release.md#troubleshooting)), and these tasks hold no GitHub
  tool anyway.
- A scheduled thread that fires while a Friday release incident is running is a
  second thread on the same agent. Run the tasks before the incident, not during
  it, so you can tell their threads from the incident's in the portal.
- A task thread runs without a signed-in person, so it never waits for an
  authorization. The same questions asked in a chat can
  ([Act 1](ask-anything.md#questions-that-name-people)).
- **The health check reports the last 24 hours.** After a Friday release run it says
  so plainly: on 2026-11-11 it reported the app healthy now, with 1,011 failed
  checkouts in the last 24 hours (59.6% success), all on v1.3.0, and three resolved
  alerts still Acknowledged. That's the release you just showed, not a fault; say it
  before the audience asks, or run this act before the incident.

## Time and cost

Nothing here adds a resource or a second parent: the tasks live on the agent and go
away with it. Applying the configuration again recreates them Paused. The parent bills
4 AAUs per hour from creation until deletion, plus active work
([cost reference](sre-cost-and-demo-fidelity.md#acts-1-3-and-4-ask-remember-and-scheduled-work)).
Each run is one agent thread of active work whose AAUs can't be read back. If you
resumed all three schedules, that would be 11 threads a week (five health checks,
five drift scans and one deck). One run each took: the health check 1 minute 45
seconds, the drift scan 1 minute 30 seconds and the deck 2 minutes 42 seconds, with
the drift scan finding all three drifts.

## Troubleshooting

| You see | Cause and fix |
|---|---|
| `Invoke-ScheduledTask.ps1` says the skin doesn't turn on `PROACTIVE` | Add `PROACTIVE` (and `T12`) to `sre.requiredScenarios`, then apply |
| Status says a task is "not on the agent" | The apply hasn't run since you turned the module on. Run `Initialize-SreConfiguration.ps1 -Apply` |
| Status says a task is Active and you didn't resume it | An older copy of the scripts created it: the platform starts new tasks Active. Run `-Action Disable -Name <task>` |
| Run fails and the message says the task is Paused | The platform refused a paused task, which it didn't do when measured. Enable it, run it, then disable it again (above) |
| Run says the thread wasn't named in the answer | Look in the SRE portal under the agent's threads for the newest one |
| The drift scan reports no drift | Start the drift first: `Invoke-DriftDemo.ps1 -Action Start`. If you did, check `-Action Status` and that the scan ran after it |
| The drift scan reports drift you didn't make | The web app really differs from the Bicep. Read the table, then decide: that's the finding |
| `Invoke-DriftDemo.ps1` says the web app doesn't carry `sreScenario=T12` | It isn't the workload `Deploy-TicketingWorkload.ps1` created. Nothing was changed |
| The deck download warns it doesn't start like a PowerPoint file | The file API may have returned text. Ask the agent for the Markdown version of the deck |
| The deck builder says python-pptx isn't available | Expected if the sandbox lacks it. It writes the slides as Markdown and says the deck wasn't built |

## What is proven and what isn't

Proven live (2026-11-10 and 2026-11-11), on a build from zero:

- Tasks are created over REST in Review mode. The platform ignores `isEnabled` and
  starts each new task **Active**; `POST /api/v1/scheduledtasks/{id}/pause` pauses it
  (HTTP 200) and `/resume` resumes it. A PUT on a paused task keeps it paused.
- The cron time zone is UTC: `0 8 * * 1-5` gave a next run of 08:00:00Z.
- Run now works on a paused task (HTTP 200 in under 2 seconds, one thread, the task
  stays paused). The thread's first message is `[SCHEDULED_TASK_EXECUTION]` and its
  caller is "no interactive caller".
- All three tasks ran to a useful report, the Stop hook allowed all three, and the
  drift scan found exactly the three drifts, graded Critical, Risky and Benign, with
  the revert it proposed and did not run.
- The health check's first run looked for the VMs in the Arc group and had to find
  them by another route; the skill now says they are in the infrastructure group, and
  a second run (2 minutes 31 seconds) read all eight there and reported the estate
  Parked.
- `ExecutePythonCode` is accepted as a tool name, `python-pptx` 1.0.2 is importable,
  and the binary `.pptx` downloads through the file API intact.
- `Invoke-DriftDemo.ps1` Start and Reset on the real web app.

Written offline and covered by tests against a fake agent, but **not run live yet**:

- The apply pausing a task it has just created (the same pause call was made by hand
  and worked). The next build from zero proves it: `Status` should show all three
  Paused right after the build.
- A task firing by itself at its cron time (nobody waited for one).
- The `ACTS-schedules` row for a task that is Active, and what a run costs in AAUs.
- Whether the three drift changes restart the web app (no traffic ran during them).
