#!/usr/bin/env bash
set -euo pipefail

# Commander - Multi-epic orchestrator for pi-swarm
# Orchestrates multiple captains (epics) with cross-epic dependency management
#
# Usage: commander.sh [options] --milestone <issue-number>
#        commander.sh [options] --epics <epic1> <epic2> ...
#        commander.sh [options] --project <project-spec>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library
source "$SCRIPT_DIR/lib.sh"

STATE_DIR=".commander"
MODEL=""
MILESTONE_NUM=""
PROJECT_SPEC=""
EPICS=()
MAX_PARALLEL_EPICS=2  # How many captains can run simultaneously
MAX_RETRIES=1         # Retries per epic
EPIC_TIMEOUT=120      # Minutes per epic
DRY_RUN=false
RESUME=false
FORCE=false
JOBS=0                # Jobs per captain (0 = unlimited)

# Colors
COLOR_COMMANDER='\033[1;33m'  # Bold yellow for commander
COLOR_CAPTAIN='\033[1;35m'
COLOR_INFO='\033[0;36m'
COLOR_SUCCESS='\033[0;32m'
COLOR_WARN='\033[0;33m'
COLOR_ERROR='\033[0;31m'
NC='\033[0m'

log() { echo -e "${COLOR_COMMANDER}[Commander]${NC} $*"; }
info() { echo -e "${COLOR_INFO}[Commander]${NC} $*"; }
success() { echo -e "${COLOR_SUCCESS}[Commander]${NC} ✅ $*"; }
warn() { echo -e "${COLOR_WARN}[Commander]${NC} ⚠️  $*"; }
error() { echo -e "${COLOR_ERROR}[Commander]${NC} ❌ $*"; }

usage() {
    cat <<EOF
Usage: commander.sh [options] <source>

Sources (pick one):
  --milestone <num>       Parse milestone/roadmap issue for epics
  --epics <n1> <n2> ...   Directly specify epic issue numbers
  --project <spec>        Project description (pi generates epics)

Options:
  --model <name>          Model to use for pi agents
  --max-parallel <n>      Max parallel captains (default: 2)
  --max-retries <n>       Max retries per epic (default: 1)
  --epic-timeout <min>    Timeout per epic in minutes (default: 120)
  --resume                Resume from saved state
  --force                 Force start even if another instance seems running
  --dry-run               Parse and plan only, don't execute
  -j, --jobs <n>          Max parallel jobs per captain wave
  -h, --help              Show this help

Examples:
  commander.sh --milestone 200
  commander.sh --epics 151 160 175
  commander.sh --project "Build a CLI todo app with SQLite backend"
  commander.sh --milestone 200 --max-parallel 3 --resume
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --milestone)
            MILESTONE_NUM="$2"
            shift 2
            ;;
        --project)
            PROJECT_SPEC="$2"
            shift 2
            ;;
        --epics)
            shift
            while [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; do
                EPICS+=("$1")
                shift
            done
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --max-parallel)
            validate_int "$2" "--max-parallel" || exit 1
            MAX_PARALLEL_EPICS="$2"
            shift 2
            ;;
        --max-retries)
            validate_int "$2" "--max-retries" || exit 1
            MAX_RETRIES="$2"
            shift 2
            ;;
        --epic-timeout)
            validate_int "$2" "--epic-timeout" || exit 1
            EPIC_TIMEOUT="$2"
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

# Validate input
if [[ -z "$MILESTONE_NUM" ]] && [[ ${#EPICS[@]} -eq 0 ]] && [[ -z "$PROJECT_SPEC" ]]; then
    error "Must specify --milestone, --epics, or --project"
    usage
fi

# Check dependencies
require_deps gh jq pi git || exit 1

# Initialize state directory
mkdir -p "$STATE_DIR"

# Determine state file name based on input
if [[ -n "$MILESTONE_NUM" ]]; then
    STATE_ID="milestone-$MILESTONE_NUM"
elif [[ -n "$PROJECT_SPEC" ]]; then
    # Hash the project spec for a stable ID
    STATE_ID="project-$(echo "$PROJECT_SPEC" | md5sum | cut -c1-8)"
else
    STATE_ID="epics-$(echo "${EPICS[*]}" | tr ' ' '-')"
fi

STATE_FILE="$STATE_DIR/$STATE_ID.json"
PLAN_FILE="$STATE_DIR/$STATE_ID-plan.json"
LOG_FILE="$STATE_DIR/$STATE_ID.log"

# Acquire lock (prevent duplicate runs)
if ! acquire_lock "$STATE_ID" "$STATE_DIR" "$FORCE"; then
    error "Could not acquire lock. Use --force to override."
    exit 1
fi

# Release lock on exit
trap 'release_lock "$STATE_ID" "$STATE_DIR"' EXIT

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

log "═══════════════════════════════════════════════════════════════"
log "⭐ Commander starting"
log "📦 Repository: $REPO"
if [[ -n "$MILESTONE_NUM" ]]; then
    log "🎯 Milestone: #$MILESTONE_NUM"
elif [[ -n "$PROJECT_SPEC" ]]; then
    log "🚀 Project: $PROJECT_SPEC"
else
    log "📋 Epics: ${EPICS[*]}"
fi
log "═══════════════════════════════════════════════════════════════"
echo ""

# Generate project plan using pi (for --project mode)
generate_project_plan() {
    log "🧠 Generating project plan with pi agent..."
    
    local prompt="You are the Commander - a strategic planner for software projects.

# Project Request:
$PROJECT_SPEC

# Repository: $REPO

# Your Task:
Break this project down into GitHub Epics and Issues that can be executed by autonomous agents.

Think about:
1. What are the major components/features? (These become Epics)
2. What are the atomic tasks within each? (These become Issues under each Epic)
3. What are the dependencies between epics?
4. What can be parallelized?

# Output Format (JSON only):
{
  \"project_name\": \"Short project name\",
  \"description\": \"One-line description\",
  \"epics\": [
    {
      \"id\": 1,
      \"title\": \"Epic: Feature Name\",
      \"description\": \"What this epic accomplishes\",
      \"depends_on\": [],
      \"issues\": [
        {
          \"title\": \"Issue title\",
          \"description\": \"Detailed description of what to implement\",
          \"depends_on\": [],
          \"estimate\": \"0.5 days\"
        }
      ]
    }
  ],
  \"epic_waves\": [
    {
      \"wave\": 1,
      \"epic_ids\": [1, 2],
      \"description\": \"Foundation - can run in parallel\"
    }
  ],
  \"success_criteria\": [\"criterion 1\", \"criterion 2\"],
  \"estimated_total_time\": \"X days\"
}

Output ONLY valid JSON."

    local pi_cmd="pi -p"
    [[ -n "$MODEL" ]] && pi_cmd="pi --model $MODEL -p"
    
    local pi_output
    if pi_output=$($pi_cmd "$prompt" 2>&1); then
        # Extract JSON
        echo "$pi_output" | sed -n '/^{/,/^}/p' > "$PLAN_FILE"
        if jq empty "$PLAN_FILE" 2>/dev/null; then
            success "Project plan generated"
            return 0
        fi
    fi
    
    error "Failed to generate project plan"
    echo "$pi_output"
    return 1
}

# Create GitHub issues from project plan
create_github_issues() {
    log "📝 Creating GitHub issues from plan..."
    
    local created_epics=()
    local epic_count
    epic_count=$(jq '.epics | length' "$PLAN_FILE")
    
    for ((i=0; i<epic_count; i++)); do
        local epic_title epic_desc issues_md
        epic_title=$(jq -r ".epics[$i].title" "$PLAN_FILE")
        epic_desc=$(jq -r ".epics[$i].description" "$PLAN_FILE")
        
        # Build issue list for epic body
        issues_md=$(jq -r ".epics[$i].issues | to_entries | map(\"- [ ] \" + .value.title + \" (\" + .value.estimate + \")\") | join(\"\n\")" "$PLAN_FILE")
        
        # Build dependencies text
        local deps_text=""
        local deps
        deps=$(jq -r ".epics[$i].depends_on | map(\"Epic \" + tostring) | join(\", \")" "$PLAN_FILE")
        [[ -n "$deps" && "$deps" != "" ]] && deps_text="**Depends on:** $deps"
        
        local epic_body="## Overview
$epic_desc

$deps_text

## Sub-Issues
$issues_md

## Success Criteria
- All sub-issues completed
- Tests passing
- Code reviewed

---
*Generated by Commander*"

        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would create epic: $epic_title"
            info "  Issues: $(jq -r ".epics[$i].issues | length" "$PLAN_FILE")"
        else
            info "Creating epic: $epic_title"
            local epic_url
            epic_url=$(gh issue create --title "$epic_title" --body "$epic_body" --label "epic" 2>&1) || true
            
            if [[ "$epic_url" =~ /issues/([0-9]+) ]]; then
                local epic_num="${BASH_REMATCH[1]}"
                created_epics+=("$epic_num")
                success "Created epic #$epic_num: $epic_title"
                
                # Create sub-issues
                local issue_count
                issue_count=$(jq ".epics[$i].issues | length" "$PLAN_FILE")
                
                for ((j=0; j<issue_count; j++)); do
                    local issue_title issue_desc
                    issue_title=$(jq -r ".epics[$i].issues[$j].title" "$PLAN_FILE")
                    issue_desc=$(jq -r ".epics[$i].issues[$j].description" "$PLAN_FILE")
                    
                    local issue_body="$issue_desc

---
Part of Epic #$epic_num

*Generated by Commander*"
                    
                    if gh issue create --title "$issue_title" --body "$issue_body" >/dev/null 2>&1; then
                        info "  Created: $issue_title"
                    else
                        warn "  Failed to create: $issue_title"
                    fi
                    
                    sleep 1  # Rate limiting
                done
            else
                warn "Failed to create epic: $epic_title"
            fi
            
            sleep 2  # Rate limiting between epics
        fi
    done
    
    # Update EPICS array with created epic numbers
    EPICS=("${created_epics[@]}")
    
    # Save to plan
    local tmp
    tmp=$(mktemp)
    jq --argjson epics "$(printf '%s\n' "${created_epics[@]}" | jq -R . | jq -s .)" \
        '.created_epic_numbers = $epics' "$PLAN_FILE" > "$tmp"
    mv "$tmp" "$PLAN_FILE"
}

# Fetch milestone and parse epics
fetch_milestone() {
    log "Fetching milestone issue #$MILESTONE_NUM..."
    
    gh issue view "$MILESTONE_NUM" --json title,body,state > "$STATE_DIR/$STATE_ID-raw.json"
    
    local title
    title=$(jq -r '.title' "$STATE_DIR/$STATE_ID-raw.json")
    info "Title: $title"
    echo ""
}

# Parse milestone to extract epics and dependencies
parse_milestone_with_pi() {
    log "Analyzing milestone with pi agent..."
    
    local milestone_body
    milestone_body=$(jq -r '.body' "$STATE_DIR/$STATE_ID-raw.json")
    
    local prompt="You are the Commander - analyzing a milestone/roadmap issue.

# Milestone Content:
$milestone_body

# Your Task:
1. Extract all Epic issue numbers referenced (e.g., #151, #160)
2. Identify dependencies between epics (look for → arrows, 'after', 'depends on', 'requires')
3. Group epics into parallel-safe 'waves'

# Output Format (JSON only):
{
  \"milestone_number\": $MILESTONE_NUM,
  \"total_epics\": <count>,
  \"epic_waves\": [
    {
      \"wave\": 1,
      \"epics\": [151, 160],
      \"description\": \"Foundation epics - can run in parallel\"
    },
    {
      \"wave\": 2,
      \"epics\": [175],
      \"depends_on_wave\": 1,
      \"description\": \"Depends on foundation\"
    }
  ],
  \"epic_details\": {
    \"151\": {\"title\": \"...\", \"depends_on\": []},
    \"160\": {\"title\": \"...\", \"depends_on\": [151]}
  },
  \"success_criteria\": [\"milestone criterion 1\"],
  \"estimated_time\": \"X weeks\"
}

Output ONLY valid JSON."

    local pi_cmd="pi -p"
    [[ -n "$MODEL" ]] && pi_cmd="pi --model $MODEL -p"
    
    local pi_output
    if pi_output=$($pi_cmd "$prompt" 2>&1); then
        echo "$pi_output" | sed -n '/^{/,/^}/p' > "$PLAN_FILE"
        if jq empty "$PLAN_FILE" 2>/dev/null; then
            success "Execution plan created"
            
            # Extract epics from plan (handle both .epics and .epic_ids)
            EPICS=($(jq -r '.epic_waves[] | (.epics // .epic_ids)[]' "$PLAN_FILE" | sort -u))
            return 0
        fi
    fi
    
    error "Failed to parse milestone"
    echo "$pi_output"
    return 1
}

# Create plan for direct epic list
create_epic_plan_with_pi() {
    log "Analyzing epic dependencies..."
    
    # Fetch all epic details
    local epics_json="["
    local first=true
    for epic in "${EPICS[@]}"; do
        local epic_data
        epic_data=$(gh issue view "$epic" --json title,body 2>/dev/null || echo '{"title":"Unknown","body":""}')
        
        [[ "$first" == true ]] && first=false || epics_json+=","
        epics_json+="{\"number\":$epic,\"title\":$(echo "$epic_data" | jq '.title'),\"body\":$(echo "$epic_data" | jq '.body')}"
    done
    epics_json+="]"
    
    local prompt="You are the Commander - analyzing multiple epics for execution order.

# Epics:
$epics_json

# Your Task:
Analyze these epics and determine:
1. Dependencies between them (from their descriptions)
2. Which can run in parallel
3. Optimal execution waves

# Output Format (JSON only):
{
  \"total_epics\": ${#EPICS[@]},
  \"epic_waves\": [
    {
      \"wave\": 1,
      \"epics\": [${EPICS[0]}],
      \"description\": \"Description of this wave\"
    }
  ],
  \"epic_details\": {},
  \"estimated_time\": \"X days\"
}

Output ONLY valid JSON."

    local pi_cmd="pi -p"
    [[ -n "$MODEL" ]] && pi_cmd="pi --model $MODEL -p"
    
    local pi_output
    if pi_output=$($pi_cmd "$prompt" 2>&1); then
        echo "$pi_output" | sed -n '/^{/,/^}/p' > "$PLAN_FILE"
        if jq empty "$PLAN_FILE" 2>/dev/null; then
            success "Execution plan created"
            return 0
        fi
    fi
    
    # Fallback: simple sequential plan
    warn "Could not analyze dependencies, using sequential execution"
    local waves="["
    local wave=1
    for epic in "${EPICS[@]}"; do
        [[ $wave -gt 1 ]] && waves+=","
        waves+="{\"wave\":$wave,\"epics\":[$epic],\"description\":\"Epic #$epic\"}"
        wave=$((wave + 1))
    done
    waves+="]"
    
    echo "{\"total_epics\":${#EPICS[@]},\"epic_waves\":$waves}" > "$PLAN_FILE"
}

# Display execution plan
show_plan() {
    log "Execution Plan:"
    echo ""
    
    local total_epics waves
    total_epics=$(jq -r '.total_epics // .epics | length' "$PLAN_FILE")
    waves=$(jq -r '.epic_waves | length' "$PLAN_FILE")
    
    info "Total epics: $total_epics"
    info "Waves: $waves"
    info "Max parallel: $MAX_PARALLEL_EPICS captains"
    echo ""
    
    # Handle both .epics and .epic_ids formats
    jq -r '.epic_waves[] | "  Wave \(.wave): Epics \((.epics // .epic_ids) | map("#\(.)") | join(", "))\n    └─ \(.description // "No description")"' "$PLAN_FILE"
    echo ""
    
    local est_time
    est_time=$(jq -r '.estimated_time // .estimated_total_time // "unknown"' "$PLAN_FILE")
    info "Estimated time: $est_time"
    echo ""
}

# Initialize or load state
init_state() {
    if [[ "$RESUME" == true ]] && [[ -f "$STATE_FILE" ]]; then
        log "Resuming from saved state..."
        return 0
    fi
    
    jq -n --arg id "$STATE_ID" '{
        id: $id,
        status: "initialized",
        current_wave: 0,
        completed_waves: [],
        epic_status: {},
        retries: {},
        errors: [],
        started_at: now | todate,
        updated_at: now | todate
    }' > "$STATE_FILE"
}

# State management functions
update_state() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_epic_status() {
    local epic="$1"
    jq -r --arg epic "$epic" '.epic_status[$epic] // "pending"' "$STATE_FILE"
}

set_epic_status() {
    local epic="$1"
    local status="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg epic "$epic" --arg status "$status" \
        '.epic_status[$epic] = $status | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_retry_count() {
    local epic="$1"
    jq -r --arg epic "$epic" '.retries[$epic] // 0' "$STATE_FILE"
}

inc_retry_count() {
    local epic="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg epic "$epic" \
        '.retries[$epic] = ((.retries[$epic] // 0) + 1) | .updated_at = (now | todate)' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# Execute a single epic using captain.sh
execute_epic() {
    local epic_num="$1"
    local log_file="$STATE_DIR/epic-$epic_num.log"
    
    echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} Starting..." | tee "$log_file"
    
    set_epic_status "$epic_num" "in_progress"
    
    # Build captain command
    local captain_cmd="$SCRIPT_DIR/captain.sh --epic $epic_num"
    [[ -n "$MODEL" ]] && captain_cmd+=" --model $MODEL"
    [[ "$JOBS" -gt 0 ]] && captain_cmd+=" --jobs $JOBS"
    captain_cmd+=" --wave-timeout $((EPIC_TIMEOUT / 3))"  # Divide timeout among waves
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} [DRY RUN] Would execute: $captain_cmd" | tee -a "$log_file"
        set_epic_status "$epic_num" "completed"
        return 0
    fi
    
    # Execute with timeout
    local timeout_cmd=""
    [[ "$EPIC_TIMEOUT" -gt 0 ]] && timeout_cmd="timeout ${EPIC_TIMEOUT}m"
    
    if $timeout_cmd $captain_cmd 2>&1 | tee -a "$log_file"; then
        echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} ✅ Completed" | tee -a "$log_file"
        set_epic_status "$epic_num" "completed"
        return 0
    else
        local exit_code=$?
        
        # Check log for fatal errors
        local log_content
        log_content=$(cat "$log_file" 2>/dev/null || echo "")
        local error_type
        error_type=$(detect_error_type "$log_content")
        
        if is_fatal_error "$error_type"; then
            echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} 🚫 Fatal error: $(error_type_name $error_type)" | tee -a "$log_file"
            set_epic_status "$epic_num" "fatal"
            record_error "$STATE_FILE" "$epic_num" "$error_type" "Captain hit fatal error"
            return 1
        elif [[ $exit_code -eq 124 ]]; then
            echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} ❌ Timed out" | tee -a "$log_file"
        else
            echo -e "${COLOR_CAPTAIN}[Captain #$epic_num]${NC} ❌ Failed (exit $exit_code)" | tee -a "$log_file"
        fi
        set_epic_status "$epic_num" "failed"
        inc_retry_count "$epic_num"
        return 1
    fi
}

# Execute a wave of epics
execute_wave() {
    local wave_num="$1"
    
    log "═══════════════════════════════════════════════════════════"
    log "🌊 Executing Wave $wave_num"
    log "═══════════════════════════════════════════════════════════"
    
    # Get epics for this wave (handle both .epics and .epic_ids)
    local epics
    epics=$(jq -r --argjson wave "$wave_num" '.epic_waves[] | select(.wave == $wave) | (.epics // .epic_ids)[]' "$PLAN_FILE")
    
    if [[ -z "$epics" ]]; then
        warn "No epics in wave $wave_num"
        return 0
    fi
    
    # Filter to pending/retriable epics
    local epics_to_run=()
    for epic in $epics; do
        local status retries
        status=$(get_epic_status "$epic")
        retries=$(get_retry_count "$epic")
        
        if [[ "$status" == "completed" ]]; then
            info "Epic #$epic already completed, skipping"
        elif [[ "$status" == "failed" ]] && [[ "$retries" -ge "$MAX_RETRIES" ]]; then
            warn "Epic #$epic failed $retries times, max retries reached"
        else
            epics_to_run+=("$epic")
        fi
    done
    
    if [[ ${#epics_to_run[@]} -eq 0 ]]; then
        info "All epics in wave $wave_num handled"
        return 0
    fi
    
    info "Running epics: ${epics_to_run[*]}"
    echo ""
    
    # Run epics with parallel limit
    local pids=()
    local active_jobs=0
    
    for epic in "${epics_to_run[@]}"; do
        # Wait for slot if at capacity
        while [[ $active_jobs -ge $MAX_PARALLEL_EPICS ]]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    unset "pids[$i]"
                    active_jobs=$((active_jobs - 1))
                    break
                fi
            done
            sleep 2
        done
        
        # Start epic
        execute_epic "$epic" &
        pids+=($!)
        active_jobs=$((active_jobs + 1))
        info "Started Captain for Epic #$epic (PID: ${pids[-1]})"
        sleep 3  # Stagger starts
    done
    
    # Wait for all
    info "Waiting for wave $wave_num captains to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    echo ""
}

# Check if wave is complete
is_wave_complete() {
    local wave_num="$1"
    
    local epics
    epics=$(jq -r --argjson wave "$wave_num" '.epic_waves[] | select(.wave == $wave) | (.epics // .epic_ids)[]' "$PLAN_FILE")
    
    for epic in $epics; do
        local status retries
        status=$(get_epic_status "$epic")
        # Completed or fatal count as "done" (no point retrying fatal)
        if [[ "$status" != "completed" ]] && [[ "$status" != "fatal" ]]; then
            retries=$(get_retry_count "$epic")
            if [[ "$retries" -lt "$MAX_RETRIES" ]]; then
                return 1
            fi
        fi
    done
    return 0
}

# Final report
generate_report() {
    log "═══════════════════════════════════════════════════════════"
    log "📊 Commander's Report"
    log "═══════════════════════════════════════════════════════════"
    echo ""
    
    local completed failed
    completed=$(jq -r '[.epic_status | to_entries[] | select(.value == "completed")] | length' "$STATE_FILE")
    failed=$(jq -r '[.epic_status | to_entries[] | select(.value == "failed")] | length' "$STATE_FILE")
    local total=$((completed + failed))
    
    info "Epics completed: $completed/$total"
    [[ $failed -gt 0 ]] && warn "Epics failed: $failed"
    echo ""
    
    # List results
    jq -r '.epic_status | to_entries[] | "  Epic #\(.key): \(.value)"' "$STATE_FILE"
    echo ""
    
    # Post to milestone if applicable
    if [[ -n "$MILESTONE_NUM" ]] && [[ "$DRY_RUN" != true ]]; then
        local summary="## ⭐ Commander's Report

**Execution Summary**
- ✅ Completed: $completed/$total epics
- ❌ Failed: $failed epics

### Epic Status:
$(jq -r '.epic_status | to_entries | map("- Epic #\(.key): \(.value)") | join("\n")' "$STATE_FILE")

---
*Automated by Pi Commander*"

        gh issue comment "$MILESTONE_NUM" --body "$summary" 2>/dev/null || warn "Failed to post summary"
        success "Posted summary to milestone #$MILESTONE_NUM"
    fi
}

# Main execution
main() {
    # Handle different input modes
    if [[ -n "$PROJECT_SPEC" ]]; then
        # Generate project from scratch
        if [[ "$RESUME" != true ]] || [[ ! -f "$PLAN_FILE" ]]; then
            generate_project_plan || exit 1
            show_plan
            
            if [[ "$DRY_RUN" == true ]]; then
                log "🔍 DRY RUN: Would create GitHub issues (skipped)"
                log "🔍 DRY RUN complete. No changes made."
                exit 0
            fi
            
            echo ""
            log "Creating GitHub issues..."
            create_github_issues
        else
            log "Using existing project plan"
            EPICS=($(jq -r '.created_epic_numbers[]' "$PLAN_FILE" 2>/dev/null || echo ""))
        fi
        
    elif [[ -n "$MILESTONE_NUM" ]]; then
        # Parse milestone issue
        if [[ "$RESUME" != true ]] || [[ ! -f "$PLAN_FILE" ]]; then
            fetch_milestone
            parse_milestone_with_pi || exit 1
        else
            log "Using existing milestone plan"
            EPICS=($(jq -r '.epic_waves[] | (.epics // .epic_ids)[]' "$PLAN_FILE" | sort -u))
        fi
        
    else
        # Direct epic list
        if [[ "$RESUME" != true ]] || [[ ! -f "$PLAN_FILE" ]]; then
            create_epic_plan_with_pi
        else
            log "Using existing epic plan"
        fi
    fi
    
    # Validate plan structure before proceeding
    if ! validate_plan "$PLAN_FILE" "epic_waves"; then
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
    total_waves=$(jq -r '.epic_waves | length' "$PLAN_FILE")
    
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
        fatal_count=$(jq -r '[.epic_status | to_entries[] | select(.value == "fatal")] | length' "$STATE_FILE")
        if [[ "$fatal_count" -gt 0 ]]; then
            error "Fatal errors detected. Cannot continue."
            error "Please check: quota, billing, or API key issues."
            update_state "status" '"fatal_error"'
            exit 1
        fi
        
        # Execute wave with retries
        local attempt=0
        while ! is_wave_complete "$wave" && [[ $attempt -lt $MAX_RETRIES ]]; do
            execute_wave "$wave"
            attempt=$((attempt + 1))
            
            if ! is_wave_complete "$wave"; then
                # Calculate backoff delay
                local delay
                delay=$(calculate_backoff $attempt)
                warn "Wave $wave incomplete after attempt $attempt. Retrying in ${delay}s..."
                sleep "$delay"
            fi
        done
        
        # Mark wave complete
        local completed_waves
        completed_waves=$(jq -r '.completed_waves' "$STATE_FILE")
        completed_waves=$(echo "$completed_waves" | jq ". + [$wave]")
        update_state "completed_waves" "$completed_waves"
        
        success "Wave $wave complete"
        echo ""
    done
    
    generate_report
    update_state "status" '"completed"'
    
    log "═══════════════════════════════════════════════════════════"
    success "Commander mission complete!"
    log "═══════════════════════════════════════════════════════════"
    echo ""
    log "State: $STATE_FILE"
    log "Logs: $STATE_DIR/"
}

main "$@"
