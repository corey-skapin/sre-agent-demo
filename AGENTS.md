# Instructions for AI tools

This repo adds an Azure SRE Agent to the companion `arc-demo` Arc estate. You're
working for the person who cloned it. When they ask you to build, wake, park,
remove or run an incident, that request is the go-ahead: preview it, then do it.
Don't ask for approval again at each step.

## Before you start

- Confirm the tenant and subscription with the user once, at the start of the
  session. Pass them to every script (`-SubscriptionId`, `-TenantId`). Never take
  them from the ambient `az` login, and never run `az login`, `az logout` or
  `az account set` to switch accounts or subscriptions.
- Keep private values in one folder outside git, for example
  `<PRIVATE_LAB_FOLDER>`: the skin (a copy of `config\demo-skin.json` saved as
  `sre-skin.json`), the saved presenter context, configuration backups, exports
  and evidence. Pass the skin as `-SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json`.
  The tracked skins are fictional examples.
- The Arc estate must be Active first. This repo never deploys, changes or
  removes it.
- Read [README.md](README.md), then the
  [setup path](docs/sre-response-plan-automation.md#setup-path-at-a-glance).
  [docs/README.md](docs/README.md) lists everything else.

## Commands

Run these from the repo root, each with the three inputs above.

- **Build:** `Deploy-SreAgent.ps1 -WhatIf`, then `Deploy-SreAgent.ps1
  -ApproveParentCreation -ConfigurationBackupPath <NEW_FILE_OUTSIDE_REPO.json>`.
  It creates the paid parent (4 AAUs per hour until you delete it), then applies
  and checks the configuration (about 5.5 minutes). Add
  `-GrantAzureMonitorAlertAccess` to create the one subscription Monitoring
  Contributor grant the agent needs to read alerts, unless its identity already
  has it.
- **Check:** `Test-SreReadiness.ps1 -DesiredState Active`. Every required check
  must pass. After parking or removing, use `Hibernated` or `Removed` with
  `-PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID>`.
- **Park:** save the UAMI principal ID, run `Hibernate-SreAgent.ps1 -WhatIf` and
  show the preview, then run it with `-Confirm:$false`. It deletes only the paid
  parent. Park SRE before Arc.
- **Wake:** wake Arc first, then run the Build commands again. The identity and
  its grants are reused.
- **Remove:** `Remove-SreAgent.ps1 -WhatIf`, show the preview, then run it with
  `-Confirm:$false`.
- **Incident:** follow [the T09 runbook](docs/t09-native-containerapp-closed-loop.md).
  It breaks the demo Container App on purpose, waits for the alert and the
  agent's proposed fix, then checks recovery.
- **Present:** `New-PresenterRunsheet.ps1` renders `.local\presenter-runsheet.md`
  from the saved context ([how](docs/ai-deploy-handbook.md#your-presenter-guide)).
  The Arc half is in the Arc repo (`docs/runsheet.md`).
- **Tests:** `.\tests\Invoke-Tests.ps1` (offline, about a minute).

## Safety

- Preview removals and other destructive steps with `-WhatIf` and show the user
  the preview before you run them. If a preview includes anything you didn't
  expect, stop and tell the user.
- Never delete or change resources the scripts don't own: the Arc estate, shared
  Arc and Monitor resources, other people's role assignments, and anything a
  script refuses or reports as unknown.
- Keep secrets, tenant and subscription IDs, emails and private paths out of git.
  Run the tests and scan your diff for them before every commit.
- Keep every response plan in Review mode. Don't switch the agent to Autonomous.
- If a configuration write times out, read the state back
  (`Initialize-SreConfiguration.ps1 -Inspect`) before trying again. Never resend
  it blindly.
- Describe portal steps only from current Microsoft Learn or controls you have
  seen. Don't invent menu paths or buttons.
- Don't invent prices; see [the cost reference](docs/sre-cost-and-demo-fidelity.md).

## The step that stays with the user: Approve

In Review mode the SRE agent investigates, proposes a change, then waits for the
user to click **Approve** in the SRE portal. You can't click it for them, and no
chat message approves it. During an incident, tell the user when the card is
waiting and where to find it
([click path](docs/t09-native-containerapp-closed-loop.md#7-approve-the-governed-fix)).
If they would rather not wait, reset the app yourself with
`Invoke-NativeContainerAppFault.ps1 -State Repair` and tell them the old card is
stale.
