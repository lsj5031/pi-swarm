#!/usr/bin/env bash
set -euo pipefail

# Pi Swarm - Parallel GitHub issue processing with pi agent
# Usage: swarm.sh [options] <issue-numbers...>

WORKTREE_DIR=".worktrees"
MODEL=""
PUSH=true
CREATE_PR=true
CLEANUP=true
MAX_JOBS=0  # 0 = unlimited
TIMEOUT=0   # 0 = no timeout (in minutes)
DRY_RUN=false
ISSUES=()

# Colors for parallel logs (exported as string for subprocess compatibility)
COLOR_BLUE='\033[0;34m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_RED='\033[0;31m'
NC='\033[0m'

# Check dependencies
check_dependencies() {
    local missing=()
    command -v gh >/dev/null 2>&1 || missing+=("gh")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v pi >/dev/null 2>&1 || missing+=("pi")
    command -v git >/dev/null 2>&1 || missing+=("git")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing[*]}"
        echo "Please install them before running this script."
        exit 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-push)
            PUSH=false
            shift
            ;;
        --pr)
            CREATE_PR=true
            PUSH=true  # PR requires push
            shift
            ;;
        --no-pr)
            CREATE_PR=false
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        -j|--jobs)
            MAX_JOBS="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: swarm.sh [options] <issue-numbers...>"
            echo ""
            echo "Options:"
            echo "  --model <name>    Model to use (sonnet, opus, etc.)"
            echo "  --push            Push branches after completion (default)"
            echo "  --no-push         Don't push branches"
            echo "  --pr              Create PRs after completion (default)"
            echo "  --no-pr           Don't create PRs"
            echo "  --cleanup         Delete worktrees after success (default)"
            echo "  --no-cleanup      Keep worktrees after completion"
            echo "  -j, --jobs <n>    Max parallel jobs (default: unlimited)"
            echo "  --timeout <min>   Timeout per issue in minutes (default: no timeout)"
            echo "  --dry-run         Show what would be done without executing"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            ISSUES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "Error: No issue numbers provided"
    echo "Usage: swarm.sh [options] <issue-numbers...>"
    exit 1
fi

# Check dependencies before proceeding
check_dependencies

# Ensure worktree directory exists
mkdir -p "$WORKTREE_DIR"

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [[ -z "$REPO" ]]; then
    echo "Error: Not in a GitHub repository or gh not authenticated"
    exit 1
fi

# Get default branch dynamically
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")

echo "🐝 Pi Swarm starting for $REPO"
echo "📋 Issues: ${ISSUES[*]}"
echo "🌿 Default branch: $DEFAULT_BRANCH"
[[ $MAX_JOBS -gt 0 ]] && echo "⚡ Max parallel jobs: $MAX_JOBS"
[[ $TIMEOUT -gt 0 ]] && echo "⏱️  Timeout: ${TIMEOUT}m per issue"
[[ "$DRY_RUN" == true ]] && echo "🔍 DRY RUN MODE - no changes will be made"
echo ""

# Get color by index
get_color() {
    local idx=$1
    local colors=("$COLOR_BLUE" "$COLOR_GREEN" "$COLOR_YELLOW" "$COLOR_MAGENTA" "$COLOR_CYAN" "$COLOR_RED")
    echo "${colors[$((idx % ${#colors[@]}))]}"
}

# Function to process a single issue
process_issue() {
    local issue_num=$1
    local color_idx=$2
    local color
    color=$(get_color "$color_idx")
    local tag="${color}[Issue #$issue_num]${NC}"
    
    local worktree_path="$WORKTREE_DIR/issue-$issue_num"
    local log_file="$WORKTREE_DIR/issue-$issue_num.log"
    local branch_name="issue/$issue_num"

    echo -e "$tag Starting..." | tee "$log_file"

    # Fetch issue details
    local issue_json
    issue_json=$(gh issue view "$issue_num" --json title,body,comments 2>>"$log_file")
    if [[ -z "$issue_json" ]]; then
        echo -e "$tag ❌ Failed to fetch issue" | tee -a "$log_file"
        return 1
    fi

    local title
    local body
    local comments
    title=$(echo "$issue_json" | jq -r '.title')
    body=$(echo "$issue_json" | jq -r '.body // "No description provided"')
    comments=$(echo "$issue_json" | jq -r '.comments[]? | "\n--- Comment by " + .author.login + " ---\n" + .body' 2>/dev/null || echo "")

    echo -e "$tag Title: $title" | tee -a "$log_file"

    # Dry run mode - just show what would happen
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "$tag [DRY RUN] Would create worktree at $worktree_path" | tee -a "$log_file"
        echo -e "$tag [DRY RUN] Would create branch $branch_name" | tee -a "$log_file"
        echo -e "$tag [DRY RUN] Would run pi agent with prompt for issue #$issue_num" | tee -a "$log_file"
        [[ "$PUSH" == true ]] && echo -e "$tag [DRY RUN] Would push to origin/$branch_name" | tee -a "$log_file"
        [[ "$CREATE_PR" == true ]] && echo -e "$tag [DRY RUN] Would create PR against $DEFAULT_BRANCH" | tee -a "$log_file"
        return 0
    fi

    # Clean up any stale worktree references
    git worktree prune 2>/dev/null || true

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        echo -e "$tag Worktree exists, reusing..." | tee -a "$log_file"
    else
        # Remove stale worktree dir if exists
        rm -rf "$worktree_path" 2>/dev/null || true

        # Create branch and worktree
        if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
            echo -e "$tag Branch exists, creating worktree..." | tee -a "$log_file"
            git worktree add -f "$worktree_path" "$branch_name" 2>>"$log_file"
        else
            echo -e "$tag Creating new branch and worktree..." | tee -a "$log_file"
            git worktree add -f -b "$branch_name" "$worktree_path" 2>>"$log_file"
        fi
    fi

    # Build the prompt
    local prompt="Work on GitHub Issue #$issue_num: $title

$body

$comments

Instructions:
1. Read the issue carefully and understand what needs to be done
2. Implement the changes described
3. Run tests to verify your changes work
4. Run linting and formatting
5. Commit your changes with a descriptive message that references issue #$issue_num
6. Summarize what you did at the end"

    echo -e "$tag Running pi agent..." | tee -a "$log_file"

    # Build pi command
    local pi_cmd="pi -p"
    if [[ -n "$MODEL" ]]; then
        pi_cmd="pi --model $MODEL -p"
    fi

    # Run pi agent in the worktree (with optional timeout)
    local abs_log_file
    abs_log_file="$(pwd)/$log_file"
    local json_log_file="${abs_log_file%.log}.jsonl"
    
    local timeout_cmd=""
    if [[ $TIMEOUT -gt 0 ]]; then
        timeout_cmd="timeout ${TIMEOUT}m"
    fi

    # Helper function to parse and display pi output
    parse_pi_output() {
        local tag="$1"
        local log_file="$2"
        local json_log_file="$3"
        
        while IFS= read -r line; do
            # Log raw JSON to jsonl file
            echo "$line" >> "$json_log_file"

            # Parse JSON with jq
            if [[ "$line" =~ ^\{.*\}$ ]]; then
                local type
                type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
                
                case "$type" in
                    tool_execution_start)
                        local tool args
                        tool=$(echo "$line" | jq -r '.toolName // "unknown"' 2>/dev/null)
                        args=$(echo "$line" | jq -r '.args // {} | tostring' 2>/dev/null)
                        # Truncate args if too long
                        if [[ ${#args} -gt 100 ]]; then args="${args:0:97}..."; fi
                        echo -e "$tag 🔧 Tool: $tool $args" | tee -a "$log_file"
                        ;;
                    message_start)
                        local role
                        role=$(echo "$line" | jq -r '.message.role // empty' 2>/dev/null)
                        if [[ "$role" == "assistant" ]]; then
                            echo -e "$tag 🤖 Agent is thinking/writing..." | tee -a "$log_file"
                        fi
                        ;;
                    error|hook_error)
                        local msg
                        msg=$(echo "$line" | jq -r '.error // .message // "Unknown error"' 2>/dev/null)
                        echo -e "$tag ❌ Error: $msg" | tee -a "$log_file"
                        ;;
                esac
            else
                # Non-JSON line (likely system error or timeout)
                echo -e "$tag $line" | tee -a "$log_file"
            fi
        done
    }

    # Use --mode json for better visibility
    local pi_json_cmd="pi --mode json"
    if [[ -n "$MODEL" ]]; then
        pi_json_cmd="pi --mode json --model $MODEL"
    fi
    
    if (cd "$worktree_path" && $timeout_cmd $pi_json_cmd "$prompt" 2>&1) | parse_pi_output "$tag" "$abs_log_file" "$json_log_file"; then
        echo -e "$tag ✅ Agent completed" | tee -a "$log_file"

        # Check for uncommitted changes and ask agent to fix
        if [[ -n $(cd "$worktree_path" && git status --porcelain) ]]; then
            echo -e "$tag ⚠️  Uncommitted changes detected. Asking agent to commit..." | tee -a "$log_file"
            
            local followup_prompt="It seems there are uncommitted changes. Please commit your changes now. If there are pre-commit hook errors, please fix them."
            (cd "$worktree_path" && $timeout_cmd $pi_json_cmd "$followup_prompt" 2>&1) | parse_pi_output "$tag" "$abs_log_file" "$json_log_file"
        fi

        # Push if requested
        if [[ "$PUSH" == true ]]; then
            echo -e "$tag Pushing branch..." | tee -a "$log_file"
            (cd "$worktree_path" && git push -u origin "$branch_name" 2>&1) | tee -a "$log_file"
        fi

        # Create PR if requested
        if [[ "$CREATE_PR" == true ]]; then
            # Verify we have commits to PR
            if (cd "$worktree_path" && git diff --quiet "HEAD" "origin/$DEFAULT_BRANCH" 2>/dev/null); then
                echo -e "$tag ❌ No changes detected compared to $DEFAULT_BRANCH, marking as failed..." | tee -a "$log_file"
                return 1
            else
                echo -e "$tag Creating PR..." | tee -a "$log_file"
                local pr_title="$title"
                local pr_body="Resolves #$issue_num

## Summary
This PR addresses the changes requested in issue #$issue_num.

## Changes
See commits for details."
                local pr_output
                if pr_output=$(cd "$worktree_path" && gh pr create \
                    --base "$DEFAULT_BRANCH" \
                    --title "$pr_title" \
                    --body "$pr_body" 2>&1); then
                    echo "$pr_output" | tee -a "$log_file"
                    # Extract PR URL (usually the last line)
                    local pr_url
                    pr_url=$(echo "$pr_output" | tail -n 1)
                    if [[ "$pr_url" =~ https://github.com/.*/pull/[0-9]+ ]]; then
                        echo "$pr_url" > "$WORKTREE_DIR/issue-$issue_num.pr"
                    fi
                else
                    echo "$pr_output" | tee -a "$log_file"
                    echo -e "$tag ⚠️ PR creation failed (may already exist), continuing..." | tee -a "$log_file"
                fi
            fi
        fi

        # Cleanup if requested - but preserve worktree if there are uncommitted changes
        if [[ "$CLEANUP" == true ]]; then
            local has_uncommitted=false
            if [[ -d "$worktree_path" ]] && [[ -n $(cd "$worktree_path" && git status --porcelain 2>/dev/null) ]]; then
                has_uncommitted=true
            fi
            
            if [[ "$has_uncommitted" == true ]]; then
                echo -e "$tag ⚠️  Preserving worktree - uncommitted changes exist at $worktree_path" | tee -a "$log_file"
            else
                echo -e "$tag Cleaning up worktree..." | tee -a "$log_file"
                git worktree remove "$worktree_path" 2>>"$log_file" || true
            fi
        fi
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo -e "$tag ❌ Agent timed out after ${TIMEOUT}m" | tee -a "$log_file"
        else
            echo -e "$tag ❌ Agent failed (exit code: $exit_code)" | tee -a "$log_file"
        fi
        return 1
    fi
}

# Export function and variables for parallel execution
export -f process_issue get_color
export WORKTREE_DIR MODEL PUSH CREATE_PR CLEANUP DEFAULT_BRANCH DRY_RUN TIMEOUT
export COLOR_BLUE COLOR_GREEN COLOR_YELLOW COLOR_MAGENTA COLOR_CYAN COLOR_RED NC

# Track PIDs and process group for parallel execution
declare -A PIDS
SWARM_PGID=$$

# Trap to handle interruption - kill only our process group
cleanup_swarm() {
    echo ""
    echo "🛑 Swarm interrupted! Cleaning up..."
    
    # Kill all tracked background jobs
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            # Kill the process and its children
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    echo "Cleanup complete."
    exit 1
}

trap cleanup_swarm SIGINT SIGTERM

# Dry run summary and exit
if [[ "$DRY_RUN" == true ]]; then
    echo "🔍 DRY RUN: Previewing actions for ${#ISSUES[@]} issues..."
    echo ""
    idx=0
    for issue_num in "${ISSUES[@]}"; do
        process_issue "$issue_num" "$idx"
        idx=$((idx + 1))
        echo ""
    done
    echo "🔍 DRY RUN complete. No changes were made."
    exit 0
fi

echo "🚀 Spawning ${#ISSUES[@]} parallel pi agents..."
echo ""

# Semaphore for job limiting
active_jobs=0

wait_for_slot() {
    if [[ $MAX_JOBS -gt 0 ]]; then
        while [[ $active_jobs -ge $MAX_JOBS ]]; do
            # Wait for any job to finish
            for issue_num in "${!PIDS[@]}"; do
                if ! kill -0 "${PIDS[$issue_num]}" 2>/dev/null; then
                    unset "PIDS[$issue_num]"
                    active_jobs=$((active_jobs - 1))
                    break
                fi
            done
            sleep 1
        done
    fi
}

# Start issues (with optional job limiting)
idx=0
for issue_num in "${ISSUES[@]}"; do
    wait_for_slot
    
    process_issue "$issue_num" "$idx" &
    PIDS[$issue_num]=$!
    active_jobs=$((active_jobs + 1))
    echo "  Started issue #$issue_num (PID: ${PIDS[$issue_num]})"
    idx=$((idx + 1))
    sleep 2  # Brief stagger to avoid concurrent initialization issues
done

echo ""
echo "⏳ Waiting for all agents to complete..."
echo "   Monitor with: tail -f $WORKTREE_DIR/issue-*.log"
echo ""

# Wait for all and collect results
FAILED=()
SUCCEEDED=()

for issue_num in "${ISSUES[@]}"; do
    if [[ -n "${PIDS[$issue_num]:-}" ]]; then
        if wait "${PIDS[$issue_num]}"; then
            SUCCEEDED+=("$issue_num")
        else
            FAILED+=("$issue_num")
        fi
    fi
done

# Summary
echo ""
echo "═══════════════════════════════════════"
echo "🐝 Pi Swarm Complete"
echo "═══════════════════════════════════════"
echo "✅ Succeeded: ${SUCCEEDED[*]:-none}"

if [[ ${#SUCCEEDED[@]} -gt 0 ]]; then
    echo "🔗 Created PRs:"
    for issue_num in "${SUCCEEDED[@]}"; do
        if [[ -f "$WORKTREE_DIR/issue-$issue_num.pr" ]]; then
            pr_url=$(cat "$WORKTREE_DIR/issue-$issue_num.pr")
            echo "   - Issue #$issue_num: $pr_url"
        fi
    done
fi

echo "❌ Failed: ${FAILED[*]:-none}"
echo ""
echo "Logs: $WORKTREE_DIR/issue-*.log"
echo "Worktrees: $WORKTREE_DIR/issue-*/"

# Exit with error if any failed
[[ ${#FAILED[@]} -eq 0 ]]
