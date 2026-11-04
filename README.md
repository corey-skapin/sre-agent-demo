# Azure SRE Agent layer for arc-demo

This repository is the optional **Azure SRE Agent** layer for the separate `arc-demo` companion repository. It keeps concerns split: `arc-demo` builds the Arc + Azure Monitor estate and remains fully standalone; this repo attaches an SRE Agent to an already-deployed `arc-demo` environment without redeploying or modifying it.

**Present from `.local/presenter-runsheet.md`.** Setup generates this local SRE
guide with the actual resource names, portal links and scoped queries. Follow it
top to bottom after the Arc section in the companion repo. No presenter input
card or customization step is required.

## Start here

- **AI coding assistants:** read [`AGENTS.md`](AGENTS.md) first.
- **Presenter:** open `.local/presenter-runsheet.md`. If it is missing, the setup assistant follows [local guide generation](docs/ai-deploy-handbook.md#local-presenter-guide). The [docs index](docs/README.md) keeps operator/history references outside the presenter path.
- **Build, verify, park, wake or remove the SRE layer:** follow the [setup path at a glance](docs/sre-response-plan-automation.md#setup-path-at-a-glance) in `docs\sre-response-plan-automation.md`. Dated rehearsal evidence is kept in that document's appendix, away from the setup steps.
- **Do not use every doc as a presenter script.** Several files under `docs\` are engineering evidence or historical runbooks.

## What it deploys

- `Microsoft.App/agents` SRE Agent in **Review** mode.
- `incidentManagementConfiguration.type = AzMonitor` so Azure Monitor alerts are the incident source.
- User-assigned managed identity for the agent action and knowledge graph paths.
- Workspace-based Application Insights component for agent diagnostics, linked to the existing arc-demo Log Analytics workspace.
- RBAC on the existing arc-demo Arc/observability and infra resource groups:
  - `High` access (default): Reader + Log Analytics Contributor + Contributor, preserving the existing lab profile for governed Review-mode remediation.
  - `Low` access: Reader + Log Analytics Reader for observe-only demos.

The Bicep uses the published [Microsoft.App/agents schema](https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/agents).

## Repo layout

```text
infra/
  main.bicep                 # subscription-scope composition and RBAC over existing arc-demo RGs
  modules/sre-identity.bicep # retained SRE-only user-assigned identity
  modules/sre-agent.bicep    # disposable parent and App Insights, referencing retained identity
  modules/role-assignments.bicep # RG-scoped RBAC for the agent identity
config/
  demo-skin.json             # fictional default skin (also dummy-customer.demo-skin.json); schema in demo-skin.schema.json
  sre-handler.instructions.txt, sre-sql.instructions.txt, sre-parent-settings.json # versioned agent instructions and parent settings
samples/
  lob-arc-app/               # Local T11 app; optional operator-supplied repository context
scripts/
  Deploy-SreAgent.ps1        # builds the parent (and, with -ConfigurationBackupPath, its configuration)
  Initialize-SreConfiguration.ps1 # renders, inspects and applies handler/response-plan configuration
  Test-SreReadiness.ps1      # read-only readiness for -DesiredState Active, Hibernated or Removed
  Hibernate-SreAgent.ps1     # parks the paid parent, retains identity and grants
  Remove-SreAgent.ps1        # separately approved full removal
  Grant-SreAzureMonitorAlertAccess.ps1 # the one subscription Monitoring Contributor grant
  Invoke-SreDemoRoute.ps1    # Prepare/Restore a demo alert rule around a live fault
  New-PresenterRunsheet.ps1  # renders .local/presenter-runsheet.md; no Azure calls
  Invoke-NativeContainerAppFault.ps1 # T09 fault toggle
  Invoke-LobArcAppOnArc.ps1  # deploys/operates the T11 LOB app on a Windows Arc server
  New-LobArcAppMonitorAlert.ps1 # creates or prints the T11 log alert signal
  Invoke-T10ArcFault.ps1     # historical T10 experiment fault helper, kept for its ledger
  lib/                       # shared modules for the scripts above
tests/                       # offline tests; run .\tests\Invoke-Tests.ps1
docs/                        # start at docs/README.md
```

## Prerequisites

1. Existing current `arc-demo` deployment; enable its optional Container App
   workload when presenting T09.
2. Explicit tenant/subscription inputs matching the Arc estate; do not rely on
   ambient subscription selection.
3. PowerShell 7.4+ (every script requires it), Azure CLI 2.60+ and Bicep CLI (`az bicep install`).
4. Permission to create a resource group, managed identity, Application Insights component, `Microsoft.App/agents` resource, and role assignments on the existing arc-demo resource groups.

Default arc-demo names discovered by the script:

| Input | Default discovery |
|---|---|
| Arc/observability RG | `rg-<NamePrefix>` |
| Infra/workload RG | `rg-<NamePrefix>-infra` |
| Log Analytics workspace | `law-<NamePrefix>` in the Arc RG |
| Action Group | `ag-<NamePrefix>` in the Arc RG |
| SRE RG | `rg-<NamePrefix>-sre` |
| Agent name | `sre-<NamePrefix>` sanitized to the SRE Agent naming rules |

The defaults above are read from the schema-validated skin unless a script parameter
overrides them. Missing or invalid skins fail, rather than silently using another
customer's defaults. Subscription and tenant GUIDs are required on cloud helpers;
requests pass explicit subscription context without changing the global CLI account.
Names are validated rather than silently sanitized when explicitly supplied.

## Handoff safety

Keep tracked examples fictional and real skins/evidence outside the checkout.
Optional source URL/revision must be supplied together; a local-sample demo
requires neither a repository connection nor a fabricated source URL.
`tests\Invoke-Tests.ps1` includes handoff checks for non-example UUIDs, contact
emails, workstation checkout/home paths and unreviewed repository-owner links. Public Azure
role IDs and synthetic test IDs are deliberately retained.

CI also runs PowerShell static analysis, offline Bicep compilation and Markdown
linting. The Markdown config preserves existing long lines and table styles;
other rules stay enabled. These checks do not perform a live smoke test.
These checks are not a complete detector of customer context or secrets.
Review all tracked changes and perform a bounded secret check before sharing.
Current-tree cleanup does not rewrite Git history, author metadata, hosting
ownership or prior PR content; those remain separate from the sanitized files.

## Validate locally

On Windows, the shared CLI helper invokes the installed MSI CLI's bundled native
Python entry point, matching `az.cmd` without shell-interpreting query URLs or
guest arguments. A missing bundled runtime fails explicitly; it never falls back
to unsafe command-string forwarding.

```powershell
# Run from the SRE checkout.
.\tests\Invoke-Tests.ps1
az bicep build --file .\infra\main.bicep
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\scripts\Deploy-SreAgent.ps1', [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

## Deploy against an existing arc-demo environment

### Rebuild prerequisites

Use the same validated private skin for every SRE script, passed as an absolute
`-SkinPath <PRIVATE_LAB_FOLDER>\sre-skin.json`. The companion wrapper resolves its
`build.json` relative `sre.skinPath` against that one private lab folder, not the
current directory. Keep it outside git, worktrees and assistant session folders.
Store one new configuration backup per deployment under `sre-backups\`.

The Arc owner must first deploy/verify the shared workspace, collection, Action
Group and hosts. With `T09`, its Arc skin must enable Container Apps and provide
the healthy fault app plus restart alert. With `T11`, separately authorize
`New-LobArcAppMonitorAlert.ps1 -Action Create` and
`Invoke-LobArcAppOnArc.ps1 -Action Deploy` using the same target/skin before SRE
readiness. The latter is a guest Run Command write, not a read-only prerequisite
check. `Connected` alone does not prove that the LOB app or its Event/Perf data
exists. SQL also needs the Arc owner's SQL/collection/alert readiness handoff.

Install Azure CLI and its `containerapp` and `connectedmachine` extensions
before deployment (extension installation needs its own setup authorization).
On Windows, keep the CLI installation's bundled Python runtime: the shared
wrapper uses native `python.exe -IBm azure.cli`, not a shell command string or
an unrelated Python installation. It fails explicitly if that runtime is missing.
Keep SRE registration/region availability and caller role-assignment rights
separate from these client prerequisites.

Readiness isolates a missing, denied or malformed scenario resource/alert into
its own failed check and still evaluates later handler, routing and IAM checks.
It never creates missing prerequisites or injects faults.

Preview first:

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -WhatIf
```

Deploy:

Creation starts the AAU meter and requires explicit `-ApproveParentCreation`.
An existing parent is refused before IaC, including WhatIf: use configuration-only
Inspect/Apply for handler and plan changes instead of overwriting live settings.
The complete build creates the parent, then applies and read-back-verifies the
handler and response plans. It needs `-ConfigurationBackupPath`: a **new** file in
an existing directory outside the repository, kept as the reference export.

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -ApproveParentCreation `
  -ConfigurationBackupPath <NEW_PATH_OUTSIDE_REPO.json>
```

Add `-GrantAzureMonitorAlertAccess` only after IAM approval (see
[How it consumes arc-demo](#how-it-consumes-arc-demo)); without that grant,
required readiness fails on `azure-monitor-alert-access` unless the retained
identity already holds it. `-ParentOnly` replaces `-ConfigurationBackupPath` to
stop after the control plane; that result is **not Ready**. Finish with
`Test-SreReadiness.ps1 -DesiredState Active` (below).

If your arc-demo names differ from the skin, pass explicit IDs/names instead of
relying on discovery. A complete build requires the skin's own names, so custom
overrides are `-ParentOnly` and the skin must be reskinned to match before the
configuration step ([reskin guide](docs/reskin-guide.md)):

```powershell
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -ParentOnly `
  -ApproveParentCreation `
  -ArcResourceGroupName rg-my-arc `
  -InfraResourceGroupName rg-my-arc-infra `
  -LogAnalyticsWorkspaceId /subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/law-my-arc `
  -ActionGroupId /subscriptions/.../providers/Microsoft.Insights/actionGroups/ag-my-arc `
  -AdditionalManagedResourceIds /subscriptions/.../providers/Microsoft.App/containerApps/ca-arc-demo-fault
```

## How it consumes arc-demo

This layer reads the existing arc-demo resource group IDs, Log Analytics workspace ID, and Action Group ID. Those IDs become SRE Agent knowledge graph managed resources. The agent identity receives RBAC on the existing Arc/observability RG (`rg-arc-demo`) and backing workload RG (`rg-arc-demo-infra`) so later scenarios can investigate Azure Monitor alerts and, in Review mode, propose controlled fixes.

No companion Arc files or workloads are changed by this repo.

Azure Monitor intake also requires exactly one subscription-scoped Monitoring
Contributor assignment on the live UAMI. Opt in with
`Deploy-SreAgent.ps1 -GrantAzureMonitorAlertAccess` only after IAM approval, or
preview and approve the [standalone grant](docs/sre-response-plan-automation.md#explicit-azure-monitor-access-grant).
Without it, selected-AzMonitor readiness fails rather than silently granting access.
IaC sets `incidentManagementConfiguration.type = AzMonitor`; the script supplies
the separately approved role grant. A portal connection click is **not a required
rebuild step**. Readiness reports the ARM selection as `incident-platform`, not
scanner health or alert-delivery proof. If it reports an unset/non-AzMonitor
platform, use the separately authorized [portal fallback](docs/sre-response-plan-automation.md#explicit-azure-monitor-access-grant).
Do not enable a quickstart Autonomous plan. Fresh-agent intake from IaC plus
the scripted grant remains **unproven until the rebuild and authorized delivery
verification**.

### Complete Ready state

`-ParentOnly` explicitly acknowledges that Bicep deploys only the control plane.
For complete parent-plus-configuration deployment supply a new
`-ConfigurationBackupPath` outside git. For an already running parent, use
`Initialize-SreConfiguration.ps1 -Inspect`, then separately authorized `-Apply
-BackupPath <NEW_PATH>`.
The [current-schema procedure](docs/sre-response-plan-automation.md) uses pinned
Microsoft IaC template protocols for full reads, named upserts and verification.
Do not use the legacy MCP `severity: high` recipe: it creates invalid AzMonitor
P1/P2 and response-level settings. Current plans use exact Sev2, explicit Review,
and instructions/tools on the handling custom agent. Fresh bootstrap creates one
handler and two filters, or three when the optional SQL scenario is enabled;
modern updates preserve the same objects/history.
SQL uses the Arc-owned real lock-timeout signal for investigation and operator
recommendations only. Its exact setup and retained-identity wake behavior are in
the [configuration reference](docs/sre-response-plan-automation.md#exact-desired-demo-configuration).
Legacy migration/cutover is not supported; legacy settings or enabled unowned
routes stop before writes. See the canonical protocol/fallback reference above.

Run `Test-SreReadiness.ps1 -SubscriptionId <SUB> -TenantId <TENANT>
-SkinPath .\config\demo-skin.json -DesiredState Ready -OutputFormat Json`.
It is read-only and bounded (`-TimeoutSeconds`, default 180). The common Arc/SRE
contract uses `pass|fail|pending|skipped`, with exit 0 pass, 1 fail/error, 2 pending.
It checks parent/Review/identity/RBAC/managed resources/scenario resource health
and reads full handler/plan/legacy-settings/routing configuration. Invalid
priorities or legacy settings fail explicitly. The command does not ingest
external rehearsal evidence: `telemetry-and-alerts` is optional
(`required=false`), skipped/not evaluated, with no observed proof.
Active/Ready exits 0 when required checks pass; required fail/pending checks
still produce exits 1/2. Record authorized incident evidence separately.
Parent success is never a routing-readiness certificate.

Required scenarios come from `sre.requiredScenarios` (default T09/T11). Deployment
adds their explicit Container App/Arc IDs to managed resources. Bicep role names
include the identity principal; existing same-principal names are adopted.
Incremental deployments cannot revoke permissions: a Low downgrade with an
existing incompatible write grant fails until a separately approved cleanup.
Legacy Monitoring Contributor or other excessive/inherited grants are retained
while parked but require explicit reconciliation before Active.
Low uses the actual Log Analytics Reader ID;
the previous template mislabeled Log Analytics Contributor as Reader.
User, service-principal and managed-identity deployers are supported through
`-DeployerPrincipalType` inference/override.

## Off state / reactivate

The demo has three desired states: **Active** (`Ready` remains a compatible
readiness name/default), **Hibernated**, and **Removed**. Hibernation deletes the
paid SRE parent but **retains the dedicated group/UAMI, existing workload grants,
workspace Application Insights and owned Smart Detection Action Group**.
The deployer's parent-scoped administrator entry follows the deleted parent,
not the stable UAMI. Stale entries and unrelated IAM/resource drift are
reported for reconciliation before Active, not silently deleted or used to
block parking the known parent. Wrong target/identity and failed reads still stop
execution. The Arc estate is never deleted here.
Unknown retained resources may still bill; Hibernated proves the SRE parent's
cost state, not that the whole group or combined lab is cost-free.

| Desired state | Required result |
| --- | --- |
| Active (`Ready` alias) | Parent, configuration, identity/grants and required workloads verified; rehearsal is advisory and unevaluated. |
| Hibernated | Paid parent absent, original UAMI/group retained; diagnostics/grants are reported without blocking parking on unrelated free drift. |
| Removed | Verified owned grants/resources and empty dedicated group removed; shared Arc/Monitor resources and private exports preserved. |

```powershell
# Only after approved parent removal; export configuration/evidence and
# save the live identity principal first. See the complete lifecycle procedure:
# docs\sre-response-plan-automation.md
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -WhatIf

# Execute only the approved preview.
.\scripts\Hibernate-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json

# Submission is asynchronous; repeat this read-only check within a bounded
# observation window until pass, or report pending/failure without resubmitting.
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Hibernated `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -OutputFormat Json

# Before the next demo — rebuild the parent using the retained identity
# First reactivate and verify Arc through its own repo, then preview with -WhatIf.
.\scripts\Deploy-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -ApproveParentCreation `
  -ConfigurationBackupPath <NEW_PATH_OUTSIDE_REPO.json>
```

Verify SRE hibernation before parking Arc; wake Arc before reconstructing SRE.
Reactivation is the same complete build as a first deployment: it reuses the
retained identity and grants, recreates and verifies the handler and v3 plans,
and needs a new external backup path and approval for actual changes. Follow it
with `Test-SreReadiness.ps1 -DesiredState Active`.
After successful AI-led combined activation/SRE reactivation, the SRE assistant
must [ask once whether you want a T09 incident](docs/ai-deploy-handbook.md#post-activation-incident-offer).
If you agree, it runs the existing procedure and guides your human Review
approval; you do not need to remember or run scripts. Declining leaves Active
unchanged. This offer does not run after parent-only or Arc-only deployment.
Deletion loses custom agents, response plans, thread/incident history, memory and
connector state. Code-repository authorization is optional and must be explicitly
re-established; a URL in the skin is not authentication. Save the retained identity
principal and use readiness `-DesiredState Hibernated
-PreviousIdentityPrincipalId <ID>` to verify retained identity and parent absence. Missing
identity/partial state is safe to inspect, but an absent UAMI (including historical
whole-group deletion) fails the new identity-retained Hibernated contract.
WhatIf never selects a global account, revokes grants or writes a
guest script.
The saved Inspect export is a reference, not a replayable history/connector
backup. The retained UAMI principal and deterministic workload assignment IDs
are reused on wake; deployment creates it only on the first deployment or after
separate full deletion. The parent keeps its validated combined identity shape:
its system-assigned principal still changes when the parent is recreated and is
not granted these external workload roles. Never reactivate retired legacy v2 handlers.
Versioned filters explicitly restore enabled three-hour cooldown and Review/Sev2.
Hibernate was proven live on 2026-11-04. Reactivation after it and a from-zero
Deploy have not been run live, so treat them as unproven until a separately
authorized run. Residual Arc/storage/monitoring
charges remain until their own lifecycle actions; this is not a zero-cost claim.

The [managed identity itself has no extra cost](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
Normal parking also retains its free workload grants, including standing
Contributor access. Restrict who can attach/use that identity. Before Active,
deployment/readiness require the requested profile at the two workload groups;
excessive/inherited grants need explicit reconciliation, never automatic revocation.
Incremental IaC adopts existing assignment names and creates only missing grants.
The separate identity module owns it in the same SRE group, so first creation and
future reuse follow identical IaC without an extra identity group or manual identity.
Full removal requires separate explicit approval and `Remove-SreAgent.ps1`:

Its live read-only preview has been rehearsed: seven UAMI assignments, one parent
administrator, four resources and the dedicated group; no mutation occurred.
Destructive Removed convergence remains a separate unverified live step.
Known extra UAMI grants require an explicit full assignment-ID
[allow-list](docs/sre-response-plan-automation.md#explicit-removed-convergence),
not a blanket role exemption.

```powershell
.\scripts\Remove-SreAgent.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -WhatIf
# Execute without -WhatIf only after approving the exact resources/grants.
.\scripts\Test-SreReadiness.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json -DesiredState Removed `
  -PreviousIdentityPrincipalId <SAVED_PRINCIPAL_ID> -OutputFormat Json
```

Removed deletes only known SRE resources, known identity-owned grants, verified
parent grants and the dedicated group **after it is empty**. Unknown resources
or scoped assignments block removal for ownership review. Save the principal
before removal: without it, external-grant verification is pending, not passed.
Already absent/partial state converges without deploying anything. Private
exports and shared Arc/Monitor resources remain untouched. Old UAMI-only parked
states remain Hibernated; authorized wake recreates their missing diagnostics.

SRE Agent's [always-on charge](https://learn.microsoft.com/azure/sre-agent/pricing-billing)
is **4 Azure Agent Units per agent-hour while the parent exists**, including when
it is Stopped. Stopping is not the repo's deletion-based hibernation and does not
remove that baseline charge. `High`/`Low` are permission profiles, not pricing tiers.
See `docs\sre-cost-and-demo-fidelity.md` for billing assumptions, remaining Monitor
costs and why a cheaper-looking model, retention setting or cap is not a safe
automatic demo downgrade. Keep a requested running demo running.

## Scenario runbooks

The complete audience/status map is [`docs\README.md`](docs/README.md).
Open `.local/presenter-runsheet.md` for the SRE presentation. The Arc repo owns
its own section. The files below are operator/engineering references, outside
the presenter path.

- `docs\delivery-runsheet.md` - Source for the generated SRE-only presenter guide.
- `docs\sre-cost-and-demo-fidelity.md` - SRE cost levers, parking tradeoffs and demo-preserving boundaries.
- `docs\ai-deploy-handbook.md` - Prompt and checklist for AI-assisted deployment by another SE.
- `docs\sre-sales-rollout-guidance.md` - Internal sales, PoC and rollout guidance for SRE Agent conversations.
- `docs\clean-room-shareability-test-2026-10-12.md` - No-cost clean-room preview result across both repos.
- `docs\t09-native-containerapp-closed-loop.md` - Azure-native Container App loop.
- `docs\sre-response-plan-automation.md` - Canonical setup, lifecycle and protocol-pin reference; start at its "Setup path at a glance". Dated rehearsal evidence is in its appendix.
- `docs\t10-sre-on-arc-experiment.md` - Arc-server assisted diagnostics and operator remediation experiment.
- `docs\t11-hybrid-diagnostics-wow.md` - Customer-facing hybrid diagnostics wow scene for LOB-on-Arc.
- `docs\t11-lob-app-on-arc-bridge.md` - Engineering evidence ledger for the LOB app running on an Arc server; not the current presenter source-of-truth.
- `docs\reskin-guide.md` - Skin variables schema, swap-list, and retargeting steps.

## Current validation stance

See the [dated non-presenter engineering ledger](docs/t10-sre-on-arc-experiment.md#historical-sre-configuration-and-t09-evidence)
for earlier cutover/T09 evidence and approval/audit limits. Those results do not
certify a newly reconstructed instance; current readiness and incident evidence
must be recorded separately.

- **T09 Container App:** live validated end to end with Azure Monitor handoff, SRE RCA, Review approval, SRE-executed repair, app recovery and actual MonitorCondition recovery.
- **T10 Arc server:** live validated for SRE-assisted diagnosis and Arc Run Command viability. Autonomous / SRE-executed Arc server repair is **not currently demo-ready**; treat it as possible future capability.
- **T11 LOB app on Arc:** live validated for Arc app fault signal, Log Analytics Event ID `4100`, Azure Monitor alerting, SRE incident creation, and operator Arc Run Command recovery. In the latest run, SRE RCA generation stalled before final diagnostic output, so do not present T11 as a proven SRE RCA or autonomous Arc app repair path. The sample is local; optionally provide your own source repository and commit.
