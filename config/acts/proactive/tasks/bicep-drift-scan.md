<!-- Written for this repo. The idea of a scheduled drift scan graded Benign, Risky and Critical follows microsoft/sre-agent labs/terraform-drift-detection at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md. -->
---
name: bicep-drift-scan
description: Read-only drift scan of the ticketing workload against its Bicep, graded Benign, Risky or Critical
cron: 30 8 * * 1-5
agent: estate-auditor
---
Run the Bicep drift scan on the ticketing workload with the bicep-drift-scan skill. It is read-only: change nothing, and propose each revert without running it. Report how many checks ran, the differences graded Benign, Risky or Critical, and what matched.
