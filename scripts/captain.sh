#!/usr/bin/env bash
set -euo pipefail

# Captain - Epic orchestrator for pi-swarm
# Parses epic issues, manages dependency waves, dispatches swarm/pr-swarm, monitors progress
#
# Usage: captain.sh [options] --epic <issue-number>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library
source "$SCRIPT_DIR/lib.sh"
STATE_DIR=".captain"
MODEL=""
EPIC_NUM=""
MAX_RETRIES=2
WAVE_TIMEOUT=60  # minutes per wave
DRY_RUN=false
RESUME=false
FORCE=false
JOBS=0

# Colors
COLOR_CAPTAIN='\033[1;35m'  # Bold magenta for captain
COLOR_INFO='\033[0;36m'
COLOR_SUCCESS='\033[0;32m'
COLOR_WARN='\033[0;33m'
COLOR_ERROR='\033[0;31m'
NC='\033[0m'

log() { echo -e "${COLOR_CAPTAIN}[Captain]${NC} $*"; }
info() { echo -e "${COLOR_INFO}[Captain]${NC} $*"; }
success() { echo -e "${COLOR_SUCCESS}[Captain]${NC} ✅ $*"; }
warn() { echo -e "${COLOR_WARN}[Captain]${NC} ⚠️  $*"; }
error() { echo -e "${COLOR_ERROR}[Captain]${NC} ❌ $*"; }

usage() {
    cat <<EOF
Usage: captain.sh [options] --epic <issue-number>

Orchestrates an epic by parsing sub-issues, managing dependencies,
and dispatching swarm/pr-swarm in waves.

Options:
  --epic <num>        Epic issue number (required)
  --model <name>      Model to use for pi agents
  --max-retries <n>   Max retries per failed task (default: 2)
  --wave-timeout <m>  Timeout per wave in minutes (default: 60)
  --resume            Resume from saved state
  --force             Force start even if another instance seems running
  --dry-run           Parse and plan only, don't execute
  -j, --jobs <n>      Max parallel jobs per wave (default: unlimited)
  -h, --help          Show this help

Example:
  captain.sh --epic 151
  captain.sh --epic 151 --model opus --max-retries 3
  captain.sh --epic 151 --resume
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --epic)
            EPIC_NUM="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --max-retries)
            validate_int "$2" "--max-retries" || exit 1
            MAX_RETRIES="$2"
            shift 2
            ;;
        --wave-timeout)
            validate_int "$2" "--wave-timeout" || exit 1
            WAVE_TIMEOUT="$2"
            shift 2
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -j|--jobs)
            validate_int "$2" "--jobs" || exit 1
            JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "$EPIC_NUM" ]]; then
    error "Epic issue number is required"
    usage
fi

# Check dependencies
require_deps gh jq pi git || exit 1

# Initialize state directory
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/epic-$EPIC_NUM.json"
PLAN_FILE="$STATE_DIR/epic-$EPIC_NUM-plan.json"
LOG_FILE="$STATE_DIR/epic-$EPIC_NUM.log"

# Acquire lock (prevent duplicate runs)
if ! acquire_lock "epic-$EPIC_NUM" "$STATE_DIR" "$FORCE"; then
    error "Could not acquire lock. Use --force to override."
    exit 1
fi

# Release lock on exit
trap 'release_lock "epic-$EPIC_NUM" "$STATE_DIR"' EXIT

# Start heartbeat for liveness detection
start_heartbeat "$STATE_FILE" 30

# Setup signal handlers for graceful shutdown
setup_signal_handlers

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [[ -z "$REPO" ]]; then
    error "Not in a GitHub repository or gh not authenticated"
    exit 1
fi

log "═══════════════════════════════════════════════════════════"
log "🎖️  Captain starting for Epic #$EPIC_NUM"
log "📦 Repository: $REPO"
log "═══════════════════════════════════════════════════════════"
echo ""

# Fetch epic issue
fetch_epic() {
    log "Fetching epic issue #$EPIC_NUM..."
    gh issue view "$EPIC_NUM" --json title,body,state > "$STATE_DIR/epic-$EPIC_NUM-raw.json"
    
    local title state
    title=$(jq -r '.title' "$STATE_DIR/epic-$EPIC_NUM-raw.json")
    state=$(jq -r '.state' "$STATE_DIR/epic-$EPIC_NUM-raw.json")
    
    info "Title: $title"
    info "State: $state"
    echo ""
}

# Use pi agent to parse epic and create execution plan
parse_epic_with_pi() {
    log "Analyzing epic with pi agent..."
    
    local epic_body
    epic_body=$(jq -r '.body' "$STATE_DIR/epic-$EPIC_NUM-raw.json")
    
    local prompt="You are the Captain - an orchestrator for parallel task execution.

Analyze this GitHub Epic issue and create an execution plan in JSON format.

# Epic Content:
$epic_body

# Your Task:
1. Extract all sub-issue numbers (e.g., #145, #146, etc.)
2. Identify dependencies between issues (look for → arrows, 'depends on', 'after', 'requires')
3. Group issues into parallel-safe 'waves' - issues in the same wave can run simultaneously
4. Issues with no dependencies go in wave 1
5. Issues depending on wave N issues go in wave N+1

# Output Format (JSON only, no markdown):
{
  \"epic_number\": $EPIC_NUM,
  \"total_issues\": <count>,
  \"waves\": [
    {
      \"wave\": 1,
      \"issues\": [145, 148, 149],
      \"description\": \"Independent issues - can run in parallel\"
    },
    {
      \"wave\": 2, 
      \"issues\": [146, 147],
      \"depends_on_wave\": 1,
      \"description\": \"Depends on wave 1 completion\"
    }
  ],
  \"issue_details\": {
    \"145\": {\"title\": \"...\", \"depends_on\": []},
    \"146\": {\"title\": \"...\", \"depends_on\": [145]}
  },
  \"success_criteria\": [\"criterion 1\", \"criterion 2\"],
  \"estimated_time\": \"3-4 days\"
}

Output ONLY valid JSON, no explanation."

    local pi_cmd="pi -p"
    [[ -n "$MODEL" ]] && pi_cmd="pi --model $MODEL -p"
    
    # Run pi and capture output
    local pi_output
    if pi_output=$($pi_cmd "$prompt" 2>&1); then
        # Extract JSON from output (pi might include other text)
        echo "$pi_output" | grep -E '^\{' | head -1 > "$PLAN_FILE" || true
        
        # Validate JSON
        if jq empty "$PLAN_FILE" 2>/dev/null; then
            success "Execution plan created"
            return 0
        else
            # Try to extract JSON block
            echo "$pi_output" | sed -n '/^{/,/^}/p' > "$PLAN_FILE"
            if jq empty "$PLAN_FILE" 2>/dev/null; then
                success "Execution plan created"
                return 0
            fi
        fi
    fi
    
    error "Failed to parse epic. Pi output:"
    echo "$pi_output"
    return 1
}

# Display execution plan
show_plan() {
    log "Execution Plan:"
    echo ""
    
    local total_issues waves
    total_issues=$(jq -r '.total_issues' "$PLAN_FILE")
    waves=$(jq -r '.waves | length' "$PLAN_FILE")
    
    info "Total issues: $total_issues"
    info "Waves: $waves"
    echo ""
    
    jq -r '.waves[] | "  Wave \(.wave): Issues \(.issues | map("#\(.)") | join(", "))\n    └─ \(.description)"' "$PLAN_FILE"
    echo ""
    
    local est_time
    est_time=$(jq -r '.estimated_time // "unknown"' "$PLAN_FILE")
    info "Estimated time: $est_time"
    echo ""
}

# Initialize or load state
init_state() {
    if [[ "$RESUME" == true ]] && [[ -f "$STATE_FILE" ]]; then
        log "Resuming from saved state..."
        return 0
    fi
    
    # Initialize fresh state
    jq -n --argjson epic "$EPIC_NUM" '{
        epic: $epic,
        status: "initialized",
        current_wave: 0,
        completed_waves: [],
        issue_status: {},
        pr_status: {},
        retries: {},
        errors: [],
        started_at: now | todate,
        updated_at: now | todate
    }' > "$STATE_FILE"
}

# Update state
update_state() {
    local key="$1"
    local value="$2"
    
    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# Get issue status from state
get_issue_status() {
    local issue="$1"
    jq -r --arg issue "$issue" '.issue_status[$issue] // "pending"' "$STATE_FILE"
}

# Set issue status
set_issue_status() {
    local issue="$1"
    local status="$2"
    
    local tmp
    tmp=$(mktemp)
    jq --arg issue "$issue" --arg status "$status" \
        '.issue_status[$issue] = $status | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# Get retry count
get_retry_count() {
    local issue="$1"
    jq -r --arg issue "$issue" '.retries[$issue] // 0' "$STATE_FILE"
}

# Increment retry count
inc_retry_count() {
    local issue="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg issue "$issue" \
        '.retries[$issue] = ((.retries[$issue] // 0) + 1) | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# Execute a wave of issues using swarm.sh
execute_wave() {
    local wave_num="$1"
    
    log "═══════════════════════════════════════"
    log "🌊 Executing Wave $wave_num"
    log "═══════════════════════════════════════"
    
    # Get issues for this wave
    local issues
    issues=$(jq -r --argjson wave "$wave_num" '.waves[] | select(.wave == $wave) | .issues[]' "$PLAN_FILE")
    
    if [[ -z "$issues" ]]; then
        warn "No issues in wave $wave_num"
        return 0
    fi
    
    # Filter to pending/failed issues only
    local issues_to_run=()
    for issue in $issues; do
        local status
        status=$(get_issue_status "$issue")
        local retries
        retries=$(get_retry_count "$issue")
        
        if [[ "$status" == "completed" ]]; then
            info "Issue #$issue already completed, skipping"
        elif [[ "$status" == "failed" ]] && [[ "$retries" -ge "$MAX_RETRIES" ]]; then
            warn "Issue #$issue failed $retries times, max retries reached"
        else
            issues_to_run+=("$issue")
            set_issue_status "$issue" "in_progress"
        fi
    done
    
    if [[ ${#issues_to_run[@]} -eq 0 ]]; then
        info "All issues in wave $wave_num handled"
        return 0
    fi
    
    info "Running issues: ${issues_to_run[*]}"
    echo ""
    
    # Build swarm command
    local swarm_cmd="$SCRIPT_DIR/swarm.sh"
    [[ -n "$MODEL" ]] && swarm_cmd+=" --model $MODEL"
    [[ "$WAVE_TIMEOUT" -gt 0 ]] && swarm_cmd+=" --timeout $WAVE_TIMEOUT"
    [[ "$JOBS" -gt 0 ]] && swarm_cmd+=" --jobs $JOBS"
    swarm_cmd+=" ${issues_to_run[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would execute: $swarm_cmd"
        return 0
    fi
    
    # Execute swarm
    log "Executing: $swarm_cmd"
    echo ""
    
    if $swarm_cmd 2>&1 | tee -a "$LOG_FILE"; then
        # Check which issues succeeded by looking for PR files
        for issue in "${issues_to_run[@]}"; do
            if [[ -f ".worktrees/issue-$issue.pr" ]]; then
                set_issue_status "$issue" "completed"
                success "Issue #$issue completed with PR"
            else
                # Check log for errors
                local issue_log=".worktrees/issue-$issue.log"
                if [[ -f "$issue_log" ]]; then
                    local log_content
                    log_content=$(cat "$issue_log")
                    local error_type
                    error_type=$(detect_error_type "$log_content")
                    
                    if is_fatal_error "$error_type"; then
                        error "Issue #$issue hit fatal error: $(error_type_name $error_type)"
                        set_issue_status "$issue" "fatal"
                        record_error "$STATE_FILE" "$issue" "$error_type" "Fatal error detected"
                        # Don't retry fatal errors
                    elif grep -q "❌" "$issue_log" 2>/dev/null; then
                        set_issue_status "$issue" "failed"
                        inc_retry_count "$issue"
                        warn "Issue #$issue failed ($(error_type_name $error_type))"
                    else
                        # Assume success if no explicit failure
                        set_issue_status "$issue" "completed"
                        success "Issue #$issue completed"
                    fi
                else
                    set_issue_status "$issue" "failed"
                    inc_retry_count "$issue"
                    warn "Issue #$issue failed (no log)"
                fi
            fi
        done
    else
        warn "Swarm command returned non-zero exit code"
        # Mark all as needing review
        for issue in "${issues_to_run[@]}"; do
            if [[ -f ".worktrees/issue-$issue.pr" ]]; then
                set_issue_status "$issue" "completed"
            else
                set_issue_status "$issue" "failed"
                inc_retry_count "$issue"
            fi
        done
    fi
    
    echo ""
}

# Review PRs created in a wave using pr-swarm.sh
review_wave_prs() {
    local wave_num="$1"
    
    log "🔍 Reviewing PRs from Wave $wave_num"
    
    # Get issues from this wave that completed
    local issues
    issues=$(jq -r --argjson wave "$wave_num" '.waves[] | select(.wave == $wave) | .issues[]' "$PLAN_FILE")
    
    local prs_to_review=()
    for issue in $issues; do
        local pr_file=".worktrees/issue-$issue.pr"
        if [[ -f "$pr_file" ]]; then
            local pr_url
            pr_url=$(cat "$pr_file")
            # Extract PR number from URL
            local pr_num
            pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
            if [[ -n "$pr_num" ]]; then
                prs_to_review+=("$pr_num")
            fi
        fi
    done
    
    if [[ ${#prs_to_review[@]} -eq 0 ]]; then
        info "No PRs to review for wave $wave_num"
        return 0
    fi
    
    info "PRs to review: ${prs_to_review[*]}"
    
    # Build pr-swarm command
    local pr_swarm_cmd="$SCRIPT_DIR/pr-swarm.sh"
    [[ -n "$MODEL" ]] && pr_swarm_cmd+=" --model $MODEL"
    [[ "$JOBS" -gt 0 ]] && pr_swarm_cmd+=" --jobs $JOBS"
    pr_swarm_cmd+=" ${prs_to_review[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would execute: $pr_swarm_cmd"
        return 0
    fi
    
    log "Executing: $pr_swarm_cmd"
    $pr_swarm_cmd 2>&1 | tee -a "$LOG_FILE"
    echo ""
}

# Check if wave is complete
is_wave_complete() {
    local wave_num="$1"
    
    local issues
    issues=$(jq -r --argjson wave "$wave_num" '.waves[] | select(.wave == $wave) | .issues[]' "$PLAN_FILE")
    
    for issue in $issues; do
        local status
        status=$(get_issue_status "$issue")
        # Completed or fatal (can't retry) count as "done"
        if [[ "$status" != "completed" ]] && [[ "$status" != "fatal" ]]; then
            local retries
            retries=$(get_retry_count "$issue")
            if [[ "$retries" -lt "$MAX_RETRIES" ]]; then
                return 1  # Not complete, can still retry
            fi
        fi
    done
    
    return 0
}

# Final validation using pi agent
final_validation() {
    log "═══════════════════════════════════════"
    log "🎯 Final Validation"
    log "═══════════════════════════════════════"
    
    # Gather all completed issues and PRs
    local completed_issues
    completed_issues=$(jq -r '.issue_status | to_entries | map(select(.value == "completed")) | map(.key) | join(", ")' "$STATE_FILE")
    
    local failed_issues
    failed_issues=$(jq -r '.issue_status | to_entries | map(select(.value == "failed")) | map(.key) | join(", ")' "$STATE_FILE")
    
    local success_criteria
    success_criteria=$(jq -r '.success_criteria | join("\n- ")' "$PLAN_FILE" 2>/dev/null || echo "No criteria specified")
    
    local epic_body
    epic_body=$(jq -r '.body' "$STATE_DIR/epic-$EPIC_NUM-raw.json")
    
    local prompt="You are the Captain performing final validation of Epic #$EPIC_NUM.

# Epic:
$epic_body

# Execution Results:
- Completed issues: $completed_issues
- Failed issues: $failed_issues

# Success Criteria:
- $success_criteria

# Your Task:
1. Evaluate if the epic's goals have been met based on completed issues
2. Identify any gaps or missing work
3. Provide a final status recommendation

Output a brief summary (2-3 paragraphs) with:
- Overall status: SUCCESS / PARTIAL / FAILED
- What was accomplished
- Any remaining work needed
- Recommendation for next steps"

    local pi_cmd="pi -p"
    [[ -n "$MODEL" ]] && pi_cmd="pi --model $MODEL -p"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would run validation with pi agent"
        return 0
    fi
    
    log "Running validation..."
    echo ""
    $pi_cmd "$prompt" 2>&1 | tee -a "$LOG_FILE"
    echo ""
}

# Post summary to epic issue
post_summary() {
    log "📝 Posting summary to Epic #$EPIC_NUM..."
    
    local completed failed fatal
    completed=$(jq -r '.issue_status | to_entries | map(select(.value == "completed")) | length' "$STATE_FILE")
    failed=$(jq -r '.issue_status | to_entries | map(select(.value == "failed")) | length' "$STATE_FILE")
    fatal=$(jq -r '.issue_status | to_entries | map(select(.value == "fatal")) | length' "$STATE_FILE")
    local total=$((completed + failed + fatal))
    
    local pr_links=""
    for pr_file in .worktrees/issue-*.pr; do
        if [[ -f "$pr_file" ]]; then
            local issue_num
            issue_num=$(basename "$pr_file" | sed 's/issue-//' | sed 's/.pr//')
            local pr_url
            pr_url=$(cat "$pr_file")
            pr_links+="- Issue #$issue_num: $pr_url\n"
        fi
    done
    
    local error_section=""
    if [[ "$fatal" -gt 0 ]]; then
        local errors
        errors=$(jq -r '.errors | map("- \(.task): \(.type) - \(.message)") | join("\n")' "$STATE_FILE")
        error_section="### ⚠️ Fatal Errors
$errors
"
    fi
    
    local summary="## 🎖️ Captain's Report

**Epic Execution Summary**

- ✅ Completed: $completed/$total issues
- ❌ Failed: $failed issues
- 🚫 Fatal: $fatal issues

### Created PRs:
$pr_links
$error_section
---
*Automated by Pi Captain*"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would post comment to issue #$EPIC_NUM"
        echo "$summary"
        return 0
    fi
    
    gh issue comment "$EPIC_NUM" --body "$summary" || warn "Failed to post summary"
}

# Main execution flow
main() {
    fetch_epic
    
    if [[ "$RESUME" == true ]] && [[ -f "$PLAN_FILE" ]]; then
        log "Using existing execution plan"
    else
        parse_epic_with_pi || exit 1
    fi
    
    # Validate plan structure before proceeding
    if ! validate_plan "$PLAN_FILE" "waves"; then
        error "Invalid execution plan. Please check the plan file or re-generate."
        exit 1
    fi
    
    show_plan
    init_state
    
    if [[ "$DRY_RUN" == true ]]; then
        log "🔍 DRY RUN complete. No changes made."
        exit 0
    fi
    
    # Execute waves
    local total_waves
    total_waves=$(jq -r '.waves | length' "$PLAN_FILE")
    
    for ((wave=1; wave<=total_waves; wave++)); do
        # Check for shutdown request
        if is_shutdown_requested; then
            warn "Shutdown requested. Saving state and exiting..."
            update_state "status" '"interrupted"'
            exit 0
        fi
        
        update_state "current_wave" "$wave"
        
        # Check for fatal errors from previous waves
        local fatal_count
        fatal_count=$(jq -r '[.issue_status | to_entries[] | select(.value == "fatal")] | length' "$STATE_FILE")
        if [[ "$fatal_count" -gt 0 ]]; then
            error "Fatal errors detected. Cannot continue."
            error "Please check: quota, billing, or API key issues."
            update_state "status" '"fatal_error"'
            exit 1
        fi
        
        # Execute wave (with retries)
        local attempt=0
        while ! is_wave_complete "$wave" && [[ $attempt -lt $MAX_RETRIES ]]; do
            execute_wave "$wave"
            attempt=$((attempt + 1))
            
            if ! is_wave_complete "$wave"; then
                # Check if all failures are fatal
                local wave_issues
                wave_issues=$(jq -r --argjson w "$wave" '.waves[] | select(.wave == $w) | .issues[]' "$PLAN_FILE")
                local all_fatal=true
                for issue in $wave_issues; do
                    local status
                    status=$(get_issue_status "$issue")
                    if [[ "$status" != "fatal" ]] && [[ "$status" != "completed" ]]; then
                        all_fatal=false
                        break
                    fi
                done
                
                if [[ "$all_fatal" == true ]]; then
                    error "All remaining issues have fatal errors. Stopping."
                    update_state "status" '"fatal_error"'
                    exit 1
                fi
                
                # Calculate backoff delay
                local delay
                delay=$(calculate_backoff $attempt)
                warn "Wave $wave incomplete after attempt $attempt. Retrying in ${delay}s..."
                sleep "$delay"
            fi
        done
        
        # Review PRs from this wave
        review_wave_prs "$wave"
        
        # Mark wave as complete
        local completed_waves
        completed_waves=$(jq -r '.completed_waves' "$STATE_FILE")
        completed_waves=$(echo "$completed_waves" | jq ". + [$wave]")
        update_state "completed_waves" "$completed_waves"
        
        success "Wave $wave complete"
        echo ""
    done
    
    # Final validation
    final_validation
    
    # Post summary
    post_summary
    
    update_state "status" '"completed"'
    
    log "═══════════════════════════════════════"
    success "Epic #$EPIC_NUM orchestration complete!"
    log "═══════════════════════════════════════"
    echo ""
    log "State: $STATE_FILE"
    log "Logs: $LOG_FILE"
}

main "$@"
