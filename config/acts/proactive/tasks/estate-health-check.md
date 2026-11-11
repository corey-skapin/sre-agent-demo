<!-- Written for this repo. The task shape (a cron schedule, a custom agent, Review mode) follows microsoft/sre-agent labs/onboardinglab (workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml) at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md. -->
---
name: estate-health-check
description: Read-only health check of the ticketing app, its alert rules and the Arc estate
cron: 0 8 * * 1-5
agent: estate-auditor
---
Run the estate health check with the estate-health-check skill. It is read-only: change nothing, create no GitHub issue and save no notes. Give each area a verdict with its evidence, then list at most three items that need a person.
