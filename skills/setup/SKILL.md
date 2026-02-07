---
name: setup
description: First-time setup for the AIChor experiment automation plugin
user_invocable: true
model: sonnet
---

Guide the user through first-time setup of the AIChor experiment automation plugin.

## What to do

### 1. Check if already configured

Look for `.claude/experiment-automation.json` in the repo root (`git rev-parse --show-toplevel`).

If it exists, read it and show the current configuration. Ask if the user wants to update it.

### 2. Gather configuration

If no config exists (or user wants to reconfigure), ask the user for:

- **Author name** — used for filtering experiments on AIChor (default: output of `git config user.name`)
- **Slack channels** — list of Slack channel IDs and names to send notifications to (optional)
- **Notion database** — the `collection://` URI of a Notion database for experiment tracking (optional)
- **Default budget** — max USD per claude -p call in the experiment loop (default: 10)
- **Default max retries** — how many times to retry failed experiments (default: 5)

### 3. Create the config file

Write `.claude/experiment-automation.json` in the repo root with the gathered values:

```json
{
  "author_name": "Their Name",
  "slack_channels": [
    { "id": "CHANNEL_ID", "name": "#channel-name" }
  ],
  "notion_database": "collection://DATABASE-ID",
  "default_budget_usd": 10,
  "default_max_retries": 5
}
```

If the user skips Slack or Notion, use empty arrays / empty strings.

### 4. Verify prerequisites

Check that the following are available:
- `aichor` CLI: run `which aichor` or `aichor --version`
- `claude` CLI: run `which claude` or `claude --version`
- Git repository: run `git rev-parse --show-toplevel`
- `manifest.yaml` exists in the repo root

Report any missing prerequisites.

### 5. Remind about permissions

Tell the user they need to add permissions to their `.claude/settings.local.json` if they haven't already. Point them to the plugin README for the full permissions list.

### 6. Confirm setup

Tell the user:
- Config file location
- What's configured (Slack, Notion, or neither)
- That they can now use `/experiment-loop`, `/launch-and-monitor`, `/monitor`, etc.
- To re-run `/setup` anytime to update their configuration
