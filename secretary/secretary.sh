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

LINE_THRESHOLD=5000
QUIET=false
SILENT=false
DETAILS_ONLY=false
PREFIX=""
SIGIL=""
REPORT_MODE=false
DATA_FILE=""
TOOL_NAME="secretary"

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
                DATA_FILE="/tmp/guild-${TOOL_NAME}-${SIGIL}.dat"
                shift 2
            else
                shift
            fi
            ;;
        -r)
            if [[ -n "$2" && "$2" != -* ]]; then
                SIGIL="$2"
                DATA_FILE="/tmp/guild-${TOOL_NAME}-${SIGIL}.dat"
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

# Record data for sigil-based reporting
record_data() {
    local file="$1"
    local file_size="$2"
    local over_threshold="$3"

    if [[ -n "$SIGIL" && -n "$DATA_FILE" ]]; then
        local repo=$(extract_repo_from_path "$file")
        # Append: repo|file_count|size|over_threshold_flag
        echo "${repo}|1|${file_size}|${over_threshold}" >> "$DATA_FILE"
    fi
}

# Handle report mode (-r)
if [[ "$REPORT_MODE" == true ]]; then
    if [[ ! -f "$DATA_FILE" ]]; then
        # No data collected - exit silently
        exit 0
    fi

    # Read and aggregate data
    # Data format: repo_path|file_count|total_size|over_threshold_count
    declare -A repo_files
    declare -A repo_sizes
    declare -A repo_over_threshold
    total_repos=0

    while IFS='|' read -r repo files size over; do
        if [[ -z "${repo_files[$repo]}" ]]; then
            ((total_repos++))
            repo_files[$repo]=0
            repo_sizes[$repo]=0
            repo_over_threshold[$repo]=0
        fi
        repo_files[$repo]=$((repo_files[$repo] + files))
        repo_sizes[$repo]=$((repo_sizes[$repo] + size))
        repo_over_threshold[$repo]=$((repo_over_threshold[$repo] + over))
    done < "$DATA_FILE"

    # Calculate aggregates
    total_files=0
    total_size=0
    total_over=0
    for repo in "${!repo_files[@]}"; do
        total_files=$((total_files + repo_files[$repo]))
        total_size=$((total_size + repo_sizes[$repo]))
        total_over=$((total_over + repo_over_threshold[$repo]))
    done

    # Output report
    if [[ $total_repos -gt 0 && $total_files -gt 0 ]]; then
        avg_files=$((total_files / total_repos))
        avg_size=$((total_size / total_files))

        echo "  Average files per repo: ${avg_files}"
        echo "  Average file size: ${avg_size} bytes"
        echo "  Files over ${LINE_THRESHOLD} lines: ${total_over}"
    fi

    # Cleanup
    rm -f "$DATA_FILE"
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
    record_data "$FILE" "$FILE_SIZE" 1

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
    record_data "$FILE" "$FILE_SIZE" 0

    # File is OK
    exit 0
fi
