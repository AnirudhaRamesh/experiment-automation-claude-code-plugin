# AIChor Experiment Automation — Claude Code Plugin

Iterative AIChor experiment automation with auto-diagnosis, fix, and retry.

This plugin adds agents, skills, and scripts to Claude Code that orchestrate the full AIChor experiment lifecycle:

1. **Implement** an approved plan in an isolated git worktree
2. **Launch** on AIChor via `EXP:` commit + push
3. **Monitor** for completion with polling
4. **Analyze** logs automatically on failure
5. **Fix** code/config errors and retry
6. **Notify** via Slack and track in Notion

## Installation

### Option A: Plugin directory (development)

```bash
claude --plugin-dir /path/to/this/repo
```

### Option B: From marketplace (once published)

```bash
claude plugin install aichor-experiment-automation
```

## First-Time Setup

After installing, run the setup skill:

```
/setup
```

This will:
1. Create `.claude/experiment-automation.json` in your repo with your personal config
2. Verify prerequisites (aichor CLI, claude CLI, git repo)
3. Confirm the plugin is ready

### Manual Setup

Copy `config/template.json` to `.claude/experiment-automation.json` in your project repo and fill in your values:

```json
{
  "author_name": "Your Name",
  "slack_channels": [
    { "id": "C0ADJJTK0H0", "name": "#your-channel" }
  ],
  "notion_database": "collection://YOUR-NOTION-DATABASE-ID",
  "default_budget_usd": 10,
  "default_max_retries": 5
}
```

Add `.claude/experiment-automation.json` to your `.gitignore` — this file contains per-user configuration and should not be committed.

## Required Permissions

Plugins cannot bundle permission settings. Add these to your project's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Edit",
      "Write",
      "Bash(*)",
      "mcp__claude_ai_Slack__slack_send_message",
      "mcp__claude_ai_Slack__slack_read_channel",
      "mcp__claude_ai_Notion__notion-create-pages",
      "mcp__claude_ai_Notion__notion-fetch",
      "mcp__claude_ai_Notion__notion-update-page"
    ]
  }
}
```

The Slack and Notion permissions are optional — only needed if you configure those integrations.

## Prerequisites

- `aichor` CLI installed and authenticated
- `claude` CLI installed
- Git repository with AIChor experiment support (`manifest.yaml` at repo root)
- Claude.ai Slack integration enabled (optional, for notifications)
- Claude.ai Notion integration enabled (optional, for tracking)

## Available Skills

| Skill | Description |
|-------|-------------|
| `/experiment-loop` | Launch an iterative experiment loop with auto-fix and retry |
| `/experiment-loop-status` | Show status of all experiment loops |
| `/experiment-loop-resume` | Resume a stopped/failed loop |
| `/launch-and-monitor` | Launch and auto-monitor a single experiment |
| `/monitor` | Monitor the latest AIChor experiment |
| `/check-experiment` | Pre-launch health check |
| `/compare-configs` | Compare configs between branches/commits |
| `/setup` | First-time setup wizard |

## Available Agents

| Agent | Purpose |
|-------|---------|
| `aichor-experiment-launcher` | Commit + push to trigger AIChor runs |
| `experiment-log-analyzer` | Analyze experiment logs and error traces |
| `experiment-fixer` | Diagnose and fix failed experiments |
| `experiment-implementer` | Implement approved plans into code changes |
| `slack-notifier` | Send Slack notifications (reads channels from config) |
| `notion-tracker` | Track experiments in Notion (reads database from config) |

## How It Works

### Experiment Loop

The `/experiment-loop` skill is the main entrypoint. It:

1. Creates an isolated git worktree from your current branch
2. Invokes the `experiment-implementer` agent to make code changes
3. Commits with `EXP:` prefix and pushes (triggering AIChor)
4. Polls AIChor for experiment completion
5. On failure: downloads logs, runs `experiment-log-analyzer`, then `experiment-fixer`
6. If the fixer succeeds, loops back to step 3
7. Sends Slack/Notion notifications at each step

Your main working directory stays untouched throughout.

### State Management

Each loop creates state files under `.claude/loop-state/<loop-id>/`:
- `state.json` — full loop state with plan, iterations, verdicts
- `progress.log` — human-readable progress log
- `final-report.md` — summary report when the loop exits

### Configuration

The plugin reads from `.claude/experiment-automation.json` in your repo root. Each team member has their own config file (gitignored) with their Slack channels, Notion database, and preferences.

## Project Structure

```
aichor-experiment-automation/
├── .claude-plugin/plugin.json     # Plugin manifest
├── agents/                        # 6 agent definitions
├── skills/                        # 8 skill definitions
├── scripts/                       # Shell scripts for loop + monitoring
├── config/template.json           # Config template
└── README.md                      # This file
```
