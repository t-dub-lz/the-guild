#!/usr/bin/env bash
#
# Guild Member Utilities
#
# Common functionality for repository-scope Guild Members.
# Source this file at the top of your guild member script.
#
# Usage:
#   source "${SCRIPT_DIR}/../lib/guild-member-utils.sh"
#   guild_init "tool-name"
#
# Provides:
#   - Color definitions (RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, BOLD, NC)
#   - Guild interface flag variables (SILENT, NO_STDOUT, DETAILS_ONLY, etc.)
#   - extract_repo_name() function
#   - guild_parse_base_args() for common argument parsing
#   - guild_cleanup_setup() for temp directory management
#

# ═══════════════════════════════════════════════════════════════════════════════
# COLOR DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════════
# GUILD INTERFACE VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════

# These are the standard guild interface flags that all members should support
GUILD_SILENT=false
GUILD_NO_STDOUT=false
GUILD_DETAILS_ONLY=false
GUILD_PREFIX=""
GUILD_SIGIL=""
GUILD_REPORT_MODE=false
GUILD_REPO_PATH=""
GUILD_STRICTNESS=""

# Tool identification (set by guild_init)
GUILD_TOOL_NAME=""
GUILD_SCRIPT_DIR=""
GUILD_DB=""

# Temp directory (managed by cleanup)
GUILD_TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize guild member utilities
# Usage: guild_init "tool-name" "/path/to/script/dir"
guild_init() {
    local tool_name="$1"
    local script_dir="$2"

    GUILD_TOOL_NAME="$tool_name"
    GUILD_SCRIPT_DIR="$script_dir"
    GUILD_DB="${script_dir}/../lib/guild-db.ts"

    # Set up cleanup trap
    guild_cleanup_setup
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

# Internal cleanup function
_guild_cleanup() {
    if [[ -n "$GUILD_TEMP_DIR" && -d "$GUILD_TEMP_DIR" ]]; then
        rm -rf "$GUILD_TEMP_DIR"
    fi
}

# Set up cleanup trap - call this in guild_init or manually
guild_cleanup_setup() {
    trap _guild_cleanup EXIT
}

# Create temp directory for this invocation
# Sets GUILD_TEMP_DIR - does not echo (use the variable directly)
guild_create_temp_dir() {
    GUILD_TEMP_DIR=$(mktemp -d)
}

# ═══════════════════════════════════════════════════════════════════════════════
# REPOSITORY NAME EXTRACTION
# ═══════════════════════════════════════════════════════════════════════════════

# Extract org/repo name from repository path
# Handles: /path/to/.repos/org/reponame, org/reponame, or generic paths
#
# Usage: repo_name=$(guild_extract_repo_name "/path/to/.repos/org/repo")
guild_extract_repo_name() {
    local path="$1"

    # Try to extract from .repos path structure
    if [[ "$path" =~ \.repos/([^/]+/[^/]+)/?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$path" =~ \.repos/([^/]+/[^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^([^/]+/[^/]+)$ ]]; then
        # Direct org/repo format
        echo "$path"
    else
        # Last resort: take last two path components
        local normalized="${path%/}"
        local repo="${normalized##*/}"
        local parent="${normalized%/*}"
        local org="${parent##*/}"
        echo "$org/$repo"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════════

# Parse standard guild interface arguments
# Sets GUILD_* variables based on arguments
# Returns remaining arguments that weren't consumed
#
# Usage:
#   remaining_args=$(guild_parse_base_args "$@")
#   eval "set -- $remaining_args"
#
guild_parse_base_args() {
    local remaining=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -nn)
                GUILD_SILENT=true
                GUILD_NO_STDOUT=true
                shift
                ;;
            -n)
                GUILD_NO_STDOUT=true
                shift
                ;;
            -d)
                GUILD_DETAILS_ONLY=true
                shift
                ;;
            --prefix=*)
                GUILD_PREFIX="${1#--prefix=}"
                shift
                ;;
            --prefix)
                GUILD_PREFIX="$2"
                shift 2
                ;;
            -g)
                GUILD_SIGIL="$2"
                shift 2
                ;;
            -r)
                GUILD_SIGIL="$2"
                GUILD_REPORT_MODE=true
                shift 2
                ;;
            -s)
                GUILD_STRICTNESS="-s"
                shift
                ;;
            -S)
                GUILD_STRICTNESS="-S"
                shift
                ;;
            -*)
                # Unknown flag - pass through to remaining
                remaining+=("$1")
                shift
                ;;
            *)
                # Positional argument - assume it's the repo path if not set
                if [[ -z "$GUILD_REPO_PATH" ]]; then
                    GUILD_REPO_PATH="$1"
                else
                    remaining+=("$1")
                fi
                shift
                ;;
        esac
    done

    # Return remaining args as quoted string for eval (only if there are any)
    if [[ ${#remaining[@]} -gt 0 ]]; then
        printf '%q ' "${remaining[@]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ERROR HANDLING
# ═══════════════════════════════════════════════════════════════════════════════

# Print error message (respects GUILD_SILENT)
guild_error() {
    local message="$1"
    if [[ "$GUILD_SILENT" != true ]]; then
        printf "${RED}Error: %s${NC}\n" "$message" >&2
    fi
}

# Print warning message (respects GUILD_SILENT)
guild_warn() {
    local message="$1"
    if [[ "$GUILD_SILENT" != true ]]; then
        printf "${YELLOW}Warning: %s${NC}\n" "$message" >&2
    fi
}

# Exit with tool error (code 2)
guild_exit_error() {
    local message="$1"
    guild_error "$message"
    exit 2
}

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKING
# ═══════════════════════════════════════════════════════════════════════════════

# Check if commands are available
# Usage: guild_check_commands "gh" "jq" "snyk"
# Returns: 0 if all present, exits with 2 if any missing
guild_check_commands() {
    local missing=()

    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        guild_exit_error "Missing dependencies: ${missing[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATABASE RECORDING
# ═══════════════════════════════════════════════════════════════════════════════

# Record scan and findings to guild database
# Usage: guild_record_scan "$scan_json" "$findings_json"
# Note: Only records if GUILD_SIGIL is set and GUILD_DB exists
guild_record_scan() {
    local scan_json="$1"
    local findings_json="${2:-[]}"

    if [[ -z "$GUILD_SIGIL" || ! -f "$GUILD_DB" ]]; then
        return 0
    fi

    local insert_data
    insert_data=$(printf '{"scan":%s,"findings":%s}' "$scan_json" "$findings_json")

    npx tsx "$GUILD_DB" insert-with-findings "$GUILD_TOOL_NAME" - <<< "$insert_data" >/dev/null 2>&1 || true
}
