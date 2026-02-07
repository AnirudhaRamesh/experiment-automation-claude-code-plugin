#!/usr/bin/env bash
set -euo pipefail

# AIChor Experiment Monitor
# Polls for experiment completion, downloads logs, and triggers analysis.
#
# Usage:
#   ./monitor-experiment.sh                  # auto-detect latest experiment
#   ./monitor-experiment.sh <experiment-id>  # monitor a specific experiment
#   ./monitor-experiment.sh --worktree PATH <experiment-id>  # use worktree for git lookups

REPO_ROOT="$(git rev-parse --show-toplevel)"
ANALYSIS_DIR="$REPO_ROOT/.claude/analysis"
LOG_DIR="$REPO_ROOT/.claude/logs"
WORKTREE_PATH=""

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

AUTHOR=$(read_config "author_name" "$(git config user.name)")

# --- Parse flags ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree)
            WORKTREE_PATH="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARG="$1"
            shift
            ;;
    esac
done

# Use worktree for git operations if provided, otherwise use repo root
GIT_DIR="${WORKTREE_PATH:-$REPO_ROOT}"

mkdir -p "$LOG_DIR" "$ANALYSIS_DIR"

# --- Find experiment ---

find_experiment() {
    if [[ -n "${POSITIONAL_ARG:-}" ]]; then
        echo "$POSITIONAL_ARG"
        return
    fi

    echo ">> Finding latest experiment by $AUTHOR..." >&2

    # Get latest EXP: commit messages by this author
    local commit_msg
    commit_msg=$(cd "$GIT_DIR" && git log --author="$AUTHOR" --grep="^EXP:" --format="%s" -1)
    if [[ -z "$commit_msg" ]]; then
        echo "ERROR: No EXP: commits found by $AUTHOR" >&2
        exit 1
    fi

    # Extract first line of commit message for matching
    local first_line
    first_line=$(echo "$commit_msg" | head -1)
    echo ">> Latest commit: $first_line" >&2

    # Get recent experiments from aichor and match
    local experiments
    experiments=$(aichor get experiments --page-size 20 --output json 2>/dev/null)

    local experiment_id
    experiment_id=$(echo "$experiments" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target = '''$first_line'''
for exp in data:
    msg_first_line = exp['commitMessage'].split('\n')[0]
    if msg_first_line == target:
        print(exp['experimentId'])
        sys.exit(0)
print('')
")

    if [[ -z "$experiment_id" ]]; then
        return 1
    fi

    echo "$experiment_id"
}

# Retry finding the experiment (AIChor may not have picked it up yet)
MAX_FIND_RETRIES=10
FIND_RETRY_INTERVAL=30
for i in $(seq 1 $MAX_FIND_RETRIES); do
    EXPERIMENT_ID=$(find_experiment) && break
    echo ">> Experiment not found on AIChor yet, retrying in ${FIND_RETRY_INTERVAL}s ($i/$MAX_FIND_RETRIES)..." >&2
    sleep "$FIND_RETRY_INTERVAL"
done

if [[ -z "${EXPERIMENT_ID:-}" ]]; then
    echo "ERROR: Could not find experiment after $MAX_FIND_RETRIES retries" >&2
    exit 1
fi

echo ">> Monitoring experiment: $EXPERIMENT_ID" >&2

# --- Get experiment metadata ---

get_experiment_status() {
    local json
    json=$(aichor get experiment --experiment-id "$EXPERIMENT_ID" --output json 2>/dev/null)
    echo "$json"
}

EXP_JSON=$(get_experiment_status)
COMMIT_MSG=$(echo "$EXP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['commitMessage'].split('\n')[0])")
echo ">> Commit: $COMMIT_MSG" >&2

# --- Generate analysis filename ---

generate_filename() {
    local msg="$1"
    local exp_id="$2"
    # Strip "EXP: " prefix, lowercase, replace spaces/special chars with hyphens, truncate
    local short
    short=$(echo "$msg" | sed 's/^EXP: //i' | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-50)
    local id_prefix="${exp_id:0:7}"
    echo "${short}-${id_prefix}.md"
}

ANALYSIS_FILENAME=$(generate_filename "$COMMIT_MSG" "$EXPERIMENT_ID")
ANALYSIS_PATH="$ANALYSIS_DIR/$ANALYSIS_FILENAME"
LOG_PATH="$LOG_DIR/${EXPERIMENT_ID}.log"

echo ">> Analysis will be saved to: $ANALYSIS_PATH" >&2
echo ">> Logs will be saved to: $LOG_PATH" >&2

# --- Poll loop ---

poll_experiment() {
    local elapsed=0
    local interval=30
    local fast_phase=300  # 5 minutes in seconds

    while true; do
        local json
        json=$(get_experiment_status)
        local status
        status=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['experimentStatus'])")
        local step
        step=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['step'])")

        echo ">> [$(date '+%H:%M:%S')] Status: $status | Step: $step | Elapsed: ${elapsed}s" >&2

        case "$status" in
            "Succeeded"|"Failed"|"Cancelled")
                echo "$status"
                return
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))

        # Switch to slow polling after 5 minutes
        if [[ $elapsed -ge $fast_phase && $interval -eq 30 ]]; then
            interval=300
            echo ">> Switching to 5-minute polling interval" >&2
        fi
    done
}

# Check if already terminal
INITIAL_STATUS=$(echo "$EXP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['experimentStatus'])")
case "$INITIAL_STATUS" in
    "Succeeded"|"Failed"|"Cancelled")
        FINAL_STATUS="$INITIAL_STATUS"
        echo ">> Experiment already in terminal state: $FINAL_STATUS" >&2
        ;;
    *)
        FINAL_STATUS=$(poll_experiment)
        ;;
esac

echo ">> Final status: $FINAL_STATUS" >&2

# --- Download logs ---

echo ">> Downloading logs..." >&2
aichor logs --experiment-id "$EXPERIMENT_ID" --step run > "$LOG_PATH" 2>&1
echo ">> Logs saved to: $LOG_PATH ($(wc -l < "$LOG_PATH") lines)" >&2

# --- Trigger analysis ---

echo ">> Launching experiment-log-analyzer..." >&2

claude -p \
    --agent experiment-log-analyzer \
    --model sonnet \
    --dangerously-skip-permissions \
    --allowedTools "Glob Grep Read Write Edit Bash" \
    --max-budget-usd 10.00 \
    "Analyze the following AIChor experiment logs.

Experiment ID: $EXPERIMENT_ID
Commit: $COMMIT_MSG
Status: $FINAL_STATUS

Write your analysis to .claude/analysis/$ANALYSIS_FILENAME

Here are the logs:
$(cat "$LOG_PATH")" > /dev/null 2>&1

echo ">> Analysis complete: $ANALYSIS_PATH" >&2

# --- Summary ---

echo ""
echo "========================================="
echo " AIChor Experiment Monitor - Complete"
echo "========================================="
echo " Experiment: $EXPERIMENT_ID"
echo " Commit:     $COMMIT_MSG"
echo " Status:     $FINAL_STATUS"
echo " Logs:       $LOG_PATH"
echo " Analysis:   $ANALYSIS_PATH"
echo "========================================="

# --- Machine-readable output for experiment loop ---

echo ""
echo "===LOOP_DATA==="
echo "{\"experiment_id\":\"$EXPERIMENT_ID\",\"status\":\"$FINAL_STATUS\",\"analysis_path\":\"$ANALYSIS_PATH\",\"log_path\":\"$LOG_PATH\",\"commit_message\":\"$COMMIT_MSG\"}"
echo "===END_LOOP_DATA==="
