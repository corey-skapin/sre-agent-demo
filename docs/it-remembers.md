# Act 3: it remembers

The agent keeps notes between threads, and a later investigation reads what an
earlier one taught it. This module does two things: it seeds a short, hand-written
overview of your estate into the agent's notes when you build it, and it lets you
carry the agent's own notes across a rebuild. Present from the generated
`.local/presenter-runsheet.md` ([how](ai-deploy-handbook.md#your-presenter-guide));
this page is the setup, the warm-up flow and the limits. Ask your AI tool to run the
commands, or follow them yourself.

## What it does

1. **The seed.** When the notes folder is empty, the apply puts `overview.md` in it:
   about 1,500 characters naming your groups, the apps, the release URL pattern and
   the habits you want the agent to keep. Microsoft documents that the agent loads
   `overview.md` into its prompt at the start of every conversation, within a budget
   of about 2,000 characters ([memory](https://learn.microsoft.com/azure/sre-agent/memory)).
   The file says at the top that a person wrote it, so the agent doesn't present it
   as something it learned.
2. **The warm-up.** Run one incident to the end about 30 minutes before the act, so
   the agent writes its own topic files beside the overview.
3. **The check.** In a new chat, ask whether the estate has had an incident before.
   It should cite the warm-up one.

## Turn it on

Add `MEMORY` to `sre.requiredScenarios` in your private skin. The overview fills its
names from the skin and from the optional T09 and T12 settings, and leaves out the
lines for a scenario you didn't turn on. Then:

- On a new build, `Deploy-SreAgent.ps1` applies it.
- On an agent that is already up, preview with
  `Initialize-SreConfiguration.ps1 -Inspect`, then apply with a new `-BackupPath`
  outside the repository. The acts stage writes its own backup beside it, named
  `<your path>.acts.json`, and refuses to overwrite a file.

The apply never touches notes that exist. If the folder has any file, it says so and
leaves it alone: the seed goes only into an empty folder. `Test-SreReadiness.ps1`
shows an informational row, `ACTS-notes`, with the files it found.

To put the act in your presenter guide, add `MEMORY` to the `acts` list in your
presenter context.

### Seed from your own notes

By default the seed is the repository's `config/acts/memory/overview.md`. To start a
new agent from notes you exported, set `memory.seedPath` in your private skin to the
full path of a folder outside the repository:

```json
"memory": { "seedPath": "<full path to a folder outside the repository>" }
```

When it is set, that folder is the whole seed and the repository's overview is not
added. The folder must hold 1 to 40 `.md` files of at most 64 KB each, with plain
names (letters, digits, `.`, `_` and `-`, at most 90 characters). A folder inside the
repository is refused, because notes name your resources. The preview shows what
would be seeded before anything is written.

## The warm-up flow

1. About 30 minutes before the act, run one incident to the end and let the thread
   finish: the Friday release if you have it, or the Container App reset. Measured
   on 2026-11-11: the agent wrote its notes inside the incident thread, about 3
   minutes after the approved fix, and a new chat cited the incident 8 minutes after
   the click. The alert took about 17 minutes to resolve, and a chat asked before
   that is told the alert is still Fired, so don't ask sooner. Microsoft documents a
   further learning pass about 30 minutes after a thread goes quiet. The notes did
   not change in the 43 minutes after this thread went quiet, apart from what later
   chats wrote themselves, so don't wait for it
   (on 2026-11-10 the platform rewrote the notes about an hour and a half after an
   incident).
2. Check that they exist:

   ```powershell
   .\scripts\Export-SreAgentFiles.ps1 `
     -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
     -Source Notes -List
   ```

   It lists each file with its size. Nothing is written. You should see the overview
   and at least one topic file the agent wrote.
3. At the act, open a new chat and ask: "Have we had an incident on this estate
   before? What was the cause and what fixed it?"

## Keep the notes across a rebuild

Parking the agent deletes the parent and its notes with it. `Hibernate-SreAgent.ps1`
prints a reminder. To keep them, export first, to a folder outside the repository:

```powershell
.\scripts\Export-SreAgentFiles.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Source Notes -OutputPath <a new folder outside the repository>
```

An existing file is never overwritten. To restore, set `memory.seedPath` to the
exported `synthesizedKnowledge` folder and build or apply as above.

**A restored export makes the agent treat that incident as history.** That's what
you want for this act. It isn't what you want for a clean first look at the Friday
release: the agent will read its own earlier notes, count the earlier failures and
refer back. For a clean first look, don't restore.

**There is no way to clear the notes in place.** The agent's file API lists and
reads; it has no write or delete route. Starting from empty notes means parking the
agent and building it again without a seed path.

## What you can and can't claim

- **The overview is hand-written.** Say so. It was seeded, not learned, and it is
  labelled that way in the file. The agent keeps the file up to date itself: on
  2026-11-11 it added a map of the ticketing app and an index line for each new note,
  and the file grew from 1,527 to 2,044 characters, over the budget of about 2,000
  that Microsoft documents. The label at the top stayed.
- **The topic files are the agent's own.** It wrote them while it worked. Say what
  you did: you ran the warm-up, and it carried over.
- **Notes can be wrong.** They are an agent's summary of one run. The runbook note
  from 2026-11-11 says the restart took about 10 minutes. It dated the change at about
  06:00, when the fix card appeared, but the person clicked Approve 9 minutes later and
  the app restarted about a minute after the click. A second run reads the first run's
  notes, so a rehearsal changes what the agent says, and a later thread can rewrite a
  note (one did, and said it hadn't read the file first). If a run is meant to be a
  first look, rebuild first.
- **The hook's feedback becomes a note.** The Stop hook's message reaches the agent as
  a user message, and the agent saved it as `behavior-expectations.md`, "user
  feedback" that incident summaries need a confidence level, no prediction of when an
  alert clears, and validation steps. The next recall chat was allowed on its first
  try (one run, not a guarantee). Say that plainly if you show it: the rule came from
  the hook, and after one block it lives in the notes too. An export of the notes
  carries it into a rebuilt agent.
- **A rebuild clears the notes, not the telemetry.** Log Analytics and the Activity
  Log keep earlier runs, so on a rebuilt agent with no notes at all the recall chat
  can still find them (it counted three failed releases on 2026-11-11, two from
  earlier rehearsals). Judge the act by what the thread read: the portal shows each
  tool call, including the notes files it opened.
- **Don't say it remembers everything.** It keeps what it wrote down. A thread that
  finished a long time ago has to have been written up to count.

## Time and cost

The seed is one call at apply time and adds nothing to the parent's bill: 4 AAUs per
hour from creation until deletion, plus active work
([cost reference](sre-cost-and-demo-fidelity.md#acts-1-3-and-4-ask-remember-and-scheduled-work)).
The warm-up is a full incident, so budget its hours too. The overview is loaded into
every conversation, so it adds a little to each; the AAUs can't be read back.

## Troubleshooting

| You see | Cause and fix |
|---|---|
| The apply says the agent already has notes and leaves them | Expected after a first run. The seed goes only into an empty folder; there is no clear, so rebuild if you want the seed |
| The apply says the notes folder couldn't be read | Nothing was written. Try `Initialize-SreConfiguration.ps1 -Inspect` again, then apply |
| The apply warns that the upload was accepted but no file appeared | The seed upload worked live (HTTP 200 in 2.2 seconds, and the file was listed straight away), so this is unexpected. List the notes with `Export-SreAgentFiles.ps1 -Source Notes -List` before you rely on the seed. The upload isn't repeated |
| `memory.seedPath` is refused | It must be a full path to an existing folder outside the repository, holding 1 to 40 `.md` files with plain names, each at most 64 KB |
| `Export-SreAgentFiles.ps1` says the agent has no notes yet | The folder doesn't exist until a seed or an incident writes to it |
| The new chat doesn't know the estate | Run the canary test below. If it fails, the overview isn't loaded; list the notes and check the seed |
| A chat stops at "pending authorization" on `az ad` lookups | The agent's own runbook note can tell it to resolve a caller with `az ad sp show`. Send "skip the name lookups" in the same thread ([Act 1](ask-anything.md#questions-that-name-people)) |

**Canary test for the seed.** In a new chat, ask: "What is this estate's customer
name, and how do rollbacks work? Don't run any commands." A correct answer comes
from the overview alone. Run it before the first time you present. Measured on
2026-11-11, on a fresh build: the answer came back in 10 seconds with no tool calls.

## What is proven and what isn't

Measured on 2026-11-10, with two incidents on one agent (the first thread was
deleted before the second): the agent wrote its own notes during the first
incident, a topic file with the symptoms, the first checks and the queries, and an
index file. The second incident's first action, 4 seconds after it started, was to
read both. It said the fault was back, went to the fix card in 36 seconds, and edited
the same note at the end. The platform rewrote the notes about an hour and a half
later, so a synthesis step also maintains them. Measured on 2026-11-11, in two full
Friday release runs: the second run's thread read what the first had taught it,
including its failures. That is the rehearsal trap above.

Don't build the act on session insights. On 2026-11-10, nine insights appeared in
about two hours, all for conversation threads and 34 to 130 minutes after the
thread started; none appeared for an incident thread in the time watched. Rating a
response (the API call works) doesn't create one.

Measured on 2026-11-11, on a build from zero with the Arc estate parked (Phase 2):

- **The seed works.** The upload took 2.2 seconds (HTTP 200), and a new chat answered
  from it alone in 10 seconds with no tool calls.
- **The agent writes notes inside the thread, not after it.** The drift scan wrote
  its own note while it ran. The incident thread wrote `architecture.md`,
  `deployment.md` and `logs.md` about 3 minutes after the approved fix, a rewritten
  `overview.md` 16 seconds later, then `debugging.md` and the runbook 14 seconds
  after that, and went idle about 4 minutes 30 seconds after the click.
- **Recall works in a new chat.** The first one started 8 minutes after the click and
  answered in 71 seconds, citing the cause (v1.3.0 has no `PAYMENT_GATEWAY_URL`) and
  the fix (a rollback through `WEBSITE_RUN_FROM_PACKAGE`). A second, 34 minutes after
  the click, answered in 1 minute 45 seconds with the same cause and fix, a confidence
  level and a list of what it hadn't verified.
- **No learning pass appeared.** A listing 43 minutes after the incident thread went
  quiet, and 33 minutes after the last chat that wrote a note went quiet, matched the
  one before it. Only chats changed the notes: a recall chat added four lines to the
  runbook, and a status question added `behavior-expectations.md` and rewrote
  `overview.md`.
- **The folder stays small.** It held 8 files, 15,956 bytes, at the end.

Not run yet:

- Restoring an exported folder through `memory.seedPath`.
- A listing that the agent's file API truncates when a folder holds many files.
- What the platform does with an `overview.md` over its budget (the agent's rewrite
  reached 2,044 characters).
- Clearing the notes in place: nothing here deletes a note, and nothing was tried.

A different route exists and isn't used here. A hand-written document uploaded to
the agent's knowledge store was indexed within seconds and found by its memory
search (measured on 2026-11-10), but that store is searched on demand rather than
put in every prompt, which is why the seed goes in the notes folder instead.
