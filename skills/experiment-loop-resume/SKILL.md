---
name: experiment_loop_resume
description: Resume a stopped or failed experiment loop from where it left off
user_invocable: true
model: sonnet
---

Resume a stopped experiment loop.

## What to do

### 1. Find resumable loops

List all directories under `.claude/loop-state/` in the repo root (`git rev-parse --show-toplevel`). Read each `state.json` and identify loops that are **not** in a terminal success state. Resumable loops have status:
- `running` (crashed/killed mid-execution)
- `implementing` (crashed during plan implementation)
- `failed_max_retries` (can resume with more retries)
- `failed_unrecoverable` (user may want to retry after manual fix)
- `needs_human` (user may have made a fix and wants to continue)

Do NOT show loops with status `succeeded`.

If there are no resumable loops, tell the user and exit.

### 2. Show resumable loops

Present each resumable loop with:
- Loop ID
- Status and which phase it stopped at
- Current iteration / max retries
- Branch name
- Plan summary (first 100 chars)
- Last error or fixer verdict (if any)

If there's only one resumable loop, suggest it. If multiple, ask the user which one to resume.

### 3. Ask about max retries

If the loop stopped due to `failed_max_retries`, ask the user if they want to increase the retry limit (pass `--max-retries N` on resume).

### 4. Find the experiment-loop script

Locate `experiment-loop.sh` by searching in order:
1. `.claude/scripts/experiment-loop.sh` in the repo root (`git rev-parse --show-toplevel`)
2. If not found, search `~/.claude/plugins/**/scripts/experiment-loop.sh`

Store the discovered path as `LOOP_SCRIPT`.

### 5. Launch the resume

Run the experiment loop script in the background:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
caffeinate -i nohup <LOOP_SCRIPT> \
    --resume <loop-id> \
    > "$REPO_ROOT/.claude/logs/experiment-loop.log" 2>&1 &
```

Use `run_in_background: true` for the Bash tool call.

### 6. Report to user

Tell the user:
1. Which loop was resumed and at what phase
2. Monitor with: `tail -f .claude/loop-state/<loop-id>/progress.log`
3. Check status with: `/experiment-loop-status`
