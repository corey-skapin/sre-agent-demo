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
Every task is created in Review mode and **Off**: nothing runs until you run it or
turn its schedule on.

| Task | Agent | Schedule when On (UTC, assumed) | What it reports |
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
  On or Off setting it has.

`Test-SreReadiness.ps1 -DesiredState Active` then has two required rows,
`ACTS-skills` and `ACTS-tasks` (every task present, current and in Review mode), and
an informational row, `ACTS-schedules`, that shows each task as Off or On. Add
`PROACTIVE` to the `acts` list in your presenter context to put the act in your
guide. No grant or GitHub permission changes: the agents use the identity's
existing read access.

## Run the tasks

```powershell
.\scripts\Invoke-ScheduledTask.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Status
```

`Status` shows each task as Off or On, its schedule, how many times it has run, when
it last ran and runs next, and its mode. To run one now, add `-Action Run -Name <task>`:

```powershell
.\scripts\Invoke-ScheduledTask.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Run -Name estate-health-check
```

It starts one agent thread and prints its ID. Add `-Wait` to follow the thread until
the agent is idle (15 minutes at most, or set `-TimeoutMinutes`). Nothing waits for
a click, because neither agent has a write tool. Open the thread in the SRE portal to
read the result. `-WhatIf` shows what Run, Enable or Disable would do.

To turn a schedule on or off, use `-Action Enable` or `-Action Disable` with `-Name`.
A schedule that is On starts agent threads by itself, and each one spends AAUs, so
turn it off again when you're done. The apply never changes this setting after a task
exists.

If the agent refuses to run a task that is Off, run `-Action Enable`, then `-Action
Run`, then `-Action Disable`. The script says so when the call fails.

## The drift demo

`Invoke-DriftDemo.ps1` puts three small drifts on the ticketing web app with your
own credentials, so the drift scan finds one of each grade:

| Drift | Declared | Start sets | Grade |
|---|---|---|---|
| Two extra tags, `manual_update` and `changed_by` | The deploy tags only | Both tags | Benign |
| FTP state | `Disabled` | `FtpsOnly` | Risky |
| HTTPS only | `true` | `false` | Critical |

Nothing should restart, and the app should keep serving; that hasn't been confirmed
live yet. The agent never makes this change or reverts it.

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

Check the file before you present it. A PowerPoint file hasn't been downloaded
through the agent's file API yet, and that API may return it as text. The script
warns when a downloaded `.pptx` doesn't start like a zip file. If there is no file,
the deck builder reports the same slides as Markdown in the thread.

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
- **You ran them.** The tasks are Off. If you ran them by hand, say so: "these are
  scheduled tasks; I ran them a few minutes ago." Don't say it ran by itself unless
  you turned a schedule on and it fired.
- **A parked Arc estate reads Parked.** That's the right answer, not a failure.
- **The agent proposes, a person decides.** The drift scan prints the revert and
  marks it "proposed, not run". Its last slide says nothing in the deck was changed.

## Keep it out of the incident story

- The T12 Stop hook checks the closing summary of an investigation. Its prompt now
  says that scheduled reports, drift scans, governance reports, deck notes and
  estate answers aren't investigation summaries, so it should let them through. That
  wording hasn't been through a live scheduled run yet.
- Don't ask a task to create a GitHub issue. An agent-created issue body over about
  4,000 escaped characters gets no approval card
  ([T12](t12-friday-release.md#troubleshooting)), and these tasks hold no GitHub
  tool anyway.
- A scheduled thread that fires while a Friday release incident is running is a
  second thread on the same agent. Run the tasks before the incident, not during
  it, so you can tell their threads from the incident's in the portal.

## Time and cost

Nothing here adds a resource or a second parent: the tasks live on the agent and go
away with it. Applying the configuration again recreates them Off. The parent bills
4 AAUs per hour from creation until deletion, plus active work
([cost reference](sre-cost-and-demo-fidelity.md#acts-1-3-and-4-ask-remember-and-scheduled-work)).
Each run is one agent thread of active work whose AAUs can't be read back. If you
turned all three schedules on, that would be 11 threads a week (five health checks,
five drift scans and one deck). How long each task takes to finish isn't measured:
rehearse once and write your own numbers down.

## Troubleshooting

| You see | Cause and fix |
|---|---|
| `Invoke-ScheduledTask.ps1` says the skin doesn't turn on `PROACTIVE` | Add `PROACTIVE` (and `T12`) to `sre.requiredScenarios`, then apply |
| Status says a task is "not on the agent" | The apply hasn't run since you turned the module on. Run `Initialize-SreConfiguration.ps1 -Apply` |
| Run fails and the message says the task is Off | Enable it, run it, then disable it again (above) |
| Run says the thread wasn't named in the answer | Look in the SRE portal under the agent's threads for the newest one |
| The drift scan reports no drift | Start the drift first: `Invoke-DriftDemo.ps1 -Action Start`. If you did, check `-Action Status` and that the scan ran after it |
| The drift scan reports drift you didn't make | The web app really differs from the Bicep. Read the table, then decide: that's the finding |
| `Invoke-DriftDemo.ps1` says the web app doesn't carry `sreScenario=T12` | It isn't the workload `Deploy-TicketingWorkload.ps1` created. Nothing was changed |
| The deck download warns it doesn't start like a PowerPoint file | The file API may have returned text. Ask the agent for the Markdown version of the deck |
| The deck builder says python-pptx isn't available | Expected if the sandbox lacks it. It writes the slides as Markdown and says the deck wasn't built |

## What is proven and what isn't

Proven live (2026-11-10 and 2026-11-11): a scheduled task can be created over REST in
Review mode and run now; a task thread started that way ran with the agent's tools
and read the notes written by an earlier incident; and the Stop hook runs after
every reply and can reject one.

Written offline and covered by tests against a fake agent, but **not run live**:

- Creating the three tasks Off, and the platform honouring Off at create time.
- Run now on a task that is Off.
- The cron time zone (UTC is assumed) and the `ACTS-schedules` row for a task that
  is On.
- The two read-only agents' output: the verdict table, the drift grades, and the
  scan's result against the three live drifts.
- `Invoke-DriftDemo.ps1` on a real web app (it is tested with a mocked Azure CLI),
  including that the three changes don't restart the app.
- `ExecutePythonCode` as a tool name the platform accepts, `python-pptx` being
  importable in the sandbox, and downloading a binary `.pptx` through the file API.
- The Stop hook's exclusion for scheduled reports.
- How long each task takes, and what it costs.
