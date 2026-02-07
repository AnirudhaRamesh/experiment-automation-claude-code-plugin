---
name: experiment_loop_status
description: Show the status of all experiment loops (running, stopped, succeeded, failed)
user_invocable: true
model: haiku
---

Show the status of all experiment loops.

## What to do

### 1. Find all loops

List all directories under `.claude/loop-state/` in the repo root (`git rev-parse --show-toplevel`). Each directory is a loop. If the directory doesn't exist or is empty, tell the user there are no experiment loops.

### 2. Read each loop's state

For each loop directory, read `state.json` and extract:
- `loop_id`
- `status` (running, succeeded, failed_max_retries, failed_unrecoverable, needs_human, implementing, cancelled)
- `current_iteration` and `max_retries`
- `worktree_branch`
- `plan` (first 100 characters, truncated)
- From the latest iteration (last entry in `iterations[]`): `aichor_status`, `fixer_verdict`, `experiment_id`

### 3. Present a summary table

Format as a table:

```
Loop ID                        | Status      | Iter | Branch                  | Latest Experiment
-------------------------------|-------------|------|-------------------------|------------------
exp-loop-20260206-143022       | running     | 2/5  | exp-loop/exp-loop-...   | Failed → fixed
exp-loop-20260205-091500       | succeeded   | 1/3  | exp-loop/exp-loop-...   | Succeeded
```

### 4. For running/stopped loops, show monitoring tips

- Running: `tail -f .claude/loop-state/<loop-id>/progress.log`
- Stopped/failed: `Use /experiment-loop-resume to resume`
- Succeeded: `Final report at .claude/loop-state/<loop-id>/final-report.md`

### 5. If user asks about a specific loop

Read the full `state.json` and `progress.log` (last 30 lines) for that loop and give a detailed breakdown of each iteration.
