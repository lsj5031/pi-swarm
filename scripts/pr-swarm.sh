#!/usr/bin/env bash
set -euo pipefail

# Pi PR Swarm - Parallel GitHub PR review and fix with pi agent
# Usage: pr-swarm.sh [options] <pr-numbers...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKTREE_DIR=".worktrees"
MODEL=""
PUSH=true
CLEANUP=true
MAX_JOBS=0  # 0 = unlimited
TIMEOUT=0   # 0 = no timeout (in minutes)
DRY_RUN=false
PRS=()

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
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        -j|--jobs)
            validate_int "$2" "--jobs" || exit 1
            MAX_JOBS="$2"
            shift 2
            ;;
        --timeout)
            validate_int "$2" "--timeout" || exit 1
            TIMEOUT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: pr-swarm.sh [options] <pr-numbers...>"
            echo ""
            echo "Options:"
            echo "  --model <name>    Model to use (sonnet, opus, etc.)"
            echo "  --push            Push fixes to PR (default)"
            echo "  --no-push         Don't push fixes (dry run fix)"
            echo "  --cleanup         Delete worktrees after success (default)"
            echo "  --no-cleanup      Keep worktrees after completion"
            echo "  -j, --jobs <n>    Max parallel jobs (default: unlimited)"
            echo "  --timeout <min>   Timeout per PR in minutes (default: no timeout)"
            echo "  --dry-run         Show what would be done without executing"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            PRS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PRS[@]} -eq 0 ]]; then
    echo "Error: No PR numbers provided"
    echo "Usage: pr-swarm.sh [options] <pr-numbers...>"
    exit 1
fi

require_deps gh jq pi git || exit 1

mkdir -p "$WORKTREE_DIR"

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [[ -z "$REPO" ]]; then
    echo "Error: Not in a GitHub repository or gh not authenticated"
    exit 1
fi

echo "🐝 Pi PR Swarm starting for $REPO"
echo "📋 PRs: ${PRS[*]}"
[[ $MAX_JOBS -gt 0 ]] && echo "⚡ Max parallel jobs: $MAX_JOBS"
[[ $TIMEOUT -gt 0 ]] && echo "⏱️  Timeout: ${TIMEOUT}m per PR"
[[ "$DRY_RUN" == true ]] && echo "🔍 DRY RUN MODE"
echo ""

process_pr() {
    local pr_num=$1
    local color_idx=$2
    local color
    color=$(get_color "$color_idx")
    local tag="${color}[PR #$pr_num]${NC}"
    
    local worktree_path="$WORKTREE_DIR/pr-$pr_num"
    local log_file="$WORKTREE_DIR/pr-$pr_num.log"
    local branch_name="review/pr-$pr_num"

    echo -e "$tag Starting..." | tee "$log_file"

    # Fetch PR details
    local pr_json
    pr_json=$(gh pr view "$pr_num" --json title,body,headRefName,headRepository,url,maintainerCanModify 2>>"$log_file")
    if [[ -z "$pr_json" ]]; then
        echo -e "$tag ❌ Failed to fetch PR details" | tee -a "$log_file"
        return 1
    fi

    local title body head_ref head_repo_url can_modify
    title=$(echo "$pr_json" | jq -r '.title')
    body=$(echo "$pr_json" | jq -r '.body // "No description"')
    head_ref=$(echo "$pr_json" | jq -r '.headRefName')
    head_repo_url=$(echo "$pr_json" | jq -r '.headRepository.url')
    can_modify=$(echo "$pr_json" | jq -r '.maintainerCanModify')

    if [[ -z "$head_repo_url" || "$head_repo_url" == "null" ]]; then
        # Fallback: maybe it's in the same repo?
        head_repo_url=$(gh repo view --json url -q .url)
        echo -e "$tag ⚠️  Head repo URL missing, using current repo URL: $head_repo_url" | tee -a "$log_file"
    fi

    echo -e "$tag Title: $title" | tee -a "$log_file"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "$tag [DRY RUN] Would review PR #$pr_num" | tee -a "$log_file"
        return 0
    fi

    # Prune stale worktrees
    git worktree prune 2>/dev/null || true

    # Clean up existing worktree/branch
    if [[ -d "$worktree_path" ]]; then
        rm -rf "$worktree_path"
    fi
    # We force fetch the branch to ensure we have latest
    echo -e "$tag Fetching PR branch from $head_repo_url $head_ref:$branch_name..." | tee -a "$log_file"
    
    if ! git fetch -f "$head_repo_url" "$head_ref:$branch_name" 2>>"$log_file"; then
        echo -e "$tag ❌ Git fetch failed. See log for details." | tee -a "$log_file"
        cat "$log_file"
        return 1
    fi
    
    # Create worktree
    echo -e "$tag Creating worktree..." | tee -a "$log_file"
    git worktree add -f "$worktree_path" "$branch_name" 2>>"$log_file"

    # Build prompt
    local prompt="Review PR #$pr_num: $title

$body

Instructions:
1. Review the code changes in this PR carefully.
2. Identify bugs, logic errors, security vulnerabilities, or style issues.
3. If you find issues, FIX THEM by editing the files directly.
4. Run tests to verify your fixes work.
5. If the code is good and needs no changes, explicitely state 'No issues found'.
6. Provide a concise summary of your review and any actions taken."

    echo -e "$tag Running pi agent..." | tee -a "$log_file"

    local pi_cmd="pi --mode json"
    [[ -n "$MODEL" ]] && pi_cmd="pi --mode json --model $MODEL"

    local abs_log_file="$(pwd)/$log_file"
    local json_log_file="${abs_log_file%.log}.jsonl"
    
    local timeout_cmd=""
    [[ $TIMEOUT -gt 0 ]] && timeout_cmd="timeout ${TIMEOUT}m"

    local pi_output
    # Capture output to variable to extract summary later? No, difficult with streaming.
    # Just run it.
    
    if (cd "$worktree_path" && $timeout_cmd $pi_cmd "$prompt" 2>&1) | parse_pi_output "$tag" "$abs_log_file" "$json_log_file"; then
        echo -e "$tag ✅ Agent completed" | tee -a "$log_file"

        # Check for uncommitted changes
        if [[ -n $(cd "$worktree_path" && git status --porcelain) ]]; then
            echo -e "$tag ⚠️  Uncommitted changes. Asking agent to commit..." | tee -a "$log_file"
            local followup="Please commit your changes now. Fix any pre-commit errors."
            (cd "$worktree_path" && $timeout_cmd $pi_cmd "$followup" 2>&1) | parse_pi_output "$tag" "$abs_log_file" "$json_log_file"
        fi

        local push_output=""
        local changes_made=false
        
        if [[ "$PUSH" == true ]]; then
            # Check if we have permission to push (maintainerCanModify)
            if [[ "$can_modify" == "false" ]]; then
                echo -e "$tag ⚠️  Cannot push: maintainerCanModify is disabled for this fork" | tee -a "$log_file"
                echo -e "$tag    Review changes are in $worktree_path but cannot be pushed" | tee -a "$log_file"
            else
                echo -e "$tag Pushing changes..." | tee -a "$log_file"
                # Push to the head repo and ref
                # We use the URL and Ref we got from JSON
                if push_output=$(cd "$worktree_path" && git push "$head_repo_url" "$branch_name:$head_ref" 2>&1); then
                    echo "$push_output" | tee -a "$log_file"
                    if [[ "$push_output" == *"Everything up-to-date"* ]]; then
                        changes_made=false
                    else
                        changes_made=true
                    fi
                else
                    echo -e "$tag ❌ Push failed" | tee -a "$log_file"
                    echo "$push_output" >> "$log_file"
                    changes_made=false
                fi
            fi
        fi

        # Generate summary comment
        
        local summary=""
        if [[ -f "$json_log_file" ]]; then
            # First try: get last assistant message from agent_end
            summary=$(grep '"type":"agent_end"' "$json_log_file" | tail -1 | jq -r '
                .messages 
                | map(select(.role == "assistant" and (.content | length > 0))) 
                | last 
                | .content 
                | map(select(.type == "text") | .text) 
                | join("\n")
            ' 2>/dev/null || echo "")
            
            # Fallback: if empty (e.g., due to errors), get last message_end with actual content
            if [[ -z "$summary" || "$summary" == "null" ]]; then
                summary=$(grep '"type":"message_end"' "$json_log_file" | grep '"role":"assistant"' | \
                    jq -r 'select(.message.content[0].text != null and .message.content[0].text != "") | .message.content[0].text' 2>/dev/null | tail -1 || echo "")
            fi
            
            # Final fallback: check for error message
            if [[ -z "$summary" || "$summary" == "null" ]]; then
                local error_msg
                error_msg=$(grep '"type":"agent_end"' "$json_log_file" | tail -1 | jq -r '.messages[-1].errorMessage // empty' 2>/dev/null)
                if [[ -n "$error_msg" ]]; then
                    summary="⚠️ Agent encountered an error: Rate limit / API error. Check logs for details."
                fi
            fi
        fi
        
        local comment_body="## Pi Agent Review

$summary

(Automated review by Pi Swarm)"

        if [[ "$changes_made" == true ]]; then
             comment_body="## Pi Agent Review & Fixes

I have reviewed this PR and applied fixes.

$summary

(Automated review by Pi Swarm)"
        fi

        # If no changes made, and we want to comment "All good"
        if [[ "$changes_made" == false ]]; then
             comment_body="## Pi Agent Review

I have reviewed this PR.

$summary

(Automated review by Pi Swarm)"
        fi

        echo -e "$tag Posting comment..." | tee -a "$log_file"
        gh pr comment "$pr_num" --body "$comment_body" >> "$log_file" 2>&1 || echo -e "$tag ⚠️ Comment failed" | tee -a "$log_file"

        # Cleanup - but preserve worktree if there are uncommitted changes
        local has_uncommitted=false
        if [[ -d "$worktree_path" ]] && [[ -n $(cd "$worktree_path" && git status --porcelain 2>/dev/null) ]]; then
            has_uncommitted=true
        fi

        if [[ "$CLEANUP" == true ]]; then
            if [[ "$has_uncommitted" == true ]]; then
                echo -e "$tag ⚠️  Preserving worktree - uncommitted changes exist at $worktree_path" | tee -a "$log_file"
            else
                echo -e "$tag Cleaning up..." | tee -a "$log_file"
                git worktree remove "$worktree_path" --force 2>>"$log_file" || true
                git branch -D "$branch_name" 2>>"$log_file" || true
            fi
        fi
        return 0
    else
        echo -e "$tag ❌ Agent failed" | tee -a "$log_file"
        return 1
    fi
}

export -f process_pr get_color parse_pi_output
export WORKTREE_DIR MODEL PUSH CLEANUP DRY_RUN TIMEOUT
export COLOR_BLUE COLOR_GREEN COLOR_YELLOW COLOR_MAGENTA COLOR_CYAN COLOR_RED NC

declare -A PIDS

cleanup_swarm() {
    echo ""
    echo "🛑 Swarm interrupted! Cleaning up..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    done
    exit 1
}

trap cleanup_swarm SIGINT SIGTERM

if [[ "$DRY_RUN" == true ]]; then
    echo "🔍 DRY RUN PREVIEW"
    idx=0
    for pr in "${PRS[@]}"; do
        process_pr "$pr" "$idx"
        idx=$((idx + 1))
    done
    exit 0
fi

echo "🚀 Spawning agents..."
active_jobs=0

wait_for_slot() {
    if [[ $MAX_JOBS -gt 0 ]]; then
        while [[ $active_jobs -ge $MAX_JOBS ]]; do
            for pr in "${!PIDS[@]}"; do
                if ! kill -0 "${PIDS[$pr]}" 2>/dev/null; then
                    unset "PIDS[$pr]"
                    active_jobs=$((active_jobs - 1))
                    break
                fi
            done
            sleep 1
        done
    fi
}

idx=0
for pr in "${PRS[@]}"; do
    wait_for_slot
    process_pr "$pr" "$idx" &
    PIDS[$pr]=$!
    active_jobs=$((active_jobs + 1))
    echo "  Started PR #$pr (PID: ${PIDS[$pr]})"
    idx=$((idx + 1))
    sleep 2
done

echo ""
echo "⏳ Waiting for completion..."
echo "   Monitor with: tail -f $WORKTREE_DIR/pr-*.log"
echo ""

# Wait for all and collect results
FAILED=()
SUCCEEDED=()

for pr in "${PRS[@]}"; do
    if [[ -n "${PIDS[$pr]:-}" ]]; then
        if wait "${PIDS[$pr]}"; then
            SUCCEEDED+=("$pr")
        else
            FAILED+=("$pr")
        fi
    fi
done

# Summary
echo ""
echo "═══════════════════════════════════════"
echo "🐝 Pi PR Swarm Complete"
echo "═══════════════════════════════════════"
echo "✅ Succeeded: ${SUCCEEDED[*]:-none}"
echo "❌ Failed: ${FAILED[*]:-none}"
echo ""
echo "Logs: $WORKTREE_DIR/pr-*.log"

# Exit with error if any failed
[[ ${#FAILED[@]} -eq 0 ]]
