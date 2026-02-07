# AIChor Experiment Automation — Claude Code Plugin

Iterative AIChor experiment automation with auto-diagnosis, fix, and retry.

## Installation

```bash
claude --plugin-dir /path/to/this/repo
```

Then run `/setup` to configure your name, Slack channels, and Notion database.

## Prerequisites

- `aichor` CLI installed and authenticated
- `claude` CLI installed
- Git repo with `manifest.yaml` at root
- Claude.ai Slack/Notion integrations (optional)

## Required Permissions

Plugins can't bundle permissions. Add to `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Read", "Glob", "Grep", "Edit", "Write", "Bash(*)",
      "mcp__claude_ai_Slack__slack_send_message",
      "mcp__claude_ai_Slack__slack_read_channel",
      "mcp__claude_ai_Notion__notion-create-pages",
      "mcp__claude_ai_Notion__notion-fetch",
      "mcp__claude_ai_Notion__notion-update-page"
    ]
  }
}
```

Slack/Notion permissions are optional — only needed if you configure those integrations.

## Skills

### `/experiment-loop` — Full autopilot

The main entrypoint. Give it a plan and it handles everything:

1. Creates an isolated git worktree from your current branch
2. `experiment-implementer` agent makes the code changes
3. Commits with `EXP:` prefix and pushes (triggers AIChor)
4. Polls AIChor until the experiment completes
5. On failure: downloads logs, `experiment-log-analyzer` diagnoses, `experiment-fixer` patches
6. Loops back to step 3 until success or max retries
7. Slack/Notion notifications at each step

Your working directory stays untouched. State lives in `.claude/loop-state/<loop-id>/`.

### `/launch-and-monitor` — Single shot

Launches one experiment and monitors it. No auto-fix loop — just commit, push, poll, analyze. Good for when you've already made your changes and want to fire-and-forget.

### `/monitor` — Watch a running experiment

Attaches to the latest (or a specific) AIChor experiment. Polls until completion, downloads logs, runs the analyzer. Use when an experiment is already running.

### `/experiment-loop-status` — Dashboard

Shows all loops with their status, iteration count, and branch. Quick way to see what's running, succeeded, or needs attention.

### `/experiment-loop-resume` — Pick up where you left off

Resumes a stopped or failed loop. Detects which phase it died at (implement, launch, monitor, fix) and continues from there. Useful after laptop sleep or network interruption.

### `/check-experiment` — Pre-flight check

Validates `manifest.yaml`, shows uncommitted changes, and summarizes what will run. Run this before launching to catch config issues early.

### `/compare-configs` — Diff experiments

Compares `manifest.yaml` and config files between two branches/commits. Highlights changed hyperparameters, entrypoints, and resources.

### `/setup` — First-time configuration

Creates `.claude/experiment-automation.json` with your name, Slack channels, Notion database, and defaults. Run once per repo.
