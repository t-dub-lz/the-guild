#!/usr/bin/env bash
# Secretary - file statistics tool
# Flags files with more than 10,000 lines of code
#
# Usage: secretary.sh [OPTIONS] <file>
# Options:
#   -n          No stdout output (errors to stderr only)
#   -nn         No output at all (silent mode)
#   -d          Details only (for embedding in other output)
#   --prefix=X  Prefix each line with X
#
# Exit codes:
#   0 = file is OK (under threshold)
#   1 = file has issues (over threshold)
#   2 = tool error

LINE_THRESHOLD=10000
QUIET=false
SILENT=false
DETAILS_ONLY=false
PREFIX=""
SIGIL=""
REPORT_MODE=false
TOOL_NAME="secretary"

# Guild DB path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUILD_DB="${SCRIPT_DIR}/../lib/guild-db.ts"

# Source guild utilities for colors and symbols
if [[ -f "${SCRIPT_DIR}/../lib/guild-utils.sh" ]]; then
    source "${SCRIPT_DIR}/../lib/guild-utils.sh"
else
    # Fallback color definitions if guild-utils not found
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
    CHECKMARK='✓'
    XMARK='✗'
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            QUIET=true
            shift
            ;;
        -nn)
            SILENT=true
            shift
            ;;
        -d)
            DETAILS_ONLY=true
            shift
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        -g)
            if [[ -n "$2" && "$2" != -* ]]; then
                SIGIL="$2"
                shift 2
            else
                shift
            fi
            ;;
        -r)
            if [[ -n "$2" && "$2" != -* ]]; then
                SIGIL="$2"
                REPORT_MODE=true
                shift 2
            else
                shift
            fi
            ;;
        -s|-S)
            # Strictness flags from conclave - ignore (not implemented)
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *)
            # First non-flag argument is the file
            if [[ -z "$FILE" ]]; then
                FILE="$1"
            fi
            shift
            ;;
    esac
done

# Extract repo name from file path
# Path format: .../repos/org/reponame/path/to/file
extract_repo_from_path() {
    local filepath="$1"
    if [[ "$filepath" =~ \.repos/([^/]+/[^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Record data to guild database
record_data() {
    local file="$1"
    local file_size="$2"
    local line_count="$3"
    local over_threshold="$4"

    if [[ -n "$SIGIL" && -f "$GUILD_DB" ]]; then
        local repo=$(extract_repo_from_path "$file")
        local json_data=$(cat <<EOF
{"sigil":"${SIGIL}","repo":"${repo}","filepath":"${file}","file_size":${file_size},"line_count":${line_count},"over_threshold":${over_threshold}}
EOF
)
        "$GUILD_TSX" "$GUILD_DB" insert-scan secretary "$json_data" >/dev/null || true
    fi
}

# Handle report mode (-r)
if [[ "$REPORT_MODE" == true ]]; then
    if [[ -z "$SIGIL" || ! -f "$GUILD_DB" ]]; then
        # No sigil or no DB - exit silently
        exit 0
    fi

    # Query scans from database
    scans_json=$("$GUILD_TSX" "$GUILD_DB" query-scans secretary "$SIGIL" 2>/dev/null)
    if [[ -z "$scans_json" || "$scans_json" == "[]" ]]; then
        exit 0
    fi

    # Use jq to aggregate data
    if command -v jq &>/dev/null; then
        total_files=$(echo "$scans_json" | jq 'length')
        total_repos=$(echo "$scans_json" | jq '[.[].repo] | unique | length')
        total_size=$(echo "$scans_json" | jq '[.[].file_size] | add // 0')
        total_over=$(echo "$scans_json" | jq '[.[].over_threshold] | add // 0')

        if [[ $total_repos -gt 0 && $total_files -gt 0 ]]; then
            avg_files=$((total_files / total_repos))
            avg_size=$((total_size / total_files))
            # Format size for display (KB if over 1000)
            if [[ $avg_size -gt 1000 ]]; then
                avg_size_display="$((avg_size / 1024)) KB"
            else
                avg_size_display="${avg_size} B"
            fi

            printf "\n"
            guild_table_header "File Statistics Summary"
            guild_table_row "Repositories analyzed:" "$total_repos" "$BLUE"
            guild_table_row "Total files scanned:" "$total_files" "$BLUE"
            guild_table_row "Average files per repo:" "$avg_files" "$BLUE"
            guild_table_row "Average file size:" "$avg_size_display" "$BLUE"
            guild_table_divider
            guild_table_status_row "Over ${LINE_THRESHOLD} lines:" "$total_over" "$([[ $total_over -eq 0 ]] && echo true || echo false)"
            guild_table_footer
        fi
    fi

    exit 0
fi

# Validate file argument
if [[ -z "$FILE" ]]; then
    [[ "$SILENT" != true ]] && echo "Usage: secretary.sh [OPTIONS] <file>" >&2
    exit 2
fi

if [[ ! -f "$FILE" ]]; then
    [[ "$SILENT" != true ]] && echo "File not found: $FILE" >&2
    exit 2
fi

# Count lines
LINE_COUNT=$(wc -l < "$FILE" 2>/dev/null)
LINE_COUNT=${LINE_COUNT// /}  # Trim whitespace

if [[ -z "$LINE_COUNT" ]]; then
    [[ "$SILENT" != true ]] && echo "Could not count lines: $FILE" >&2
    exit 2
fi

# Get file size for statistics
FILE_SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null || echo 0)

# Check threshold
if [[ $LINE_COUNT -gt $LINE_THRESHOLD ]]; then
    # Record data (1 = over threshold)
    record_data "$FILE" "$FILE_SIZE" "$LINE_COUNT" 1

    # File exceeds threshold - report issue
    if [[ "$SILENT" != true && "$QUIET" != true ]]; then
        if [[ "$DETAILS_ONLY" == true ]]; then
            echo "${PREFIX}${LINE_COUNT} lines (exceeds ${LINE_THRESHOLD} line threshold)"
        else
            echo "${PREFIX}Large file: ${LINE_COUNT} lines"
        fi
    fi
    exit 1
else
    # Record data (0 = under threshold)
    record_data "$FILE" "$FILE_SIZE" "$LINE_COUNT" 0

    # File is OK
    exit 0
fi
