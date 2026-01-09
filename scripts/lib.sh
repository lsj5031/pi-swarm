#!/usr/bin/env bash
# Shared utilities for pi-swarm scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source state management
source "$SCRIPT_DIR/state.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Colors (for consistent output across scripts)
# ═══════════════════════════════════════════════════════════════════════════

COLOR_BLUE='\033[0;34m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_RED='\033[0;31m'
NC='\033[0m'

# Get color by index (for parallel log coloring)
get_color() {
    local idx=$1
    local colors=("$COLOR_BLUE" "$COLOR_GREEN" "$COLOR_YELLOW" "$COLOR_MAGENTA" "$COLOR_CYAN" "$COLOR_RED")
    echo "${colors[$((idx % ${#colors[@]}))]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Dependency Checking
# ═══════════════════════════════════════════════════════════════════════════

# Check for required dependencies
# Usage: require_deps gh jq pi git
require_deps() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing[*]}" >&2
        echo "Please install them before running this script." >&2
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Input Validation
# ═══════════════════════════════════════════════════════════════════════════

# Validate that a value is a non-negative integer
# Usage: validate_int "value" "option_name"
validate_int() {
    local value="$1"
    local name="$2"
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $name must be a non-negative integer, got: '$value'" >&2
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# JSON Output Parsing (for pi agent streaming output)
# ═══════════════════════════════════════════════════════════════════════════

# Parse and display pi agent JSON output
# Usage: some_command | parse_pi_output "$tag" "$log_file" "$json_log_file"
parse_pi_output() {
    local tag="$1"
    local log_file="$2"
    local json_log_file="$3"
    
    while IFS= read -r line; do
        # Use jq to validate JSON instead of regex
        local type
        if type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) && [[ -n "$type" ]]; then
            # Only log valid JSON to jsonl file
            echo "$line" >> "$json_log_file"
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
                        echo -e "$tag 🤖 Agent is working..." | tee -a "$log_file"
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

# ═══════════════════════════════════════════════════════════════════════════
# Plan Validation
# ═══════════════════════════════════════════════════════════════════════════

# Validate that a plan file has the required structure
# Usage: validate_plan "$plan_file" "waves" "issues"
# Returns: 0 if valid, 1 if invalid
# Note: For array fields, validates they exist and are non-empty arrays
validate_plan() {
    local plan_file="$1"
    shift
    local required_fields=("$@")
    
    if [[ ! -f "$plan_file" ]]; then
        echo "Error: Plan file not found: $plan_file" >&2
        return 1
    fi
    
    if ! jq empty "$plan_file" 2>/dev/null; then
        echo "Error: Plan file is not valid JSON: $plan_file" >&2
        return 1
    fi
    
    local missing=()
    for field in "${required_fields[@]}"; do
        local check_result
        # Check if field exists, is an array, and is non-empty; or exists and is non-null for other types
        check_result=$(jq -r "
            if .$field == null then \"missing\"
            elif (.$field | type) == \"array\" then
                if (.$field | length) > 0 then \"ok\" else \"empty_array\" end
            else \"ok\" end
        " "$plan_file" 2>/dev/null)
        
        if [[ "$check_result" == "missing" ]]; then
            missing+=("$field")
        elif [[ "$check_result" == "empty_array" ]]; then
            missing+=("$field (empty array)")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Plan file missing or invalid required fields: ${missing[*]}" >&2
        return 1
    fi
    
    return 0
}

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
