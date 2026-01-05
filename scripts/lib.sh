#!/usr/bin/env bash
# Shared utilities for pi-swarm scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source state management
source "$SCRIPT_DIR/state.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Error Detection & Classification
# ═══════════════════════════════════════════════════════════════════════════

ERROR_NONE=0
ERROR_RATE_LIMIT=1      # 429 - retry with backoff
ERROR_AUTH=2            # 401/403 - fatal
ERROR_QUOTA=3           # Quota exceeded - fatal
ERROR_TIMEOUT=4         # Timeout - retry
ERROR_NETWORK=5         # Network error - retry
ERROR_API=6             # API error (5xx) - retry

# Detect error type from output
detect_error_type() {
    local content="$1"
    
    if echo "$content" | grep -qiE "(429|rate.?limit|too many requests|throttl)"; then
        echo $ERROR_RATE_LIMIT
    elif echo "$content" | grep -qiE "(401|403|unauthorized|forbidden|invalid.?api.?key)"; then
        echo $ERROR_AUTH
    elif echo "$content" | grep -qiE "(quota|billing|exceeded|insufficient|payment.?required|402)"; then
        echo $ERROR_QUOTA
    elif echo "$content" | grep -qiE "(timeout|timed?.?out)"; then
        echo $ERROR_TIMEOUT
    elif echo "$content" | grep -qiE "(network|connection|refused|ECONNREFUSED|ETIMEDOUT)"; then
        echo $ERROR_NETWORK
    elif echo "$content" | grep -qiE "(500|502|503|504|internal.?server|bad.?gateway)"; then
        echo $ERROR_API
    else
        echo $ERROR_NONE
    fi
}

error_type_name() {
    case "$1" in
        $ERROR_RATE_LIMIT) echo "RATE_LIMIT" ;;
        $ERROR_AUTH) echo "AUTH_ERROR" ;;
        $ERROR_QUOTA) echo "QUOTA_EXCEEDED" ;;
        $ERROR_TIMEOUT) echo "TIMEOUT" ;;
        $ERROR_NETWORK) echo "NETWORK_ERROR" ;;
        $ERROR_API) echo "API_ERROR" ;;
        *) echo "NONE" ;;
    esac
}

is_retryable_error() {
    local error_type="$1"
    [[ "$error_type" == "$ERROR_RATE_LIMIT" ]] || \
    [[ "$error_type" == "$ERROR_TIMEOUT" ]] || \
    [[ "$error_type" == "$ERROR_NETWORK" ]] || \
    [[ "$error_type" == "$ERROR_API" ]]
}

is_fatal_error() {
    local error_type="$1"
    [[ "$error_type" == "$ERROR_AUTH" ]] || [[ "$error_type" == "$ERROR_QUOTA" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# Backoff
# ═══════════════════════════════════════════════════════════════════════════

calculate_backoff() {
    local attempt="$1"
    local base="${2:-5}"
    local max="${3:-300}"
    
    local delay=$base
    for ((i=1; i<attempt; i++)); do
        delay=$((delay * 2))
        [[ $delay -gt $max ]] && delay=$max && break
    done
    
    # Add jitter (±20%)
    local jitter=$((delay / 5))
    if [[ $jitter -gt 0 ]]; then
        delay=$((delay + RANDOM % (jitter * 2) - jitter))
    fi
    
    echo $delay
}

# ═══════════════════════════════════════════════════════════════════════════
# Graceful Shutdown
# ═══════════════════════════════════════════════════════════════════════════

SHUTDOWN_REQUESTED=false

request_shutdown() {
    SHUTDOWN_REQUESTED=true
    echo ""
    echo "Shutdown requested. Finishing current task..." >&2
}

is_shutdown_requested() {
    [[ "$SHUTDOWN_REQUESTED" == "true" ]]
}

setup_signal_handlers() {
    trap 'request_shutdown' SIGINT SIGTERM
}

# ═══════════════════════════════════════════════════════════════════════════
# Convenience wrappers
# ═══════════════════════════════════════════════════════════════════════════

# For backward compatibility with existing code
acquire_lock() {
    local name="$1"
    local dir="$2"
    local force="${3:-false}"
    lock_acquire "$dir/${name}.lock" "$force"
}

release_lock() {
    local name="$1"
    local dir="$2"
    lock_release "$dir/${name}.lock"
}

# Heartbeat is now just updating the state file's updated_at field
start_heartbeat() {
    # No-op - state updates handle this now
    :
}

stop_heartbeat() {
    :
}

cleanup_children() {
    # Kill all child processes
    pkill -P $$ 2>/dev/null || true
}
