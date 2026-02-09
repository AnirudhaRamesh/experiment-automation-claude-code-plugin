---
name: launch_and_monitor
description: Launch an AIChor experiment and automatically monitor it for completion with log analysis
user_invocable: true
model: sonnet
---

Launch an experiment on AIChor and automatically monitor it until completion.

Follow these steps in order:

## Step 1: Launch the experiment

Use the `aichor-experiment-launcher` agent (via the Task tool) to:
- Verify the manifest configuration
- Set appropriate Neptune tags
- Commit with "EXP: <message>" prefix
- Push to trigger the AIChor run

Wait for the launcher agent to complete and confirm the push was successful.

## Step 2: Find the monitor script

Locate `monitor-experiment.sh` by searching in order:
1. `.claude/scripts/monitor-experiment.sh` in the repo root (`git rev-parse --show-toplevel`)
2. If not found, search for `scripts/monitor-experiment.sh` relative to this skill file's directory (i.e., two levels up from the SKILL.md: `<plugin-root>/scripts/monitor-experiment.sh`)
3. If not found, search `~/.claude/plugins/**/scripts/monitor-experiment.sh`

Store the discovered path as `MONITOR_SCRIPT`.

## Step 3: Start monitoring

Once the push is confirmed, run the monitoring script in the background:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
nohup <MONITOR_SCRIPT> > "$REPO_ROOT/.claude/logs/aichor-monitor.log" 2>&1 &
```

Use `run_in_background: true` for the Bash tool call.

## Step 4: Report to user

Tell the user:
1. What experiment was launched (commit message, Neptune tags)
2. That monitoring has started in the background
3. That they can check progress with: `tail -f .claude/logs/aichor-monitor.log`
4. That when complete, the analysis will be saved to `.claude/analysis/`
