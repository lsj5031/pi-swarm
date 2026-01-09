#!/usr/bin/env bash
# State management utilities for pi-swarm
# Simple, durable state tracking using JSON files with atomic writes
#
# CONCURRENCY NOTE: These utilities use atomic file writes (temp + mv) which
# are safe for single-writer scenarios. They are NOT safe for concurrent
# multi-process updates to the same state file without external locking.
# If multiple processes need to update the same state file, wrap calls with
# lock_acquire/lock_release around the state file's lock.

STATE_VERSION="1"

# ═══════════════════════════════════════════════════════════════════════════
# Atomic File Operations
# ═══════════════════════════════════════════════════════════════════════════

# Atomic write - write to temp, then move (atomic on same filesystem)
atomic_write() {
    local file="$1"
    local content="$2"
    
    local dir
    dir=$(dirname "$file")
    mkdir -p "$dir"
    
    local tmp
    tmp=$(mktemp "$dir/.tmp.XXXXXX")
    
    echo "$content" > "$tmp"
    mv "$tmp" "$file"
}

# Atomic JSON update with jq
# Usage: atomic_json_update <file> <jq_filter> [jq_args...]
atomic_json_update() {
    local file="$1"
    shift
    local args=("$@")
    
    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi
    
    local tmp
    tmp=$(mktemp "$(dirname "$file")/.tmp.XXXXXX")
    
    if jq "${args[@]}" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# State File Management
# ═══════════════════════════════════════════════════════════════════════════

# Initialize state file
init_state_file() {
    local file="$1"
    local id="$2"
    local type="$3"  # "epic" or "project" or "milestone"
    
    if [[ -f "$file" ]]; then
        # Check if resuming
        local existing_status
        existing_status=$(jq -r '.status // "unknown"' "$file" 2>/dev/null)
        if [[ "$existing_status" != "completed" ]]; then
            echo "Resuming from existing state (status: $existing_status)" >&2
            return 0
        fi
    fi
    
    local now
    now=$(date -Iseconds)
    
    cat > "$file" << EOF
{
  "version": "$STATE_VERSION",
  "id": "$id",
  "type": "$type",
  "status": "initialized",
  "current_wave": 0,
  "completed_waves": [],
  "tasks": {},
  "errors": [],
  "created_at": "$now",
  "updated_at": "$now",
  "pid": $$,
  "hostname": "$(hostname)"
}
EOF
}

# Update a field in state
state_set() {
    local file="$1"
    local key="$2"
    local value="$3"
    local is_json="${4:-false}"
    
    local now
    now=$(date -Iseconds)
    
    if [[ "$is_json" == "true" ]]; then
        atomic_json_update "$file" \
            --arg key "$key" \
            --argjson value "$value" \
            --arg now "$now" \
            --argjson pid $$ \
            '.[$key] = $value | .updated_at = $now | .pid = $pid'
    else
        atomic_json_update "$file" \
            --arg key "$key" \
            --arg value "$value" \
            --arg now "$now" \
            --argjson pid $$ \
            '.[$key] = $value | .updated_at = $now | .pid = $pid'
    fi
}

# Get a field from state
state_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    
    local value
    value=$(jq -r --arg key "$key" '.[$key] // empty' "$file" 2>/dev/null)
    
    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Task Tracking
# ═══════════════════════════════════════════════════════════════════════════

# Set task status
task_set_status() {
    local file="$1"
    local task_id="$2"
    local status="$3"
    local message="${4:-}"
    
    local now
    now=$(date -Iseconds)
    
    atomic_json_update "$file" \
        --arg id "$task_id" \
        --arg status "$status" \
        --arg msg "$message" \
        --arg now "$now" \
        '.tasks[$id] = {
            status: $status,
            message: $msg,
            updated_at: $now,
            attempts: ((.tasks[$id].attempts // 0) + (if $status == "failed" then 1 else 0 end))
        } | .updated_at = $now'
}

# Get task status
task_get_status() {
    local file="$1"
    local task_id="$2"
    
    jq -r --arg id "$task_id" '.tasks[$id].status // "pending"' "$file" 2>/dev/null || echo "pending"
}

# Get task attempt count
task_get_attempts() {
    local file="$1"
    local task_id="$2"
    
    jq -r --arg id "$task_id" '.tasks[$id].attempts // 0' "$file" 2>/dev/null || echo "0"
}

# Check if task should be retried
task_should_retry() {
    local file="$1"
    local task_id="$2"
    local max_retries="$3"
    
    local status attempts
    status=$(task_get_status "$file" "$task_id")
    attempts=$(task_get_attempts "$file" "$task_id")
    
    # Don't retry completed or fatal
    if [[ "$status" == "completed" ]] || [[ "$status" == "fatal" ]]; then
        return 1
    fi
    
    # Retry if under limit
    [[ "$attempts" -lt "$max_retries" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# Error Recording
# ═══════════════════════════════════════════════════════════════════════════

# Record an error
record_error() {
    local file="$1"
    local task_id="$2"
    local error_type="$3"
    local message="$4"
    
    local now
    now=$(date -Iseconds)
    
    atomic_json_update "$file" \
        --arg task "$task_id" \
        --arg type "$error_type" \
        --arg msg "$message" \
        --arg now "$now" \
        '.errors += [{task: $task, type: $type, message: $msg, time: $now}] | .updated_at = $now'
}

# Check if there are fatal errors
has_fatal_errors() {
    local file="$1"
    
    local fatal_count
    fatal_count=$(jq '[.tasks | to_entries[] | select(.value.status == "fatal")] | length' "$file" 2>/dev/null || echo "0")
    
    [[ "$fatal_count" -gt 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# Wave Tracking
# ═══════════════════════════════════════════════════════════════════════════

# Mark wave as complete
wave_complete() {
    local file="$1"
    local wave_num="$2"
    
    atomic_json_update "$file" \
        --argjson wave "$wave_num" \
        '.completed_waves += [$wave] | .completed_waves |= unique'
}

# Check if wave was completed
wave_is_complete() {
    local file="$1"
    local wave_num="$2"
    
    local is_in
    is_in=$(jq --argjson wave "$wave_num" '.completed_waves | contains([$wave])' "$file" 2>/dev/null)
    
    [[ "$is_in" == "true" ]]
}

# Set current wave
wave_set_current() {
    local file="$1"
    local wave_num="$2"
    
    state_set "$file" "current_wave" "$wave_num" true
}

# ═══════════════════════════════════════════════════════════════════════════
# Lock File (Simple PID-based)
# ═══════════════════════════════════════════════════════════════════════════

# Try to acquire lock
lock_acquire() {
    local lock_file="$1"
    local force="${2:-false}"
    
    if [[ -f "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        
        # Check if process is still running
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            if [[ "$force" == "true" ]]; then
                echo "Force-killing stale process $lock_pid" >&2
                kill -9 "$lock_pid" 2>/dev/null || true
                sleep 1
            else
                echo "ERROR: Lock held by PID $lock_pid (use --force to override)" >&2
                return 1
            fi
        fi
        rm -f "$lock_file"
    fi
    
    echo $$ > "$lock_file"
    return 0
}

# Release lock
lock_release() {
    local lock_file="$1"
    
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
    
    if [[ "$lock_pid" == "$$" ]]; then
        rm -f "$lock_file"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Summary/Report Generation
# ═══════════════════════════════════════════════════════════════════════════

# Generate summary from state
generate_summary() {
    local file="$1"
    
    local completed failed fatal pending
    completed=$(jq '[.tasks | to_entries[] | select(.value.status == "completed")] | length' "$file" 2>/dev/null || echo "0")
    failed=$(jq '[.tasks | to_entries[] | select(.value.status == "failed")] | length' "$file" 2>/dev/null || echo "0")
    fatal=$(jq '[.tasks | to_entries[] | select(.value.status == "fatal")] | length' "$file" 2>/dev/null || echo "0")
    pending=$(jq '[.tasks | to_entries[] | select(.value.status == "pending" or .value.status == "in_progress")] | length' "$file" 2>/dev/null || echo "0")
    
    local total=$((completed + failed + fatal + pending))
    
    echo "Completed: $completed/$total"
    echo "Failed: $failed"
    echo "Fatal: $fatal"
    echo "Pending: $pending"
    
    if [[ "$fatal" -gt 0 ]]; then
        echo ""
        echo "Fatal errors:"
        jq -r '.errors[] | select(.type == "QUOTA_EXCEEDED" or .type == "AUTH_ERROR") | "  - \(.task): \(.type)"' "$file" 2>/dev/null
    fi
}
