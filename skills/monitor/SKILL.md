---
name: monitor
description: Monitor the latest AIChor experiment, download logs on completion, and auto-analyze
user_invocable: true
model: haiku
---

Monitor the latest AIChor experiment.

## Step 1: Find the monitor script

Locate `monitor-experiment.sh` by searching in order:
1. `.claude/scripts/monitor-experiment.sh` in the repo root (`git rev-parse --show-toplevel`)
2. If not found, search for `scripts/monitor-experiment.sh` relative to this skill file's directory (i.e., two levels up from the SKILL.md: `<plugin-root>/scripts/monitor-experiment.sh`)
3. If not found, search `~/.claude/plugins/**/scripts/monitor-experiment.sh`

Store the discovered path as `MONITOR_SCRIPT`.

## Step 2: Run the monitoring script in the background

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
nohup <MONITOR_SCRIPT> > "$REPO_ROOT/.claude/logs/aichor-monitor.log" 2>&1 &
```

Use `run_in_background: true` for the Bash tool call.

After launching, tell the user:
1. That monitoring has started
2. The experiment ID being monitored
3. That they can check progress with: `tail -f .claude/logs/aichor-monitor.log`
4. That when complete, the analysis will be saved to `.claude/analysis/`

If the user provides a specific experiment ID, pass it as an argument:
```bash
nohup <MONITOR_SCRIPT> <experiment-id> > "$REPO_ROOT/.claude/logs/aichor-monitor.log" 2>&1 &
```
