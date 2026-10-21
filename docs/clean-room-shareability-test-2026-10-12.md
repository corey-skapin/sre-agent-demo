# Clean-room shareability test - 2026-10-12

**Historical preview evidence, not a current bootstrap recipe.** This predates
the modern v3 Review-filter implementation and the 2026-10-20 T09 retry.
Use `sre-response-plan-automation.md` for current setup. Legacy MCP-create/browser
experiments below are historical only; do not repeat them to rebuild this demo.
The later in-place repair does not close the fresh deletion-to-Ready test gap.

## Scope

No-cost clean-room preview of the two-repo handoff workflow:

- Fresh clone of the operator-supplied Arc companion repository.
- Fresh clone of the operator-supplied SRE layer repository.
- Local Bicep/script validation
- Deployment `-WhatIf` previews against the current lab subscription
- No live resource creation, alert induction, or SRE portal mutation

Full live validation is still required before declaring the "send links to any SE
and deploy blindly" workflow production-ready, but the no-cost clean-room path now
passes and caught one important fix.

## Environment

| Item | Value |
|---|---|
| Clean-room path | An isolated local checkout; original path retained privately. |
| Subscription / tenant / account | Recorded privately for that run; runtime identities are not public handoff inputs. |
| Source revisions | Original run revisions retained privately, not public handoff defaults. |

## Checks run

### arc-demo

Passed:

- Fresh clone completed.
- `az bicep build --file .\bicep\main.bicep --stdout`.
- PowerShell parser check for `scripts\Deploy-ArcDemo.ps1`.
- Required docs present:
  - `README.md`
  - `AGENTS.md`
  - `docs\ai-deploy-handbook.md`
  - `docs\sql-arc-spike.md`
  - `docs\runsheet.md`
  - `docs\troubleshooting.md`
- `Deploy-ArcDemo.ps1 -WhatIf` completed against the lab subscription when a real
  `-AdminEmail` was supplied.

Issue found and fixed:

- The clean-room handbook command originally relied on updating the skin file for
  `notifications.email`. In a real AI-assisted run, an operator might forget this
  and push a placeholder email into budgets/action groups.
- Historical fix in `arc-demo`: `Deploy-ArcDemo.ps1` fails fast if
  `AdminEmail` is still a placeholder, and the AI handbook deploy command
  passes `-AdminEmail <EMAIL>` explicitly.

### sre-agent-demo

Passed:

- Fresh clone completed.
- `az bicep build --file .\infra\main.bicep --stdout`.
- PowerShell parser checks for:
  - `Deploy-SreAgent.ps1`
  - `Hibernate-SreAgent.ps1`
  - `Invoke-NativeContainerAppFault.ps1`
  - `Invoke-T10ArcFault.ps1`
  - `Invoke-LobArcAppOnArc.ps1`
  - `New-LobArcAppMonitorAlert.ps1`
- Required docs present:
  - `README.md`
  - `docs\ai-deploy-handbook.md`
  - `docs\sre-response-plan-automation.md`
  - `docs\delivery-runsheet.md`
  - `docs\t09-native-containerapp-closed-loop.md`
  - `docs\t10-sre-on-arc-experiment.md`
  - `docs\t11-lob-app-on-arc-bridge.md`
- `Deploy-SreAgent.ps1 -WhatIf` completed against the existing Arc demo estate.

Not live-tested in this no-cost run:

- `sreagent_agents_create` against a running SRE Agent.
- `sreagent_incidents_plans_create` after custom-agent creation.
- T09 alert induction and SRE thread creation from a fresh SRE deployment.
- Portal/browser fallback path.

## Verdict

**No-cost clean-room preview: pass with fix.**

At that historical revision the repos were shareable enough for an SE/AI assistant to clone, read the
handbooks, run local validation, and run no-cost deployment previews. The remaining
validation gap is the full live workflow:

1. Reactivate/deploy Arc demo from clean clone.
2. Deploy SRE layer from clean clone.
3. Reconstruct the custom agent through the pinned current-schema initializer.
4. Verify modern v3 filters, Review, literal titles and no duplicate routing.
5. Induce T09 and verify automatic handoff plus Review-mode repair.
6. Hibernate both layers.

That full live run is the next gate before calling the workflow "hands-off for any
SE."
