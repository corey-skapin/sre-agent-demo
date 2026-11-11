# T12: The Friday release (bad release, redeploy-previous fix)

Run one incident that looks like a real Friday-afternoon release. A small ticketing
web app gets a release that reads like an ordinary change and breaks checkout in
production. Azure Monitor alerts, the SRE agent finds the release, the file and the
line, counts the failed checkouts, and proposes one fix: redeploy the last good
version. You approve it in the SRE portal, the app recovers, and the agent can then
hand the permanent fix to Copilot as a GitHub issue. Present from the generated
`.local/presenter-runsheet.md`; this page is the runbook for the setup and for the
incident itself. (The guide needs the full presenter context, so a deployment that
requires only `T12` presents from this page; see
[the handbook](ai-deploy-handbook.md#your-presenter-guide).) Ask your AI tool to run
it, or follow it yourself. Either way you do the human steps in
[the list below](#what-only-you-do).

T12 is opt-in. It sits beside T09 and T11 and doesn't change them: add `T12` to
`sre.requiredScenarios` in your private skin and fill in a `release` section.

## What it does

1. Publish your copy of the app repository, one release per version.
2. Deploy the web app, its alert and the one new write grant for the agent (Website
   Contributor on the app) while no paid parent exists.
3. Deploy the SRE agent. Applying its configuration puts the GitHub guard in place
   before anything GitHub is connected.
4. Sign in to GitHub once, so the agent can read the repository.
5. Start the run: the script sends checkout traffic, then releases the bad version.
6. The alert fires, the agent investigates and shows a Review card for the redeploy.
7. You approve the card. The agent's own identity applies the change.
8. Verify recovery, then reset for the next run.

The numbers match the numbered steps below.

## What you can and can't claim

Say these plainly; the scripts and the agent's instructions are written to match.

- **Review gates Azure writes only.** The redeploy waits for your approval because
  the response plan is in Review mode. GitHub writes are not gated by Review mode:
  they stop for approval only because the tool policy this layer applies says
  `ask` for them. Both approvals are yours to click.
- **The GitHub sign-in is wider than the demo repository.** The sign-in uses the
  SRE Agent OAuth app with the `repo` scope, so the grant reaches every repository
  your GitHub account can reach. That's why the apply puts the `ask` policy and a
  repository-only instruction in place first, and never connects the repository or
  even fetches the sign-in link without them. Keep that order on every rebuild.
- **A completed card means a person approved it.** The card's command runs under
  the agent's own identity, not yours. The handler's instructions and a Stop hook
  ask the agent to say "approved by a person and applied" and not to predict when
  the alert clears. The hook did block a draft that made that prediction; see
  [what is proven](#what-is-proven-and-what-isnt).
- **T12 adds one write grant, and Review mode is what holds every write.** The new
  grant is Website Contributor on the web app, so an approved card can change the
  app's settings, and the role can also delete the app and read its publishing
  profile (the Activity Log shows the agent doing the read when it inspects the
  app). The tool policy's `deny`
  rules block `az webapp delete` and `az group delete` outright (measured on 11
  November: the agent reports the tool is blocked by a permission rule and no card
  appears, while any other write still raises a card). The agent's other grants
  don't change: at the default `High`
  access level it also has Contributor on the Arc resource groups, and the
  Monitoring Contributor grant alert access needs (which can write alert rules and
  reads the rest of the subscription). So don't say the agent can only change this
  app. Say that any change it proposes waits for your click in Review mode, and
  read the card before you approve it.
- **An issue the agent creates carries a link to your SRE portal.** The platform
  appends a footer to every issue the agent creates ("This issue was created by"
  the agent, and "Tracked by the SRE agent here"). The link holds your
  subscription ID, resource group, agent name and thread ID, and the platform also
  adds the GitHub account that signed in as a second assignee. The repository has
  to be public because the release packages download anonymously. After the demo,
  edit the issue to remove the footer; the issue's edit history keeps the old text
  until you delete those revisions in the GitHub interface. Don't ask the agent to
  edit it: that is another GitHub write with its own card, and the platform may
  add the footer again.

## Resource map

Default names assume `-NamePrefix arc-demo` and `australiasoutheast`. The web app
name carries an eight-character suffix computed from your subscription and group,
so it's unique and the scripts can find it.

| Resource | Default name | Resource group | Purpose |
|---|---|---|---|
| Web app | `app-arc-demo-ticketing-<suffix>` | `rg-arc-demo-ticketing` | Node 22 on Linux, always on, runs from the release package named by `WEBSITE_RUN_FROM_PACKAGE` |
| App Service plan | `plan-arc-demo-ticketing` | `rg-arc-demo-ticketing` | Linux Basic, `B1` unless the skin says otherwise |
| Application Insights and workspace | `appi-arc-demo-ticketing`, `law-arc-demo-ticketing` | `rg-arc-demo-ticketing` | Requests, exceptions and events (`AppRequests`, `AppExceptions`, `AppEvents`) |
| Alert rule | `alert-arc-demo-ticketing-checkout-failures` | `rg-arc-demo-ticketing` | Sev2, evaluated every minute over five minutes: fires when `POST /checkout` fails or returns 5xx |
| Spare alert rule | `alert-arc-demo-ticketing-checkout-failures-b` | `rg-arc-demo-ticketing` | Disabled; a fallback if a repeat failure merges into an old thread |
| Action group | `ag-arc-demo-ticketing` | `rg-arc-demo-ticketing` | The seam the rules point at; no receivers, the agent reads Azure Monitor directly |
| Role assignment | Website Contributor for the agent identity | the web app only | The one new grant: it lets an approved card change the app's settings |
| Response plan | `ticketing-release-review-v1` | the agent | Review, Azure Monitor, Sev2, title contains `ticketing-checkout-failures`, **cooldown off** |
| Handler | `ticketing-release-investigator` | the agent | Investigation instructions, two skills and the closing-check Stop hook |

The other plans keep the three-hour cooldown. T12's plan turns it off so a repeat
run opens a new thread; see [the troubleshooting table](#troubleshooting) if it
doesn't.

## Prerequisites

- Everything the [README](../README.md#prerequisites) asks for, and the Arc
  estate's resource groups, its Log Analytics workspace `law-<prefix>` and its
  Action Group `ag-<prefix>`. Deploy looks all four up, so they must exist; a parked
  Arc estate keeps them. T12 doesn't touch the estate, and it doesn't need T09 or
  T11: a skin whose `requiredScenarios` is just `["T12"]` is enough.
- A GitHub account you control, a copy of the app repository in it (step 1), and
  `git` for that copy. The scripts never call GitHub with your credentials.
- App Service quota for the plan size in the region you pick. See
  [the region and quota check](#2-deploy-the-workload).
- A private skin with a `release` section, saved outside git:

  ```json
  {
    "sre": { "requiredScenarios": ["T12"] },
    "release": {
      "location": "australiasoutheast",
      "appRepository": "<OWNER>/<APP_REPOSITORY>",
      "goodVersion": "v1.2.0",
      "badVersion": "v1.3.0"
    }
  }
  ```

  Merge those keys into your copy of `config\demo-skin.json`. `location`,
  `appRepository`, `goodVersion` and `badVersion` are required once `T12` is listed.
  Optional keys: `resourceGroup` (default `rg-<prefix>-ticketing`), `appServiceSku`
  (`B1`, `B2` or `B3`), `handlerName` and `responsePlan`. The location can differ
  from `azure.location`, because App Service quota differs by region and
  subscription. The skin is checked offline: run `Initialize-SreConfiguration.ps1`
  with only the target and `-SkinPath` and it renders the desired configuration
  without any cloud request.

Set the variables the later steps use:

```powershell
$subscriptionId = '<SUBSCRIPTION_ID>'
$tenantId = '<TENANT_ID>'
$skin = '<PRIVATE_LAB_FOLDER>\sre-skin.json'
```

## 1. Publish the app repository

The web app runs a release package, not a build: the zip for one version holds a
single bundled `server.js` with its source map, a small `package.json` and the
static files under `public/`. The app repository's release workflow builds that zip
and attaches it to a GitHub release named for the tag, as
`ticketing-app-<tag>.zip`, when you push a tag.

Put your own copy of the app repository in your GitHub account: its history is a
short run of ordinary commits, then the Friday release. Push `main`, then push each
tag one at a time and wait for each release workflow to finish before the next:

```powershell
git push origin main
git push origin v1.1.0   # wait for its release workflow
git push origin v1.2.0   # wait for its release workflow
git push origin v1.3.0   # wait for its release workflow
```

You need releases for `goodVersion` and `badVersion` at least. The deploy script
refuses to go on until both packages download.

`v1.3.0`, the bad release, reads like a normal change: checkout now authorises the
order with a payment gateway before it confirms the reservation, and the gateway
address comes from a new setting, `PAYMENT_GATEWAY_URL`, that the web app doesn't
have. Checkout throws when it's unset. The unit tests still pass, because they
inject the setting. Every request, exception and event the app emits carries
`releaseSha` and `appVersion`, and the app logs a `ReleaseStarted` event on every
start, so the agent can line the first failure up with the release.

## 2. Deploy the workload

Deploy the web app first, before the paid parent exists. A new role can take many
minutes to work, so creating the grant now means no AAUs are spent waiting for it.

```powershell
.\scripts\Deploy-TicketingWorkload.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin -WhatIf

.\scripts\Deploy-TicketingWorkload.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin
```

The preview runs the read-only checks and a what-if. It creates nothing, except
that a missing dedicated SRE group is not created and the quota check is skipped
in that case. The real run:

1. Refuses a ticketing group that already exists without this scenario's
   `sreScenario=T12` tag, and a `release.resourceGroup` that is one of the Arc or SRE
   groups. Teardown deletes the group on that tag, so the scenario only ever owns a
   group it created.
2. Checks both release packages download.
3. Creates the dedicated SRE group if it's missing (free).
4. Asks App Service whether the subscription has quota for the plan in your region.
   Nothing is created by that check; it takes about a minute.
5. Reuses the retained SRE identity, or creates it, and adopts an existing
   Website Contributor grant on the app instead of making a second one.
6. Deploys `infra/ticketing/main.bicep` and waits until the app serves
   `goodVersion`.

**If there's no quota.** Some subscriptions have zero quota for the Basic SKU in
some regions: the check then stops with `InternalSubscriptionIsOverQuotaForSku`
and `Current Limit (B1 VMs): 0`, before anything is created. Set `release.location`
to a region where it passes. In a read-only test of one subscription,
`australiaeast` and `australiacentral` failed this way and `australiasoutheast`
passed, so check yours rather than assuming. The alternative is a quota request:
in the Azure portal, **Quotas** > **App Service** (preview), filter by subscription
and region, choose the SKU and enter a new limit; if the **Total Regional VMs**
quota reads `0 of 0`, try the deployment first and then open a support request
with the full error. [Learn's troubleshooting page](https://learn.microsoft.com/troubleshoot/azure/app-service/troubleshoot-non-zone-redundant-quota-requests)
has the current steps. This repo files no request for you.

When it finishes, save the identity's principal ID it prints (you need it to verify
parking) and note the grant time. Wait for the role to work before step 3: a role
assigned during a rehearsal took up to about 27 minutes.

## 3. Deploy the SRE agent

Use the Build commands from [`AGENTS.md`](../AGENTS.md) as usual, with the T12 skin:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin -WhatIf

.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -ApproveParentCreation -GrantAzureMonitorAlertAccess `
  -ConfigurationBackupPath <NEW_FILE_OUTSIDE_REPO.json>
```

Deploy checks the ticketing group and web app exist (run step 2 first), then creates
the parent and applies the configuration. For T12 the apply runs in a fixed order:

1. The tool policy: `ask` for the GitHub tools, the pull-request names and shell
   calls to GitHub; `allow` for five GitHub **read** tools only; `deny` for
   `az group delete` and `az webapp delete`. The policy is merged in; nothing
   already there is removed.
2. The repository-only instruction: the agent acts on your app repository and no
   other, even though the sign-in can reach more.
3. The two skills (`azure-monitor-rca` and `github-issue-followup`) and the Stop
   hook.
4. The handler and the response plan.
5. The repository connection, **only** if steps 1 and 2 are in place and a GitHub
   sign-in exists. Without a sign-in this step is skipped with a note.

Each stage reads back what it wrote before the next stage runs. A write that times
out is read back, never resent.

## 4. Sign in to GitHub

This is the one GitHub step a person does, once per agent build: parking the agent
deletes the connection with the parent, so you repeat it after every wake.

```powershell
.\scripts\Initialize-SreConfiguration.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Apply -GitHubSignIn -BackupPath <ANOTHER_NEW_FILE_OUTSIDE_REPO.json>
```

The script checks the guard is in place, then prints the sign-in link and waits up
to five minutes for the sign-in to appear. Open the link in a browser signed in to
the GitHub account that owns your app repository and approve the SRE Agent app
(measured on 2026-11-10: 141 seconds from opening the link to the sign-in showing
up). It then connects the repository, waits for the clone and tests the
connection. The response carries no token.

If the five minutes pass before you approve, the script exits with a warning and
nothing is lost but the link: a link left unused for a long time stops working. Run
the same command again with another new `-BackupPath` for a fresh link. Once the
sign-in exists the apply skips the link and connects the repository, so you can also
approve first and run the apply without `-GitHubSignIn` (measured on 2026-11-11:
about three minutes from opening a fresh link to the sign-in showing up, then 50
seconds to connect, clone and test the repository). The clone appears only in
threads that start afterwards, so connect the repository before you start a run.

Some AI tools hide the `state=` value of the link in what they show you, which leaves
a link that doesn't work. The script's full output has the real one: save it to a
file and open the link from there instead of copying it from the screen.

If the link doesn't come back, the portal does the same job: from Learn, not
exercised here, open the agent's **Build + setup** > **Context** > **Code access**,
choose the service tab, select **Add repository** and sign in with **OAuth**. Do
that only after step 3 reported the policy and the instruction in place.

Skipping the sign-in is allowed: the rollback card still works. The agent just can't
read the repository or open the follow-up issue.

## 5. Check readiness

```powershell
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -DesiredState Active
```

Every required check must pass, as for any scenario. T12 adds these rows:

| Check | Required | Meaning |
|---|---|---|
| `T12-web-app` | yes | The tagged web app exists and is running |
| `T12-release` | yes | `/healthz` reports `goodVersion` |
| `T12-alert` | yes | Two Sev2 rules on the ticketing workspace, exactly one enabled |
| `T12-github-guard` | yes | The ask rules and the repository-only instruction are present |
| `T12-skills`, `T12-hook` | yes | The skills and the Stop hook match this repo |
| `T12-github-signin`, `T12-repository` | no | `pending` until you've done step 4 |

## 6. Run the incident

Open `https://sre.azure.com`, select the agent and open it once, letting its welcome
thread finish: the first visit to a fresh agent starts that thread and spends agent
usage, and it shouldn't run beside the incident.

```powershell
.\scripts\Invoke-FridayRelease.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Start
```

Start checks the app serves `goodVersion`, exactly one alert rule is enabled and the
agent is reachable. It then starts background checkout traffic (the app only reports
failures when it receives `POST /checkout`) and proves that traffic is flowing
before it releases anything: the generator must be running, must have logged
checkouts that all returned 200 and must have logged one in the last minute. It
waits a five-minute baseline (`-BaselineMinutes`), checks again, and only then
releases `badVersion` by pointing `WEBSITE_RUN_FROM_PACKAGE` at its package, with
your own credentials. `-WhatIf` previews it. If the proof fails at any point (the
generator isn't running or has gone quiet, or a checkout fails), Start releases
nothing, stops the run and tells you to reset. A release nobody is calling would
raise no failure, no alert and no thread.

Follow the run:

```powershell
.\scripts\Invoke-FridayRelease.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Status -Wait
```

Status records the first time each milestone happened in `.local\friday-release\`
(ignored by git): release applied, bad version serving, first failed checkout,
alert fired, thread created, first agent message, card pending, card completed,
healthy again and alert resolved. `-Wait` keeps polling until an Approve card is
pending (default 30 minutes, `-TimeoutMinutes`). It never approves anything.

From the release, the card took 4 min 19 s in one run and 5 min 33 s in the next
(measured on 2026-11-11 on `B1` in Australia Southeast with a two-minute baseline).
The bad version was serving 1 min 47 s and 2 min 21 s after the setting changed, the
alert fired 2 min 35 s and 3 min 41 s after the release, the thread about 50 seconds
after the alert and the card about a minute after the thread. Start the run about 12
minutes before you need the card: five of those are the default baseline.

### The cards

There are up to two, and you click both:

1. **The Azure card.** Expand the card, not just the prose. It must be one
   `az webapp config appsettings set` on the ticketing group and web app that sets
   `WEBSITE_RUN_FROM_PACKAGE` to the **good** version's package URL, and nothing
   else. If the agent proposes anything different, don't approve it.
2. **The GitHub card**, if you ask the agent for the follow-up issue: creating an
   issue assigned to Copilot in your app repository stops for approval because of
   the `ask` policy. Check the repository, title and assignee before you click.

Approve in the SRE portal as the click path in
[the T09 runbook](t09-native-containerapp-closed-loop.md#7-approve-the-governed-fix)
describes. You can't approve through the script or a chat message, and an AI tool
can't click for you. If you'd rather not wait, reset the app yourself
(`-Action Reset`, below) and treat the old card as stale: never approve it
afterwards. Reset with `-DeleteThreads` removes it.

After your click, the new version was serving about two minutes later in the
measured run (the app restarts again: 2 min 5 s from the click, and the runner saw
healthy traffic at 2 min 12 s). Verify:

```powershell
.\scripts\Invoke-FridayRelease.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Status
```

Expect `healthy again` after the card completed. The alert resolves by itself about
15 to 17 minutes after the last failed request (16 min 28 s measured); read its
Monitor condition separately from the thread and from the app.

### Reset

```powershell
.\scripts\Invoke-FridayRelease.ps1 `
  -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin `
  -Action Reset -DeleteThreads
```

Reset stops the traffic, puts `goodVersion` back unless the approved fix already
did, waits until the app is healthy and restores the alert rules. `-DeleteThreads`
removes this run's investigation threads, and any stale Approve card with them.
`-SwapRules` makes the spare alert rule the active one instead. Preview with
`-WhatIf`. The run record moves to `run-<id>.json`, so the next Start begins clean.
If the record can't be read (a file cut short by a crash), Start and Status say so,
and Reset moves it aside as `unreadable-<time>.json` and carries on; a traffic
generator it started stops by itself within two hours.

## How the fix works

The web app runs from the package URL in `WEBSITE_RUN_FROM_PACKAGE`, so redeploying
the last good version is one setting. The agent proposes it as one Review card;
the approved command runs under the agent's identity with Website Contributor on
this one app. There are no deployment slots to swap on `B1` (slots start at the
Standard tier), no build step and no deploy credentials: the app has basic
publishing credentials disabled.

Each change restarts the app, which takes about two minutes on `B1` (1 min 47 s and
2 min 21 s measured for the bad release, 2 min 5 s for the fix).

If run-from-package from a GitHub release URL doesn't work on your plan (the URL
redirects to an asset host), two fallbacks use the same two zips: `az webapp deploy
--type zip --src-url <package URL>`, or the same packages in a blob container. The
handler's instructions (`config\t12\handler.instructions.txt`) and the runner's
package setting (`scripts\lib\SreFridayRelease.psm1`) would need the matching
command.

## What only you do

| Step | What you do | How often |
|---|---|---|
| 1 | Publish the app repository releases | Once per copy of the repository |
| 4 | Open the sign-in link and approve the SRE Agent app | Once per agent build |
| 6 | Open the SRE portal once so the welcome thread finishes | Once per agent build |
| 6 | Click **Approve** on the Azure card | Every run |
| 6 | Click **Approve** on the GitHub card, if you take the Copilot hand-off | Every run that uses it |

Everything else runs from scripts your AI tool can run for you.

## Time and cost

- The paid parent bills 4 AAUs per hour from creation until you delete it
  ([cost reference](sre-cost-and-demo-fidelity.md#t12-the-friday-release)). The
  build takes about 5.5 minutes, plus the role wait if you skipped step 2's lead
  time, plus the run: about five minutes to the card, two to recovery.
- The workload is one `B1` plan, one Linux web app and a little telemetry. The
  retail price of a Linux `B1` plan is in the cost reference. Park the parent when
  you're done; the workload keeps running until you remove it.

## Teardown

Park the agent first, then remove the workload, then remove the rest if you're
finished. Preview each step with `-WhatIf` and show it before you run it for real
with `-Confirm:$false`.

1. Park the agent: save the identity's principal ID, run `Hibernate-SreAgent.ps1`
   and verify with `Test-SreReadiness.ps1 -DesiredState Hibernated`
   ([the park steps](sre-response-plan-automation.md#hibernation-and-later-reactivation)).
2. Remove the workload:

   ```powershell
   .\scripts\Remove-TicketingWorkload.ps1 `
     -SubscriptionId $subscriptionId -TenantId $tenantId -SkinPath $skin -WhatIf
   ```

3. Only if you're finished with the SRE layer, `Remove-SreAgent.ps1` with the same
   skin.

`Remove-TicketingWorkload.ps1` deletes only the ticketing group, and only when it's
tagged `sreScenario=T12`. It refuses while the SRE agent exists, because the
agent's managed resources point at that group. The Website Contributor grant is
scoped to the app, so it goes with it. The SRE group, the retained identity and the
Arc estate aren't touched. `Remove-SreAgent.ps1` with a T12 skin recognises the
web-app grant; without one it stops on it as an unexpected grant.

## Troubleshooting

| You see | Cause and fix |
|---|---|
| Deploy stops at `InternalSubscriptionIsOverQuotaForSku` | No quota for the SKU in that region. Pick another `release.location` or request quota ([step 2](#2-deploy-the-workload)). Nothing was created |
| Deploy says a release package isn't downloadable | The tag's release workflow hasn't finished, or it failed. Wait for it, or fix the cause and re-run it from the app repository's Actions tab |
| `Deploy-SreAgent.ps1` says to run `Deploy-TicketingWorkload.ps1` first | The ticketing group or web app doesn't exist yet |
| The apply reports "GitHub is not signed in" | Expected after a build. Run [step 4](#4-sign-in-to-github) |
| The apply reports "Blocked: the GitHub tool policy and the repository-only instruction are not both in place" | The first stages didn't read back. Run `Initialize-SreConfiguration.ps1 -Inspect`, don't connect the repository by hand, and apply again with a new `-BackupPath` |
| Start says the agent isn't ready | A bad release would go unnoticed. Check `Test-SreReadiness.ps1 -DesiredState Active` first |
| Start says "Nothing was released: …" | The baseline proof failed: the traffic generator isn't running, has logged nothing or gone quiet, or a checkout returned something other than 200. Nothing changed in Azure. Run `-Action Reset`, check the app with `-Action Status`, and start again |
| Deploy says the group already exists and wasn't created by this scenario | The group has no `sreScenario=T12` tag, so Remove would later delete something that isn't yours to delete. Set `release.resourceGroup` to a new name |
| Start says exactly one alert rule must be enabled | A rehearsal left both on or neither. `-Action Reset` restores the primary rule |
| No new thread for a repeat failure, only an acknowledged alert | The old thread merged it. Run Reset with `-DeleteThreads -SwapRules` and wait about 17 minutes for the old alert to resolve |
| No alert, though checkouts fail | The app reports failures only when it receives `POST /checkout`; check the traffic log in `.local\friday-release\`, and that the alert rule is enabled |
| A card from an earlier run is still pending | It's stale: never approve it. Reset with `-DeleteThreads` |
| The card proposes something other than one `WEBSITE_RUN_FROM_PACKAGE` change | Don't approve it. Reset the app with `-Action Reset` |
| The agent says "An error occurred while creating the approval record" for the GitHub issue, and no card appears | The issue body is too long: no card can be made when the escaped body is longer than about 4,000 characters, and each backtick, quotation mark or apostrophe counts as six. Ask the agent to retry once with a body under 2,500 characters and few backticks; the skill tells it to. Links and labels were not the cause |
| The sign-in wait ends with "No GitHub sign-in appeared in time" | The link wasn't approved within five minutes. Approve it if it still works, or run the apply again for a fresh link ([step 4](#4-sign-in-to-github)) |
| `Test-SreReadiness.ps1` fails `T12-release` | Expected while the bad release is serving. Run it again after recovery or after `-Action Reset` |

## What is proven and what isn't

Measured on 2026-11-10 against a spike web app with the same shape (a setting
change, not a package swap): the alert, thread and Review-card timings above; that
an approved card runs under the agent's identity, including when an alert started
the thread with nobody signed in; that with an `ask` policy a GitHub issue
creation stops for approval while an allow-listed GitHub read runs without a card;
that the agent's issue assigned to Copilot produced a draft pull request nine
seconds later; and the 141-second sign-in.

Measured on 2026-11-11 against this workload, in two full runs and some separate
tests:

- **The package swap from a GitHub release URL works on `B1`.** The bad version
  served 1 min 47 s and 2 min 21 s after the setting changed, and the fix 2 min 5 s
  after the click.
- **The cooldown switch works.** The second run's alert fired 15 minutes after the
  first run's thread was resolved, well inside the default three hours, and started
  a new thread. Nothing was deleted and no rule was swapped.
- **The Stop hook runs after every reply (1.4 to 2.3 seconds) and it can reject.**
  It blocked a closing draft that predicted when the alert would clear. Its first
  wording also demanded the approver's name and time, which the agent can't know,
  so the agent hedged; the shipped prompt requires only that a person approved the
  card. A hook that is a language model needs a rehearsal: watch what it asks for.
- **The `deny` rules work.** For `az webapp delete` and `az group delete` the agent
  reports that the tool is blocked by a permission rule and no card appears, while
  any other write still raises one.
- **A card waits as long as nobody clicks.** The first run's waited 14 min 42 s
  and never expired.
- **The approved write ran under the agent's identity.** The Activity Log caller is
  that identity, not yours.
- **A GitHub issue body that is too long can't get a card.** The agent reports "An
  error occurred while creating the approval record" and nothing appears. The
  platform stores the call's parameters escaped, and each backtick, quotation mark
  or apostrophe then counts as six characters. Escaped bodies of 3,410, 3,807 and
  3,833 characters got a card; 4,087, 4,273 and 4,448 did not, whatever the links,
  the labels or a link to the SRE portal. The skill now keeps the body under 2,500
  characters, but that rule hasn't been through a live incident yet.
- **The Copilot hand-off works on this app.** The approved issue was created, and
  Copilot's draft pull request opened 8 seconds later and had its final title and
  four changed files about five minutes after the issue.
- **The agent reads the repository only in threads that start after the sign-in
  has connected it.** An earlier thread sees an empty clone.
- **The agent keeps notes between threads.** The second run's thread read what the
  first run taught it, so a rehearsal changes what the agent says in the next run.
- **The hook is a nudge, not a gate.** In a third run (the Act 3 warm-up on
  2026-11-11), the closing draft was blocked for having no confidence level or
  validation step, the redraft was blocked for a next step that implied when the
  alert would clear ("check at 06:45"), and the thread then went idle with the second
  draft. A recall chat did the same, and a status question was blocked once and then
  allowed. Read the closing summary before you show it, and expect the first draft to
  be imperfect and the last one to stand.
- **The hook judges chats too.** It blocked two chats whose answers read like incident
  summaries (the recall question and "how is the ticketing app doing" while the alert
  was still Fired), and it allowed the three scheduled tasks and the other estate
  answers.
- **That third run's timings**, from the setting change: the bad version served
  after 1 min 04 s, the alert fired at 1 min 55 s, the thread started at 2 min 05 s
  and the card was pending at 4 min 02 s. The person clicked 9 min 10 s later; the
  write was applied 6 seconds after the click and checkouts were healthy 58
  seconds after it. The alert took 16 min 43 s from the click to resolve.

Not yet shown live, so rehearse before you present: a closing summary that passes
the hook on its first draft; the skill's new limit on the issue body's size; and the
`-SwapRules` rule update. The runner (`Invoke-FridayRelease.ps1`) is covered by
offline tests against a fake agent and has run live three times.
