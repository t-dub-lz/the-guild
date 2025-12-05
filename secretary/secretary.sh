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
        -*)
            # Ignore unknown flags (like -s, -S for strictness)
            shift
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

# Check threshold
if [[ $LINE_COUNT -gt $LINE_THRESHOLD ]]; then
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
    # File is OK
    exit 0
fi
