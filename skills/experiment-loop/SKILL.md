---
name: experiment_loop
description: Launch an iterative experiment loop that auto-diagnoses failures, applies fixes, and retries — all in an isolated git worktree
user_invocable: true
model: sonnet
---

Launch an iterative experiment loop from an approved plan.

The loop creates a git worktree, implements the plan, launches on AIChor, monitors for completion, and automatically fixes + retries on failure. Your main working directory stays untouched.

## What to do

### 1. Get the plan

The user should have an approved plan ready. Ask them to provide it as either:
- A **plan file path** (e.g., a `.md` file from a previous plan mode session)
- **Inline text** describing the experiment

If the user hasn't provided a plan yet, ask them to describe what experiment they want to run.

### 2. Confirm settings

Ask the user:
- **Max retries** (default: 5) — how many times to retry on failure before stopping
- **Base branch** (default: current branch) — which branch to fork the worktree from

### 3. Find the experiment-loop script

Locate `experiment-loop.sh` by searching in order:
1. `.claude/scripts/experiment-loop.sh` in the repo root (`git rev-parse --show-toplevel`)
2. If not found, search for `scripts/experiment-loop.sh` relative to this skill file's directory (i.e., two levels up from the SKILL.md: `<plugin-root>/scripts/experiment-loop.sh`)
3. If not found, search `~/.claude/plugins/**/scripts/experiment-loop.sh`

Store the discovered path as `LOOP_SCRIPT`.

### 4. Launch the loop

Run the experiment loop script in the background with `caffeinate -i` to prevent idle sleep:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
caffeinate -i nohup <LOOP_SCRIPT> \
    --plan-file <path> \
    --max-retries <N> \
    > "$REPO_ROOT/.claude/logs/experiment-loop.log" 2>&1 &
```

Or with inline plan:
```bash
caffeinate -i nohup <LOOP_SCRIPT> \
    --plan "plan text here" \
    --max-retries <N> \
    > "$REPO_ROOT/.claude/logs/experiment-loop.log" 2>&1 &
```

Use `run_in_background: true` for the Bash tool call.

### 5. Report to user

Tell the user:
1. The **loop ID** (from the log output — it will appear as `SETUP: Loop ID: exp-loop-YYYYMMDD-HHMMSS`)
2. How to **monitor progress**: `tail -f .claude/loop-state/<loop-id>/progress.log`
3. That the **final report** will be at `.claude/loop-state/<loop-id>/final-report.md`
4. **Check all loops**: `/experiment-loop-status`
5. **Resume a stopped loop**: `/experiment-loop-resume`
6. Note: if the laptop lid is closed, the loop will suspend. Use `/experiment-loop-resume` when you're back.
