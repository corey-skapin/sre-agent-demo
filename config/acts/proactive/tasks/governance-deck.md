<!-- Written for this repo. The weekly governance deck follows microsoft/sre-agent labs/zava-learning (sre-config/scheduled-tasks) at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md. -->
---
name: governance-deck
description: Weekly governance review deck (PowerPoint) built from read-only facts
cron: 0 9 * * 1
agent: deck-builder
---
Build the governance review deck with the governance-deck skill. Gather the facts read-only, build the PowerPoint with python-pptx and save it in this thread's files folder. If python-pptx is not available, report the same content as Markdown and say the deck was not built. Change nothing.
