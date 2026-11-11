# {customerName} demo estate (seed overview)

A person wrote this when the agent was built. It is not something the agent learned from an incident. The agent adds topic files beside it as it learns.

## Estate
- Arc-enabled Windows servers are Arc machine resources in {arcGroup}; the Azure VMs behind them are in {infraGroup}. Their Heartbeat, Perf and Event data is in the Log Analytics workspace {arcWorkspaceName}.
- Shared infrastructure, including those VMs, is in {infraGroup}.
<!-- T09 -->
- The Container App {containerApp} is in {infraGroup}.
<!-- /T09 -->
<!-- T12 -->
- Ticketing web app {appName} (App Service, Linux, Node) in {appGroup}. The alert rule {alertName} fires when POST /checkout fails.
- Releases are zip packages at {releaseUrlPrefix}TAG/ticketing-app-TAG.zip. The app runs from the package named in WEBSITE_RUN_FROM_PACKAGE, so a rollback sets it to the last good tag. Source: {repository}.
<!-- /T12 -->

## How this agent is run
- Every response plan and scheduled task is in Review mode: a change to Azure waits for a person to click Approve, and an approved card runs under the agent's own identity.
<!-- T12 -->
- GitHub issues ask first too. Two commands are denied outright: az group delete and az webapp delete.
<!-- /T12 -->

## Habits
- Say which command or query gave each fact. Judge "stopped reporting" by TimeGenerated, not by when a row arrived.
- Never print subscription, tenant or principal IDs.

## Topic files
architecture.md, debugging.md, deployment.md and logs.md are written by the agent. Read them first. Merge new facts into them; do not replace them.
