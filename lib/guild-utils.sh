#!/usr/bin/env bash
#
# Guild Utilities
#
# Common functionality for Guild scripts (members and orchestrator).
# Source this file at the top of your guild script.
#
# Usage:
#   source "${SCRIPT_DIR}/../lib/guild-utils.sh"
#   guild_init "tool-name" "$SCRIPT_DIR"
#
# Provides:
#   - Color definitions and aliases
#   - Symbols (CHECKMARK, XMARK, WARNING_SYMBOL, etc.)
#   - Guild interface flag variables
#   - guild_init(), guild_parse_base_args(), guild_extract_repo_name()
#   - guild_load_env() - environment file loading
#   - guild_strip_jsonc_comments() - JSONC parsing
#   - Spinner animation functions
#   - guild_make_separator() - separator line generation
#   - Table formatting (guild_table_header, guild_table_row, etc.)
#

# ═══════════════════════════════════════════════════════════════════════════════
# COLOR DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ═══════════════════════════════════════════════════════════════════════════════
# COLOR ALIASES (for consistency across scripts)
# ═══════════════════════════════════════════════════════════════════════════════

SUCCESS_COLOR="$GREEN"
FAIL_COLOR="$RED"
YELLOW_COLOR="$YELLOW"
BLUE_COLOR="$BLUE"
MAGENTA_COLOR="$MAGENTA"
CYAN_COLOR="$CYAN"
NEON_GREEN=$'\033[0;92m'
RESET_COLOR="$NC"

# ═══════════════════════════════════════════════════════════════════════════════
# SYMBOLS
# ═══════════════════════════════════════════════════════════════════════════════

CHECKMARK='✓'
XMARK='✗'
DOWN_RIGHT_ARROW="╰─>"
WARNING_SYMBOL='⚠'

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

# Retry database operations with exponential backoff
# Handles SQLITE_BUSY errors that may occur during parallel repo processing
# Usage: guild_db_with_retry command args...
guild_db_with_retry() {
    local max_retries=5
    local retry_delay=1
    local attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        # Try the command, capture both stdout and exit status
        if "$@" 2>&1; then
            return 0
        fi
        ((attempt++))
        # Exponential backoff: 1s, 2s, 4s, 8s, 16s
        sleep "$retry_delay"
        retry_delay=$((retry_delay * 2))
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT FILE LOADING
# ═══════════════════════════════════════════════════════════════════════════════

# Load environment variables from .env file
# Usage: guild_load_env "/path/to/.env"
# Usage: guild_load_env  # uses $GUILD_SCRIPT_DIR/../.env
guild_load_env() {
    local env_file="${1:-${GUILD_SCRIPT_DIR}/../.env}"

    [[ ! -f "$env_file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip if not a valid KEY=value format
        [[ "$line" != *=* ]] && continue

        # Extract key and value
        local key="${line%%=*}"
        local value="${line#*=}"

        # Remove surrounding quotes from value if present
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        # Export the variable
        export "$key=$value"
    done < "$env_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# JSONC PARSING
# ═══════════════════════════════════════════════════════════════════════════════

# Strip JSONC comments from input
# Removes // comments on their own lines and /* */ block comments
# Usage: json=$(guild_strip_jsonc_comments "$(cat config.jsonc)")
guild_strip_jsonc_comments() {
    local input="$1"
    echo "$input" | sed -e '/^[[:space:]]*\/\//d' -e 's|/\*.*\*/||g'
}

# ═══════════════════════════════════════════════════════════════════════════════
# SPINNER ANIMATION
# ═══════════════════════════════════════════════════════════════════════════════

GUILD_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
GUILD_SPINNER_INDEX=0

# Clear spinner line (outputs to stderr to avoid interfering with stdout data)
guild_clear_spinner() {
    printf "\r\033[K" >&2
}

# Advance spinner to next frame
guild_advance_spinner() {
    GUILD_SPINNER_INDEX=$(( (GUILD_SPINNER_INDEX + 1) % ${#GUILD_SPINNER_FRAMES[@]} ))
}

# Get current spinner character
guild_get_spinner() {
    echo "${GUILD_SPINNER_FRAMES[$GUILD_SPINNER_INDEX]}"
}

# Show spinner with message (call in a loop)
# Usage: guild_show_spinner "Loading..."
# Note: Outputs to stderr to avoid interfering with stdout data in command substitutions
guild_show_spinner() {
    local message="$1"
    printf "\r${NEON_GREEN}%s${RESET_COLOR} %s" "${GUILD_SPINNER_FRAMES[$GUILD_SPINNER_INDEX]}" "$message" >&2
    guild_advance_spinner
}

# ═══════════════════════════════════════════════════════════════════════════════
# DISPLAY UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Generate separator line of given length
# Usage: separator=$(guild_make_separator 40 "═")
# Usage: separator=$(guild_make_separator 40)  # defaults to "═"
guild_make_separator() {
    local len="$1"
    local char="${2:-═}"
    local result=""
    for ((i=0; i<len; i++)); do
        result+="$char"
    done
    printf '%s' "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TABLE FORMATTING - Conclave-style output tables
# ═══════════════════════════════════════════════════════════════════════════════

# Standard table width (53 chars inner content, matching catburglar)
GUILD_TABLE_WIDTH=53

# Box-drawing characters
GUILD_BOX_TL='╔'  # Top-left corner
GUILD_BOX_TR='╗'  # Top-right corner
GUILD_BOX_BL='╚'  # Bottom-left corner
GUILD_BOX_BR='╝'  # Bottom-right corner
GUILD_BOX_H='═'   # Horizontal line
GUILD_BOX_V='║'   # Vertical line
GUILD_BOX_ML='╠'  # Middle-left (divider)
GUILD_BOX_MR='╣'  # Middle-right (divider)

# Print table top border with title
# Usage: guild_table_header "My Summary Title"
guild_table_header() {
    local title="$1"
    local width=${2:-$GUILD_TABLE_WIDTH}
    local border=$(guild_make_separator "$width" "$GUILD_BOX_H")
    local title_len=${#title}
    local left_pad=$(( (width - title_len) / 2 ))
    local right_pad=$(( width - title_len - left_pad ))

    printf "${BOLD}${GUILD_BOX_TL}${border}${GUILD_BOX_TR}${NC}\n"
    printf "${BOLD}${GUILD_BOX_V}%*s%s%*s${GUILD_BOX_V}${NC}\n" "$left_pad" "" "$title" "$right_pad" ""
    printf "${BOLD}${GUILD_BOX_ML}${border}${GUILD_BOX_MR}${NC}\n"
}

# Print table section divider
# Usage: guild_table_divider
guild_table_divider() {
    local width=${1:-$GUILD_TABLE_WIDTH}
    local border=$(guild_make_separator "$width" "$GUILD_BOX_H")
    printf "${BOLD}${GUILD_BOX_ML}${border}${GUILD_BOX_MR}${NC}\n"
}

# Print table bottom border
# Usage: guild_table_footer
guild_table_footer() {
    local width=${1:-$GUILD_TABLE_WIDTH}
    local border=$(guild_make_separator "$width" "$GUILD_BOX_H")
    printf "${BOLD}${GUILD_BOX_BL}${border}${GUILD_BOX_BR}${NC}\n"
}

# Print a table row with label and value (right-aligned value, optionally colored)
# Usage: guild_table_row "Label text:" "42" "$BLUE"
# Usage: guild_table_row "Label text:" "42"  # no color
guild_table_row() {
    local label="$1"
    local value="$2"
    local color="${3:-}"
    local width=${4:-$GUILD_TABLE_WIDTH}

    # Format: "║ label                    value ║"
    # Inner content = width chars, with 1 space after ║ and 1 before ║
    local inner=$((width - 2))  # Account for leading/trailing space
    local value_width=8         # Fixed width for value column
    local label_max=$((inner - value_width - 1))  # -1 for space between label and value

    # Truncate label if needed
    local display_label="${label:0:$label_max}"
    local label_len=${#display_label}
    local padding=$((label_max - label_len))

    # Build the line: space + label + padding + space + value (right-aligned in 8 chars) + space
    if [[ -n "$color" ]]; then
        printf "${GUILD_BOX_V} %s%*s ${color}%${value_width}s${NC} ${GUILD_BOX_V}\n" \
            "$display_label" "$padding" "" "$value"
    else
        printf "${GUILD_BOX_V} %s%*s %${value_width}s ${GUILD_BOX_V}\n" \
            "$display_label" "$padding" "" "$value"
    fi
}

# Print a table row with label and status (checkmark/X with color)
# Usage: guild_table_status_row "Files clean:" 10 true   # green checkmark
# Usage: guild_table_status_row "Files with issues:" 5 false  # red X
guild_table_status_row() {
    local label="$1"
    local value="$2"
    local is_good="${3:-true}"
    local width=${4:-$GUILD_TABLE_WIDTH}

    # Format: "║ ✓ label                 value ║"
    local inner=$((width - 2))
    local value_width=8
    local symbol_width=2  # Symbol + space
    local label_max=$((inner - value_width - symbol_width - 1))

    local display_label="${label:0:$label_max}"
    local label_len=${#display_label}
    local padding=$((label_max - label_len))

    if [[ "$is_good" == true ]]; then
        printf "${GUILD_BOX_V} ${GREEN}${CHECKMARK}${NC} %s%*s %${value_width}s ${GUILD_BOX_V}\n" \
            "$display_label" "$padding" "" "$value"
    else
        printf "${GUILD_BOX_V} ${RED}${XMARK}${NC} %s%*s ${RED}%${value_width}s${NC} ${GUILD_BOX_V}\n" \
            "$display_label" "$padding" "" "$value"
    fi
}

# Print a section header row (cyan label, no value)
# Usage: guild_table_section "SCA Findings:"
guild_table_section() {
    local label="$1"
    local width=${2:-$GUILD_TABLE_WIDTH}

    local inner=$((width - 2))
    local label_len=${#label}
    local padding=$((inner - label_len))

    printf "${GUILD_BOX_V} ${CYAN}%s${NC}%*s ${GUILD_BOX_V}\n" "$label" "$padding" ""
}
