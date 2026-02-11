#!/usr/bin/env bash
set -euo pipefail

# Experiment Loop — Iterative experiment runner with auto-diagnosis and retry.
#
# Creates a git worktree, implements an approved plan, launches on AIChor,
# monitors for completion, and automatically fixes + retries on failure.
#
# Usage:
#   experiment-loop.sh --plan-file <path>      # path to approved plan (.md)
#   experiment-loop.sh --plan "inline text"    # inline plan description
#   experiment-loop.sh --resume <loop-id>      # resume a stopped loop
#
# Options:
#   --max-retries N     (default: 5)
#   --branch NAME       base branch to fork from (default: current)
#   --budget N          budget per claude -p call in USD (default: 10)

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_BASE_DIR="$REPO_ROOT/.claude/loop-state"
WORKTREE_BASE_DIR="$REPO_ROOT/.claude/worktrees"

# --- Plugin config ---
CONFIG_FILE="$REPO_ROOT/.claude/experiment-automation.json"
read_config() {
    local key="$1"
    local default="${2:-}"
    if [[ -f "$CONFIG_FILE" ]]; then
        python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$key', '$default'))" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# --- Defaults (read from config, with fallbacks) ---
MAX_RETRIES=$(read_config "default_max_retries" "5")
BASE_BRANCH=""
BUDGET=$(read_config "default_budget_usd" "10")
PLAN_FILE=""
PLAN_TEXT=""
RESUME_ID=""

# --- Logging helpers ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    if [[ -n "${PROGRESS_LOG:-}" ]]; then
        echo "$msg" >> "$PROGRESS_LOG"
    fi
}

# --- Parse arguments ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan-file)
            PLAN_FILE="$2"
            shift 2
            ;;
        --plan)
            PLAN_TEXT="$2"
            shift 2
            ;;
        --resume)
            RESUME_ID="$2"
            shift 2
            ;;
        --max-retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
        --branch)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --budget)
            BUDGET="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# --- State management helpers ---

read_state_field() {
    local field="$1"
    python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('$field', ''))"
}

read_state_int() {
    local field="$1"
    python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('$field', 0))"
}

update_state_field() {
    local field="$1"
    local value="$2"
    python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    d = json.load(f)
d['$field'] = $value
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
}

update_state_status() {
    update_state_field "status" "\"$1\""
}

add_iteration() {
    local iteration="$1"
    python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    d = json.load(f)
d['iterations'].append({
    'iteration': $iteration,
    'experiment_name': None,
    'experiment_id': None,
    'commit_hash': None,
    'aichor_status': None,
    'analysis_path': None,
    'log_path': None,
    'fixer_verdict': None,
    'fixer_summary': None,
    'fixer_detail': None,
    'changes_made': []
})
d['current_iteration'] = $iteration
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
}

update_iteration_field() {
    local iteration="$1"
    local field="$2"
    local value="$3"
    python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    d = json.load(f)
for it in d['iterations']:
    if it['iteration'] == $iteration:
        it['$field'] = $value
        break
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
}

get_iteration_field() {
    local iteration="$1"
    local field="$2"
    python3 -c "
import json
d = json.load(open('$STATE_FILE'))
for it in d['iterations']:
    if it['iteration'] == $iteration:
        val = it.get('$field')
        print(val if val is not None else '')
        break
"
}

# --- Notification functions ---

send_notion_plan() {
    log "NOTIFY: Creating Notion tracking page..."

    local notion_output
    notion_output=$(claude -p \
        --agent notion-tracker \
        --dangerously-skip-permissions \
        --max-budget-usd 2 \
        "action: create_tracking_page
state_file: $STATE_FILE" 2>&1) || true

    # Extract page IDs from output
    local page_id log_page_id
    page_id=$(echo "$notion_output" | grep -o 'NOTION_PAGE_ID: [^ ]*' | head -1 | sed 's/NOTION_PAGE_ID: //' || true)
    log_page_id=$(echo "$notion_output" | grep -o 'NOTION_LOG_PAGE_ID: [^ ]*' | head -1 | sed 's/NOTION_LOG_PAGE_ID: //' || true)

    if [[ -n "$page_id" ]]; then
        update_state_field "notion_page_id" "\"$page_id\""
        log "NOTIFY: Notion page created: $page_id"
    else
        log "NOTIFY: WARNING: Could not capture Notion page ID"
    fi
    if [[ -n "$log_page_id" ]]; then
        update_state_field "notion_log_page_id" "\"$log_page_id\""
        log "NOTIFY: Notion log page created: $log_page_id"
    else
        log "NOTIFY: WARNING: Could not capture Notion log page ID"
    fi
}

send_iteration_notifications() {
    local status="$1"
    local detail_level="${2:-concise}"

    # Slack notification (background)
    (
        claude -p \
            --agent slack-notifier \
            --dangerously-skip-permissions \
            --max-budget-usd 1 \
            "action: iteration_complete
state_file: $STATE_FILE
status: $status
detail_level: $detail_level" > /dev/null 2>&1
    ) &

    # Notion log append (background)
    local log_page_id
    log_page_id=$(read_state_field "notion_log_page_id")
    if [[ -n "$log_page_id" && "$log_page_id" != "None" ]]; then
        (
            claude -p \
                --agent notion-tracker \
                --dangerously-skip-permissions \
                --max-budget-usd 1 \
                "action: append_iteration
state_file: $STATE_FILE
notion_log_page_id: $log_page_id
status: $status" > /dev/null 2>&1
        ) &
    fi

    log "NOTIFY: Sent iteration notifications (background)"
}

update_notion_status() {
    local loop_status="$1"

    local page_id
    page_id=$(read_state_field "notion_page_id")
    if [[ -n "$page_id" && "$page_id" != "None" ]]; then
        (
            claude -p \
                --agent notion-tracker \
                --dangerously-skip-permissions \
                --max-budget-usd 1 \
                "action: update_status
state_file: $STATE_FILE
notion_page_id: $page_id
status: $loop_status" > /dev/null 2>&1
        ) &
        log "NOTIFY: Updating Notion status for '$loop_status' (background)"
    fi
}

# --- Resume or Initialize ---

if [[ -n "$RESUME_ID" ]]; then
    # Resume existing loop
    LOOP_ID="$RESUME_ID"
    STATE_DIR="$STATE_BASE_DIR/$LOOP_ID"
    STATE_FILE="$STATE_DIR/state.json"
    PROGRESS_LOG="$STATE_DIR/progress.log"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "ERROR: State file not found: $STATE_FILE" >&2
        exit 1
    fi

    log "RESUME: Resuming loop $LOOP_ID"

    WORKTREE_PATH=$(read_state_field "worktree_path")
    MAX_RETRIES=$(read_state_int "max_retries")
    CURRENT_ITERATION=$(read_state_int "current_iteration")

    # Check worktree still exists
    if [[ ! -d "$WORKTREE_PATH" ]]; then
        log "ERROR: Worktree no longer exists at $WORKTREE_PATH"
        exit 1
    fi

    # Determine resume point based on state
    LOOP_STATUS=$(read_state_field "status")

    if [[ $CURRENT_ITERATION -eq 0 ]]; then
        # Died during or before implementation
        RESUME_PHASE="implement"
        CURRENT_ITERATION=1
        log "RESUME: Loop died during implementation, will re-run implementer"
    else
        LAST_COMMIT=$(get_iteration_field "$CURRENT_ITERATION" "commit_hash")
        LAST_STATUS=$(get_iteration_field "$CURRENT_ITERATION" "aichor_status")
        LAST_VERDICT=$(get_iteration_field "$CURRENT_ITERATION" "fixer_verdict")

        if [[ -z "$LAST_COMMIT" || "$LAST_COMMIT" == "None" ]]; then
            # Never pushed — re-launch this iteration
            RESUME_PHASE="launch"
        elif [[ -z "$LAST_STATUS" || "$LAST_STATUS" == "None" ]]; then
            # Pushed but never got monitoring result — resume monitoring
            RESUME_PHASE="monitor"
        elif [[ "$LAST_STATUS" == "Failed" && ( -z "$LAST_VERDICT" || "$LAST_VERDICT" == "None" ) ]]; then
            # Failed but fixer never ran — run fixer
            RESUME_PHASE="fix"
        elif [[ "$LAST_VERDICT" == "fixed" ]]; then
            # Fixer ran, start next iteration
            CURRENT_ITERATION=$((CURRENT_ITERATION + 1))
            RESUME_PHASE="launch"
        else
            # Other terminal state — just evaluate
            RESUME_PHASE="evaluate"
        fi
    fi

    # Log Notion page IDs if they exist
    NOTION_PID=$(read_state_field "notion_page_id")
    NOTION_LOG_PID=$(read_state_field "notion_log_page_id")
    if [[ -n "$NOTION_PID" && "$NOTION_PID" != "None" ]]; then
        log "RESUME: Notion page: $NOTION_PID, log page: $NOTION_LOG_PID"
    fi

    log "RESUME: Resuming at phase=$RESUME_PHASE, iteration=$CURRENT_ITERATION"

else
    # Fresh start — validate inputs
    if [[ -z "$PLAN_FILE" && -z "$PLAN_TEXT" ]]; then
        echo "ERROR: Must provide --plan-file or --plan" >&2
        exit 1
    fi

    # Read plan content
    if [[ -n "$PLAN_FILE" ]]; then
        if [[ ! -f "$PLAN_FILE" ]]; then
            echo "ERROR: Plan file not found: $PLAN_FILE" >&2
            exit 1
        fi
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    else
        PLAN_CONTENT="$PLAN_TEXT"
    fi

    # Determine base branch
    if [[ -z "$BASE_BRANCH" ]]; then
        BASE_BRANCH=$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD)
    fi

    # Generate loop ID
    LOOP_ID="exp-loop-$(date '+%Y%m%d-%H%M%S')"
    STATE_DIR="$STATE_BASE_DIR/$LOOP_ID"
    STATE_FILE="$STATE_DIR/state.json"
    PROGRESS_LOG="$STATE_DIR/progress.log"
    WORKTREE_PATH="$WORKTREE_BASE_DIR/$LOOP_ID"
    WORKTREE_BRANCH="exp-loop/$LOOP_ID"

    mkdir -p "$STATE_DIR" "$WORKTREE_BASE_DIR"

    log "SETUP: Loop ID: $LOOP_ID"
    log "SETUP: Base branch: $BASE_BRANCH"
    log "SETUP: Max retries: $MAX_RETRIES"

    # Create worktree
    log "SETUP: Creating worktree at $WORKTREE_PATH"
    cd "$REPO_ROOT" && git worktree add "$WORKTREE_PATH" -b "$WORKTREE_BRANCH" HEAD
    log "SETUP: Worktree created on branch $WORKTREE_BRANCH"

    # Initialize state file — write plan to temp file first to avoid shell quoting issues
    PLAN_TEMP=$(mktemp)
    if [[ -n "$PLAN_FILE" ]]; then
        cp "$PLAN_FILE" "$PLAN_TEMP"
    else
        printf '%s' "$PLAN_TEXT" > "$PLAN_TEMP"
    fi

    python3 - "$LOOP_ID" "$PLAN_TEMP" "$PLAN_FILE" "$BASE_BRANCH" "$WORKTREE_PATH" "$WORKTREE_BRANCH" "$MAX_RETRIES" "$STATE_FILE" <<'PYEOF'
import json, sys

loop_id, plan_temp, plan_file, base_branch, wt_path, wt_branch, max_retries, state_file = sys.argv[1:9]

with open(plan_temp) as f:
    plan_content = f.read()

# Extract heading: markdown heading first, then first non-empty line
experiment_name = None
first_line = None
for line in plan_content.split('\n'):
    line = line.strip()
    if line.startswith('# '):
        experiment_name = line.lstrip('# ').strip()
        break
    elif first_line is None and line:
        first_line = line
if experiment_name is None and first_line:
    experiment_name = first_line

state = {
    "loop_id": loop_id,
    "plan": plan_content,
    "plan_file": plan_file if plan_file else None,
    "original_branch": base_branch,
    "worktree_path": wt_path,
    "worktree_branch": wt_branch,
    "max_retries": int(max_retries),
    "current_iteration": 0,
    "status": "running",
    "experiment_name": experiment_name,
    "notion_page_id": None,
    "notion_log_page_id": None,
    "iterations": []
}
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
PYEOF
    rm -f "$PLAN_TEMP"
    log "SETUP: State file initialized at $STATE_FILE"

    CURRENT_ITERATION=1
    RESUME_PHASE="implement"

    # Create Notion tracking page (foreground — we need the IDs)
    send_notion_plan
fi

# --- Implementation function (used by both fresh start and resume) ---

run_implementer() {
    log "IMPLEMENT: Running experiment-implementer agent..."
    update_state_status "implementing"

    claude -p \
        --agent experiment-implementer \
        --model opus \
        --dangerously-skip-permissions \
        --allowedTools "Glob Grep Read Write Edit Bash Task" \
        --max-budget-usd "$BUDGET" \
        "Implement the approved experiment plan.

State file: $STATE_FILE

Read the state file to get the plan and the worktree_path.
All file changes must be made inside the worktree at: $WORKTREE_PATH

Do NOT commit or push — just make the code/config changes described in the plan." > /dev/null 2>&1

    # Log what changed in the worktree
    CHANGED_FILES=$(cd "$WORKTREE_PATH" && git diff --name-only 2>/dev/null || echo "(could not determine)")
    log "IMPLEMENT: Done. Changed files: $CHANGED_FILES"
    update_state_status "running"
}

# --- Main Loop ---

write_final_report() {
    local final_status="$1"
    local report_path="$STATE_DIR/final-report.md"

    python3 - "$STATE_FILE" "$final_status" "$report_path" <<'PYEOF'
import json, sys

state_file, final_status, report_path = sys.argv[1:4]

with open(state_file) as f:
    state = json.load(f)

lines = ["# Experiment Loop Final Report", ""]
lines.append(f"**Loop ID**: {state['loop_id']}")
lines.append(f"**Status**: {final_status}")
lines.append(f"**Iterations**: {len(state['iterations'])}")
lines.append(f"**Branch**: {state['worktree_branch']}")
lines.append("")
lines.append("## Plan")
lines.append(state["plan"])
lines.append("")
lines.append("## Iterations")

for it in state["iterations"]:
    lines.append(f"### Iteration {it['iteration']}")
    lines.append(f"- **Experiment ID**: {it.get('experiment_id', 'N/A')}")
    lines.append(f"- **Commit**: {it.get('commit_hash', 'N/A')}")
    lines.append(f"- **AIChor Status**: {it.get('aichor_status', 'N/A')}")
    lines.append(f"- **Fixer Verdict**: {it.get('fixer_verdict', 'N/A')}")
    lines.append(f"- **Summary**: {it.get('fixer_summary', 'N/A')}")
    if it.get("fixer_detail"):
        lines.append(f"- **Detail**: {it['fixer_detail']}")
    if it.get("analysis_path"):
        lines.append(f"- **Analysis**: {it['analysis_path']}")
    lines.append("")

with open(report_path, "w") as f:
    f.write("\n".join(lines))
PYEOF
    log "DONE: Final report written to $report_path"
}

exit_loop() {
    local status="$1"
    local exit_code="${2:-0}"
    update_state_status "$status"
    write_final_report "$status"

    # Send final notifications (detailed for loop exit)
    send_iteration_notifications "$status" "detailed" || true
    update_notion_status "$status" || true

    log "DONE: $status (exit $exit_code)"
    # Wait for background notification jobs to finish
    wait 2>/dev/null || true
    exit "$exit_code"
}

while true; do

    # --- IMPLEMENT (first iteration or resume after failed implementation) ---
    if [[ "$RESUME_PHASE" == "implement" ]]; then
        run_implementer
        RESUME_PHASE="launch"
    fi

    # --- Check max retries ---
    if [[ $CURRENT_ITERATION -gt $MAX_RETRIES ]]; then
        log "DONE: Max retries ($MAX_RETRIES) reached"
        exit_loop "failed_max_retries" 1
    fi

    # --- LAUNCH ---
    if [[ "$RESUME_PHASE" == "launch" ]]; then
        # Add new iteration to state (only if not resuming mid-iteration)
        EXISTING_ITER=$(get_iteration_field "$CURRENT_ITERATION" "iteration" 2>/dev/null || echo "")
        if [[ -z "$EXISTING_ITER" || "$EXISTING_ITER" == "None" || "$EXISTING_ITER" == "" ]]; then
            add_iteration "$CURRENT_ITERATION"
        fi

        log "LAUNCH [iter $CURRENT_ITERATION]: Launching via aichor-experiment-launcher agent..."

        # Build suggested commit message from experiment_name in state + (iter-N)
        PLAN_HEADING=$(read_state_field "experiment_name")

        # Strip any existing iter-N suffix to avoid accumulation on retries
        PLAN_HEADING=$(echo "$PLAN_HEADING" | sed 's/ iter-[0-9]*$//')

        COMMIT_MSG_HINT=""
        if [[ -n "$PLAN_HEADING" && "$PLAN_HEADING" != "None" && "$PLAN_HEADING" != "null" ]]; then
            SUFFIX=" iter-$CURRENT_ITERATION"
            MAX_HEADING_LEN=$((67 - ${#SUFFIX}))
            SANITIZED=$(echo "$PLAN_HEADING" | tr -d '=()`' | tr ':—' '- ' | tr -s ' ' | sed 's/^ //;s/ $//')
            COMMIT_MSG_HINT="${SANITIZED:0:$MAX_HEADING_LEN}$SUFFIX"
            COMMIT_MSG_HINT="Suggested commit message: $COMMIT_MSG_HINT"
        fi

        # Read the plan for context
        PLAN_TEXT=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    print(json.load(f)['plan'])
" 2>/dev/null || echo "(could not read plan)")

        # Random backoff (5-30s) to avoid rate limits with parallel loops
        BACKOFF=$((RANDOM % 26 + 5))
        log "LAUNCH [iter $CURRENT_ITERATION]: Backoff ${BACKOFF}s before launching agent..."
        sleep "$BACKOFF"

        LAUNCHER_OUTPUT=$(cd "$WORKTREE_PATH" && claude -p \
            --agent aichor-experiment-launcher \
            --dangerously-skip-permissions \
            --allowedTools "Glob Grep Read Edit Write Bash" \
            --max-budget-usd "$BUDGET" \
            "Launch this experiment on AIChor. You are in the worktree directory already.

Plan:
$PLAN_TEXT

$COMMIT_MSG_HINT

This is iteration $CURRENT_ITERATION of the experiment loop." 2>&1) || {
            log "LAUNCH [iter $CURRENT_ITERATION]: ERROR: launcher agent failed"
            log "LAUNCH [iter $CURRENT_ITERATION]: Output: $LAUNCHER_OUTPUT"
            exit_loop "failed_unrecoverable" 1
        }

        COMMIT_HASH=$(cd "$WORKTREE_PATH" && git log --format="%H" -1 2>/dev/null || echo "unknown")

        update_iteration_field "$CURRENT_ITERATION" "commit_hash" "\"$COMMIT_HASH\""

        # Extract experiment name from commit message (the part after "EXP: ")
        EXPERIMENT_NAME=$(cd "$WORKTREE_PATH" && git log --format="%s" -1 2>/dev/null | sed 's/^EXP: //' || echo "")
        if [[ -n "$EXPERIMENT_NAME" ]]; then
            update_iteration_field "$CURRENT_ITERATION" "experiment_name" "\"$EXPERIMENT_NAME\""
            update_state_field "experiment_name" "\"$EXPERIMENT_NAME\""
        fi

        log "LAUNCH [iter $CURRENT_ITERATION]: Pushed commit $COMMIT_HASH ($EXPERIMENT_NAME)"
    fi

    # --- MONITOR (skip if resuming at fix phase — analysis already exists) ---
    if [[ "$RESUME_PHASE" != "fix" ]]; then
        log "MONITOR [iter $CURRENT_ITERATION]: Polling for experiment completion..."

        MONITOR_OUTPUT=$("$SCRIPTS_DIR/monitor-experiment.sh" --worktree "$WORKTREE_PATH" 2>&1 || true)

        # Parse the LOOP_DATA JSON block from monitor output
        LOOP_DATA=$(echo "$MONITOR_OUTPUT" | sed -n '/===LOOP_DATA===/,/===END_LOOP_DATA===/p' | grep -v '===')

        if [[ -n "$LOOP_DATA" ]]; then
            EXPERIMENT_ID=$(echo "$LOOP_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment_id'])")
            AICHOR_STATUS=$(echo "$LOOP_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
            ANALYSIS_PATH=$(echo "$LOOP_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['analysis_path'])")
            LOG_PATH_VAL=$(echo "$LOOP_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['log_path'])")
        else
            log "MONITOR [iter $CURRENT_ITERATION]: WARNING: Could not parse monitor output"
            EXPERIMENT_ID="unknown"
            AICHOR_STATUS="Failed"
            ANALYSIS_PATH=""
            LOG_PATH_VAL=""
        fi

        update_iteration_field "$CURRENT_ITERATION" "experiment_id" "\"$EXPERIMENT_ID\""
        update_iteration_field "$CURRENT_ITERATION" "aichor_status" "\"$AICHOR_STATUS\""
        if [[ -n "$ANALYSIS_PATH" ]]; then
            update_iteration_field "$CURRENT_ITERATION" "analysis_path" "\"$ANALYSIS_PATH\""
        else
            update_iteration_field "$CURRENT_ITERATION" "analysis_path" "None"
        fi
        if [[ -n "$LOG_PATH_VAL" ]]; then
            update_iteration_field "$CURRENT_ITERATION" "log_path" "\"$LOG_PATH_VAL\""
        else
            update_iteration_field "$CURRENT_ITERATION" "log_path" "None"
        fi

        log "MONITOR [iter $CURRENT_ITERATION]: Experiment $AICHOR_STATUS. Analysis at $ANALYSIS_PATH"
    else
        # Resuming at fix — read status from state file
        AICHOR_STATUS=$(get_iteration_field "$CURRENT_ITERATION" "aichor_status")
        log "FIX-RESUME [iter $CURRENT_ITERATION]: Skipping monitor, status from state: $AICHOR_STATUS"
    fi

    # Reset resume phase so subsequent loop iterations run normally
    RESUME_PHASE=""

    # --- EVALUATE ---
    case "$AICHOR_STATUS" in
        "Succeeded")
            log "DONE: Succeeded on iteration $CURRENT_ITERATION"
            exit_loop "succeeded" 0
            ;;
        "Cancelled")
            log "DONE: Experiment was cancelled"
            exit_loop "cancelled" 1
            ;;
        "Failed")
            log "EVALUATE [iter $CURRENT_ITERATION]: Experiment failed, invoking fixer..."
            ;;
        *)
            log "EVALUATE [iter $CURRENT_ITERATION]: Unexpected status '$AICHOR_STATUS', treating as failure"
            ;;
    esac

    # --- FIX (reached only when status is Failed or unexpected) ---
    if [[ "$AICHOR_STATUS" != "Succeeded" && "$AICHOR_STATUS" != "Cancelled" ]]; then
        log "FIX [iter $CURRENT_ITERATION]: Running experiment-fixer agent..."

        claude -p \
            --agent experiment-fixer \
            --model opus \
            --dangerously-skip-permissions \
            --allowedTools "Glob Grep Read Write Edit Bash Task" \
            --max-budget-usd "$BUDGET" \
            "Fix the failed experiment.

State file: $STATE_FILE
Current iteration: $CURRENT_ITERATION
Worktree: $WORKTREE_PATH

Read the state file to understand the plan, previous iterations, and the latest failure.
Read the analysis at the path in the latest iteration entry.
All file changes must be made inside the worktree at: $WORKTREE_PATH

After diagnosis, update the latest iteration in state.json with your verdict (fixed/unrecoverable/needs_human), fixer_summary, fixer_detail, and changes_made.

If verdict is unrecoverable or needs_human, also write a report to: $STATE_DIR/needs-human-report.md" > /dev/null 2>&1

        # Read the fixer verdict from state
        FIXER_VERDICT=$(get_iteration_field "$CURRENT_ITERATION" "fixer_verdict")
        FIXER_SUMMARY=$(get_iteration_field "$CURRENT_ITERATION" "fixer_summary")

        log "FIX [iter $CURRENT_ITERATION]: verdict=$FIXER_VERDICT. $FIXER_SUMMARY"

        # Send iteration notification with fixer result
        send_iteration_notifications "Fix: $FIXER_VERDICT" "detailed" || true

        case "$FIXER_VERDICT" in
            "fixed")
                # Continue to next iteration
                CURRENT_ITERATION=$((CURRENT_ITERATION + 1))
                RESUME_PHASE="launch"
                log "FIX [iter $((CURRENT_ITERATION - 1))]: Fix applied, advancing to iteration $CURRENT_ITERATION"
                ;;
            "unrecoverable")
                exit_loop "failed_unrecoverable" 1
                ;;
            "needs_human")
                exit_loop "needs_human" 1
                ;;
            *)
                log "FIX [iter $CURRENT_ITERATION]: WARNING: No valid verdict returned (got '$FIXER_VERDICT'), stopping for safety"
                exit_loop "needs_human" 1
                ;;
        esac
    fi
done
