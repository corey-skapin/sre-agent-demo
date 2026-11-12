# Notices

Some files in this repository are adapted from Microsoft's open-source
[microsoft/sre-agent](https://github.com/microsoft/sre-agent) repository (its
`labs/onboardinglab`, `labs/terraform-drift-detection` and `labs/zava-learning`),
which is licensed under the MIT License. Each adapted file says so in a comment at
its top and points here. They were adapted from commit
`e6afdfc8a5e446b488325118b0c07da7c3d8462a`:

| File here | Adapted from |
| --- | --- |
| `infra/ticketing/workload.bicep` | `labs/onboardinglab/ticketingapp-source/modules/workload.bicep` |
| `config/t12/skills/azure-monitor-rca.md` | `labs/onboardinglab/workflow-templates/plugin/skills/azure-monitor-rca/SKILL.md` |
| `config/t12/skills/github-issue-followup.md` | `labs/onboardinglab/workflow-templates/plugin/skills/github-issue-followup/SKILL.md` |
| `config/t12/hooks/release-closing-check.md` | `labs/onboardinglab/agent-recipe/config/hooks/evidence-checklist.yaml` |
| `config/acts/ask/skills/estate-query.md` | The shape of a skill file in `labs/onboardinglab/workflow-templates/plugin/skills` |
| `config/acts/arc/skills/arc-server-repair.md` | The shape of a skill file in `labs/onboardinglab/workflow-templates/plugin/skills` |
| `config/acts/proactive/skills/estate-health-check.md` | `labs/onboardinglab/workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml` and `labs/onboardinglab/workflow-templates/plugin/skills/proactive-health-check/SKILL.md` |
| `config/acts/proactive/skills/bicep-drift-scan.md` | `labs/terraform-drift-detection/skills/terraform-drift-analysis.md` and `labs/terraform-drift-detection/scripts/induce-drift.ps1` |
| `config/acts/proactive/skills/governance-deck.md` | `labs/zava-learning/sre-config/agent-config/skills/zava-audit-report/SKILL.md`, `nsg-audit/SKILL.md` and `rbac-audit/SKILL.md` |
| `config/acts/proactive/agents/estate-auditor.md` | The idea of read-only auditor agents: `labs/zava-learning/sre-config/agent-config/agents` and `labs/onboardinglab/workflow-templates/scheduled-tasks` |
| `config/acts/proactive/agents/deck-builder.md` | `labs/zava-learning/sre-config/agent-config/skills/zava-audit-report/SKILL.md` |
| `config/acts/proactive/tasks/estate-health-check.md` | The task shape in `labs/onboardinglab/workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml` |
| `config/acts/proactive/tasks/bicep-drift-scan.md` | The idea of a scheduled drift scan graded Benign, Risky and Critical in `labs/terraform-drift-detection` |
| `config/acts/proactive/tasks/governance-deck.md` | The weekly governance deck in `labs/zava-learning/sre-config/scheduled-tasks` |
| `scripts/Invoke-DriftDemo.ps1` | The two tag names and the Benign, Risky and Critical pattern of `labs/terraform-drift-detection/scripts/induce-drift.ps1` |

The ticketing application that the T12 scenario deploys is a separate repository
with its own notice: an attributed import of the same lab's application.

## MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
