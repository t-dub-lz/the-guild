#!/usr/bin/env bash

# The Guild Conclave - Multi-tool repository scanner
# Discovers and runs all Guild Member tools against repositories
#
# Supports parallel repository processing via GNU Parallel.
# When called with --parallel-worker, processes a single repository.

set -euo pipefail

# Script directory (bash equivalent of zsh ${0:A:h})
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source guild utilities
source "${SCRIPT_DIR}/lib/guild-utils.sh"

# Load environment variables from .env file
guild_load_env "${SCRIPT_DIR}/.env"

# ═══════════════════════════════════════════════════════════════════════════════
# PARALLEL WORKER MODE
# When invoked with --parallel-worker, process a single repository and exit.
# This mode is called by GNU Parallel for each repository.
# Environment variables GUILD_WORKER_* carry configuration from parent process.
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "${1:-}" == "--parallel-worker" ]]; then
    # Worker mode: process single repository
    repo="${2:-}"
    [[ -z "$repo" ]] && { echo "Error: No repo specified for worker" >&2; exit 2; }

    # Configuration comes from exported environment variables
    REPOS_DIR="${GUILD_WORKER_REPOS_DIR:-$SCRIPT_DIR/.repos}"
    SIGIL="${GUILD_WORKER_SIGIL:-}"
    STRICTNESS_FLAG="${GUILD_WORKER_STRICTNESS_FLAG:-}"
    MEMBER_TIMEOUT="${GUILD_WORKER_MEMBER_TIMEOUT:-300}"
    FILE_PARALLEL="${GUILD_WORKER_FILE_PARALLEL:-4}"
    DRYRUN="${GUILD_WORKER_DRYRUN:-false}"
    SCAN_ALL_OVERRIDE="${GUILD_WORKER_SCAN_ALL_OVERRIDE:-false}"
    DEBUG="${GUILD_WORKER_DEBUG:-false}"

    # Parse tools list from environment (colon-separated)
    IFS=':' read -ra tools_list <<< "${GUILD_WORKER_TOOLS_LIST:-}"

    # Worker functions are defined later in this script, so we source the rest
    # by jumping to the worker execution section at the end
    WORKER_MODE=true
    WORKER_REPO="$repo"
    # Continue to load function definitions, then execute at WORKER_EXECUTION section
fi

# Default configuration - skip in worker mode (config comes from environment)
if [[ "${WORKER_MODE:-false}" != true ]]; then
    REPO_LIMIT=10000
    ORG_NAME=""
    REPOS_DIR="$SCRIPT_DIR/.repos"
    GUILD_PARALLEL=16        # Total parallel worker pool (auto-split between repos and files)
    STRICTNESS_FLAG=""
    SCAN_ALL_OVERRIDE=false  # -a flag overrides per-tool config
    DRYRUN=false             # -n flag for guild training mode (counts files only)
    EXCLUDED_MEMBERS=()      # -x flag to exclude specific members
    DEBUG=false              # -d flag for verbose diagnostic output
    HEADLESS=false           # --headless flag for TUI integration

    # Generate unique sigil (UUID) for this session
    SIGIL=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | sha256sum | cut -c1-36)
fi

# Debug output function - writes to stderr
debug() {
    if [[ "$DEBUG" == true ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Structured marker output for guild-hall TUI integration
# Emits parseable markers that don't interfere with human output
emit_marker() {
    if [[ "$HEADLESS" == true ]]; then
        echo "$1"
    fi
}

emit_sigil() {
    emit_marker "[SIGIL:$SIGIL]"
}

emit_org() {
    emit_marker "[ORG:$ORG_NAME]"
}

emit_repo_start() {
    emit_marker "[REPO:START:$1]"
}

emit_repo_end() {
    emit_marker "[REPO:END:$1]"
}

emit_progress() {
    emit_marker "[PROGRESS:$1:$2]"
}

emit_finding() {
    # Args: member, repo, filepath, line, type
    emit_marker "[FINDING:$1:$2:$3:$4:$5]"
}

emit_done() {
    emit_marker "[DONE:$1]"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GNU PARALLEL VERIFICATION
# Verify GNU Parallel is available and is the GNU version (not moreutils)
# Uses capability testing: --group is GNU-specific, moreutils doesn't have it
# ═══════════════════════════════════════════════════════════════════════════════
verify_gnu_parallel() {
    # Check: parallel command exists
    # Trigger: command not found
    # Rationale: GNU Parallel is required for grouped repo output
    if ! command -v parallel &>/dev/null; then
        echo "${RED}Error: GNU Parallel is required but not installed.${NC}" >&2
        echo "Install with: sudo apt install parallel" >&2
        echo "  or: (wget -O - pi.dk/3 || curl pi.dk/3/) | bash" >&2
        exit 2
    fi

    # Check: GNU Parallel (not moreutils parallel) via capability test
    # Trigger: --group flag not supported (moreutils version)
    # Rationale: --group keeps repo output together, moreutils lacks this
    if ! echo "test" | parallel --group echo {} &>/dev/null; then
        echo "${RED}Error: GNU Parallel required, but detected moreutils parallel.${NC}" >&2
        echo "Replace moreutils parallel with GNU Parallel:" >&2
        echo "  sudo apt remove moreutils" >&2
        echo "  sudo apt install parallel" >&2
        exit 2
    fi
}

# Verify GNU Parallel before proceeding
verify_gnu_parallel

# Cleanup function - handles interruption of parallel processing
cleanup() {
    echo ""
    echo "${YELLOW_COLOR}Cleaning up...${RESET_COLOR}" >&2

    # Kill all GNU Parallel processes (both repo-level and file-level)
    # GNU Parallel handles SIGTERM gracefully and propagates to children
    # Using killall catches both levels of parallelism consistently
    killall -q -TERM parallel 2>/dev/null || true

    # Kill sync process if it's running
    if [[ -n "${sync_pid:-}" ]] && kill -0 "$sync_pid" 2>/dev/null; then
        kill "$sync_pid" 2>/dev/null || true
        wait "$sync_pid" 2>/dev/null || true
    fi

    # Clean up temp files
    [[ -f "${parallel_joblog:-}" ]] && rm -f "$parallel_joblog"

    exit 1
}

trap cleanup INT TERM

# Help function
show_help() {
    echo "Usage: conclave.sh [OPTIONS] [repo1,repo2,...]"
    echo ""
    echo "The Guild Conclave - Multi-tool repository scanner"
    echo "Discovers and runs all Guild Member tools against repositories."
    echo ""
    echo "Options:"
    echo "  -o <org>        Organization name (default: your GitHub user)"
    echo "  -l <number>     Limit number of repos to fetch (default: 10000)"
    echo "  -p <number>     Total parallel workers (default: 16, max: 1000)"
    echo "                  Auto-splits between repos and files within each repo"
    echo "  -x <members>    Exclude members by folder name (comma-separated)"
    echo "  -a              Scan all text files (overrides per-tool config)"
    echo "  -n              Guild training - count files without running analysis"
    echo "  -s              Strict mode (2x member timeout)"
    echo "  -S              Super strict mode (3x member timeout)"
    echo "  -d              Enable debug output (to stderr)"
    echo "  --headless      Machine-readable output for TUI integration"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  MEMBER_TIMEOUT  Base member tool timeout in seconds (default: 300)"
    echo "                  Scaled by strictness: -s = 2x, -S = 3x"
    echo ""
    echo "Arguments:"
    echo "  [repos]         Optional comma-separated list of repos (e.g., org/repo1,org/repo2)"
    echo "                  If not provided, fetches all repos from the specified organization"
    echo ""
    echo "Repository Cache:"
    echo "  Repositories are cached in .repos/ for faster subsequent scans."
    echo "  First run clones repos; subsequent runs pull latest changes."
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TOOL DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════════

# Discover Guild Member tools
# Each tool lives in its own folder, with the main executable having the same name as the folder
discover_tools() {
    local tools=()
    for dir in "$SCRIPT_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local dirname="${dir%/}"
        dirname="${dirname##*/}"

        # Skip hidden dirs, .repos, node_modules, lib
        [[ "$dirname" == .* ]] && continue
        [[ "$dirname" == "node_modules" ]] && continue
        [[ "$dirname" == ".repos" ]] && continue
        [[ "$dirname" == "lib" ]] && continue

        # Skip excluded members
        is_member_excluded "$dirname" && continue

        # Look for executable with same name as folder (any extension)
        local tool_exe=""
        for ext in "" ".sh" ".zsh" ".ts" ".py" ".js"; do
            local candidate="$dir${dirname}${ext}"
            if [[ -f "$candidate" ]]; then
                tool_exe="$candidate"
                break
            fi
        done

        # Check if config.jsonc exists
        local config_file="$dir/config.jsonc"
        if [[ -n "$tool_exe" && -f "$config_file" ]]; then
            tools+=("$dirname")
        fi
    done
    printf '%s\n' "${tools[@]}"
}

# Get tool executable path
get_tool_executable() {
    local tool_name="$1"
    local tool_dir="$SCRIPT_DIR/$tool_name"

    for ext in "" ".sh" ".zsh" ".ts" ".py" ".js"; do
        local candidate="$tool_dir/${tool_name}${ext}"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# TOOL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

# Read tool config value using jq or python fallback (supports JSONC)
get_tool_config() {
    local tool_name="$1"
    local key="$2"
    local config_file="$SCRIPT_DIR/$tool_name/config.jsonc"
    local json_content

    # Read and strip JSONC comments
    json_content=$(guild_strip_jsonc_comments "$(cat "$config_file")")

    if command -v jq &>/dev/null; then
        echo "$json_content" | jq -r ".$key // empty" 2>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$key', ''))" <<< "$json_content" 2>/dev/null
    else
        echo ""
    fi
}

# Get file patterns for a tool (supports JSONC)
get_tool_patterns() {
    local tool_name="$1"
    local config_file="$SCRIPT_DIR/$tool_name/config.jsonc"
    local json_content

    # Read and strip JSONC comments
    json_content=$(guild_strip_jsonc_comments "$(cat "$config_file")")

    if command -v jq &>/dev/null; then
        echo "$json_content" | jq -r '.patterns[]? // empty' 2>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 -c "import json,sys; d=json.loads(sys.stdin.read()); [print(p) for p in d.get('patterns', [])]" <<< "$json_content" 2>/dev/null
    else
        echo "*"
    fi
}

# Check if tool wants to scan all text files
tool_scans_all_text() {
    local tool_name="$1"
    local val
    val=$(get_tool_config "$tool_name" "scanAllText")
    [[ "$val" == "true" ]]
}

# Check if tool ignores the -a (scan all) override
tool_ignores_all() {
    local tool_name="$1"
    local val
    val=$(get_tool_config "$tool_name" "ignoreAll")
    [[ "$val" == "true" ]]
}

# Check if tool operates at repository scope (once per repo, not per file)
tool_has_repository_scope() {
    local tool_name="$1"
    local val
    val=$(get_tool_config "$tool_name" "repositoryScope")
    [[ "$val" == "true" ]]
}

# Check if a member is in the excluded list
is_member_excluded() {
    local member_name="$1"
    for excluded in "${EXCLUDED_MEMBERS[@]}"; do
        [[ "$excluded" == "$member_name" ]] && return 0
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# REPOSITORY SYNC
# ═══════════════════════════════════════════════════════════════════════════════

# Sync a repository (clone or pull)
# Returns: CLONED, UPDATED, ORPHAN, or SKIP
sync_repo() {
    local repo="$1"
    local org="${repo%/*}"
    local name="${repo#*/}"
    local local_path="$REPOS_DIR/$org/$name"
    local is_orphan=false

    # Debug output goes to stderr to not interfere with return value
    [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: checking remote for $repo" >&2

    # Check if remote exists
    if ! gh repo view "$repo" &>/dev/null 2>&1; then
        is_orphan=true
        [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: remote not found, marking as orphan" >&2
    else
        [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: remote exists" >&2
    fi

    [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: local_path=$local_path" >&2

    if [[ -d "$local_path/.git" ]]; then
        # Repo exists locally
        [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: local repo exists at $local_path" >&2
        if [[ "$is_orphan" == true ]]; then
            echo "ORPHAN"
        else
            # Update existing repo
            [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: updating existing repo" >&2
            cd "$local_path" || return 1
            local default_branch
            default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
            [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: fetching origin, branch=$default_branch" >&2
            git fetch origin --quiet 2>/dev/null
            git reset --hard "origin/$default_branch" --quiet 2>/dev/null
            cd - >/dev/null || return 1
            echo "UPDATED"
        fi
    elif [[ "$is_orphan" == false ]]; then
        # Clone new repo
        [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: cloning new repo" >&2
        mkdir -p "$REPOS_DIR/$org"
        if gh repo clone "$repo" "$local_path" -- --quiet 2>/dev/null; then
            echo "CLONED"
        else
            [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: clone failed" >&2
            echo "FAILED"
        fi
    else
        [[ "$DEBUG" == true ]] && echo "[DEBUG] sync_repo: skipping (orphan with no local)" >&2
        echo "SKIP"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# FILE DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════════

# Find files matching tool's patterns in a directory
find_files_for_tool() {
    local tool_name="$1"
    local repo_path="$2"
    local files=()

    if { [[ "$SCAN_ALL_OVERRIDE" == true ]] && ! tool_ignores_all "$tool_name"; } || tool_scans_all_text "$tool_name"; then
        # Scan all text files (excluding .git)
        while IFS= read -r -d '' file; do
            if file --mime "$file" 2>/dev/null | grep -q "text/"; then
                files+=("$file")
            fi
        done < <(find "$repo_path" -type f -not -path "*/.git/*" -print0 2>/dev/null)
    else
        # Use tool's patterns (excluding .git)
        local patterns=()
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && patterns+=("$pattern")
        done < <(get_tool_patterns "$tool_name")

        if [[ ${#patterns[@]} -eq 0 ]]; then
            patterns=("*")
        fi

        # Build find command with patterns
        local find_args=()
        local first=true
        for pattern in "${patterns[@]}"; do
            if [[ "$first" == true ]]; then
                find_args+=(-name "$pattern")
                first=false
            else
                find_args+=(-o -name "$pattern")
            fi
        done

        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$repo_path" -type f -not -path "*/.git/*" \( "${find_args[@]}" \) -print0 2>/dev/null)
    fi

    printf '%s\0' "${files[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATABASE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Initialize database and register member schemas
init_database() {
    local lib_dir="$SCRIPT_DIR/lib"
    local guild_db="$lib_dir/guild-db.ts"

    if [[ ! -f "$guild_db" ]]; then
        echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Guild database not found, skipping DB init"
        return 1
    fi

    # Initialize database (idempotent)
    npx tsx "$guild_db" init >/dev/null 2>&1 || {
        echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Failed to initialize guild database"
        return 1
    }

    # Register schemas for all discovered tools
    for tool in "${tools_list[@]}"; do
        npx tsx "$guild_db" register "$SCRIPT_DIR/$tool" >/dev/null 2>&1 || true
    done

    return 0
}

# Start conclave session in database
start_conclave_session() {
    local lib_dir="$SCRIPT_DIR/lib"
    local guild_db="$lib_dir/guild-db.ts"

    [[ ! -f "$guild_db" ]] && return 1

    # Build members JSON array
    local members_json
    members_json=$(printf '%s\n' "${tools_list[@]}" | jq -R . | jq -s . 2>/dev/null)

    # Build excluded members JSON array (if any)
    local excluded_json="null"
    if [[ ${#EXCLUDED_MEMBERS[@]} -gt 0 ]]; then
        excluded_json=$(printf '%s\n' "${EXCLUDED_MEMBERS[@]}" | jq -R . | jq -s . 2>/dev/null)
    fi

    # Build config JSON
    local config_json
    config_json=$(jq -n \
        --argjson members "$members_json" \
        --argjson excluded "$excluded_json" \
        --arg org "${ORG_NAME:-}" \
        --argjson limit "${REPO_LIMIT:-null}" \
        --arg strictness "${STRICTNESS_FLAG:-}" \
        --argjson scan_all "${SCAN_ALL_OVERRIDE:-false}" \
        --argjson dryrun "${DRYRUN:-false}" \
        '{
            members: $members,
            excluded_members: $excluded,
            org_name: (if $org == "" then null else $org end),
            repo_limit: $limit,
            strictness_flag: (if $strictness == "" then null else $strictness end),
            scan_all_override: $scan_all,
            dryrun: $dryrun
        }' 2>/dev/null)

    npx tsx "$guild_db" start-conclave "$SIGIL" "$config_json" >/dev/null 2>&1
}

# End conclave session in database
end_conclave_session() {
    local lib_dir="$SCRIPT_DIR/lib"
    local guild_db="$lib_dir/guild-db.ts"

    [[ ! -f "$guild_db" ]] && return 1

    local stats_json
    stats_json=$(jq -n \
        --argjson repo_count "$total_repos" \
        --argjson repos_with_issues "$repos_with_issues" \
        --argjson total_files "$total_files_scanned" \
        '{
            repo_count: $repo_count,
            repos_with_issues: $repos_with_issues,
            total_files_scanned: $total_files
        }' 2>/dev/null)

    npx tsx "$guild_db" end-conclave "$SIGIL" "$stats_json" >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING (Skip in worker mode)
# ═══════════════════════════════════════════════════════════════════════════════
# Worker mode exits early after process_single_repo is defined (see below)

# Skip argument parsing in worker mode - config comes from environment
if [[ "${WORKER_MODE:-false}" != true ]]; then

REPO_LIST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -o)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -o requires an organization name"
                exit 1
            fi
            ORG_NAME="$2"
            shift 2
            ;;
        -l)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -l requires a number"
                exit 1
            fi
            REPO_LIMIT="$2"
            shift 2
            ;;
        -p|--parallel)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -p requires a number" >&2
                exit 2
            fi
            # Validate: must be integer between 1 and 1000
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -p requires an integer" >&2
                exit 2
            fi
            if [[ "$2" -lt 1 ]] || [[ "$2" -gt 1000 ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -p must be between 1 and 1000" >&2
                exit 2
            fi
            GUILD_PARALLEL="$2"
            shift 2
            ;;
        -x)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -x requires comma-separated member folder names" >&2
                exit 1
            fi
            # Bash uses -a instead of -A for array read
            IFS=',' read -ra EXCLUDED_MEMBERS <<< "$2"
            # Validate each excluded member exists
            for member in "${EXCLUDED_MEMBERS[@]}"; do
                member_dir="$SCRIPT_DIR/$member"
                has_config=false
                has_exe=false
                [[ -f "$member_dir/config.jsonc" ]] && has_config=true
                for ext in "" ".sh" ".zsh" ".ts" ".py" ".js"; do
                    [[ -f "$member_dir/${member}${ext}" ]] && has_exe=true && break
                done
                if [[ "$has_config" != true || "$has_exe" != true ]]; then
                    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Unknown member: ${member}" >&2
                    echo "  Available members:" >&2
                    for dir in "$SCRIPT_DIR"/*/; do
                        [[ ! -d "$dir" ]] && continue
                        dirname="${dir%/}"
                        dirname="${dirname##*/}"
                        [[ "$dirname" == .* || "$dirname" == "node_modules" || "$dirname" == ".repos" || "$dirname" == "lib" ]] && continue
                        [[ -f "$dir/config.jsonc" ]] || continue
                        for ext in "" ".sh" ".zsh" ".ts" ".py" ".js"; do
                            if [[ -f "$dir${dirname}${ext}" ]]; then
                                echo "    - ${dirname}" >&2
                                break
                            fi
                        done
                    done
                    exit 1
                fi
            done
            shift 2
            ;;
        -a)
            SCAN_ALL_OVERRIDE=true
            shift
            ;;
        -n)
            DRYRUN=true
            shift
            ;;
        -s)
            STRICTNESS_FLAG="-s"
            shift
            ;;
        -S)
            STRICTNESS_FLAG="-S"
            shift
            ;;
        -d)
            DEBUG=true
            shift
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        -*)
            echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            REPO_LIST="$1"
            shift
            ;;
    esac
done

fi  # End of argument parsing skip for worker mode

# Everything below here runs in both main mode and worker mode
# (Functions must be available to worker mode)

# Ensure .repos directory exists (main mode only does initialization)
if [[ "${WORKER_MODE:-false}" != true ]]; then
mkdir -p "$REPOS_DIR"

# Emit sigil marker for headless mode (TUI integration)
emit_sigil

# Display banner
echo ""
echo "${CYAN_COLOR} _____ _            ____       _ _     _ ${RESET_COLOR}"
echo "${CYAN_COLOR}|_   _| |__   ___  / ___|_   _(_) | __| |${RESET_COLOR}"
echo "${CYAN_COLOR}  | | | '_ \\ / _ \\| |  _| | | | | |/ _\` |${RESET_COLOR}"
echo "${CYAN_COLOR}  | | | | | |  __/| |_| | |_| | | | (_| |${RESET_COLOR}"
echo "${CYAN_COLOR}  |_| |_| |_|\\___| \\____|\\__,_|_|_|\\__,_|${RESET_COLOR}"
echo ""
echo "${MAGENTA_COLOR}    The Guild of Aberrant Computation${RESET_COLOR}"
echo ""

# Discover tools
echo "${BLUE_COLOR}Assembling Guild Members...${RESET_COLOR}"
tools_list=()
while IFS= read -r tool; do
    [[ -n "$tool" ]] && tools_list+=("$tool")
done < <(discover_tools)

if [[ ${#tools_list[@]} -eq 0 ]]; then
    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} No Guild Member Present"
    echo "Each Guild Member (tool) needs a folder with config.jsonc and an executable with the same name as the folder"
    exit 1
fi

echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Guild Member(s) Assembled: ${BLUE_COLOR}${#tools_list[@]}${RESET_COLOR}"
for tool in "${tools_list[@]}"; do
    tool_display_name=$(get_tool_config "$tool" "name")
    [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
    echo "  ${CYAN_COLOR}${tool_display_name}${RESET_COLOR}"
done
if [[ ${#EXCLUDED_MEMBERS[@]} -gt 0 ]]; then
    echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Excluded from conclave: ${BLUE_COLOR}${#EXCLUDED_MEMBERS[@]}${RESET_COLOR}"
    for excluded in "${EXCLUDED_MEMBERS[@]}"; do
        excluded_display_name=$(get_tool_config "$excluded" "name")
        [[ -z "$excluded_display_name" ]] && excluded_display_name="$excluded"
        echo "  ${MAGENTA_COLOR}${excluded_display_name}${RESET_COLOR}"
    done
fi
echo ""

# Initialize database
if init_database; then
    echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Guild Database initialized"
    start_conclave_session
fi

# Get list of repositories
if [[ -n "$REPO_LIST" ]]; then
    # Bash uses -a instead of -A for array read
    IFS=',' read -ra repo_array <<< "$REPO_LIST"
    repos=$(printf "%s\n" "${repo_array[@]}")
    echo "${BLUE_COLOR}Processing specified repositories...${RESET_COLOR}"
else
    # If no org specified, use the authenticated user's repos
    if [[ -z "$ORG_NAME" ]]; then
        ORG_NAME=$(gh api user -q '.login' 2>/dev/null)
        if [[ -z "$ORG_NAME" ]]; then
            echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Could not determine GitHub user. Use -o to specify an org."
            exit 1
        fi
        echo "${BLUE_COLOR}Fetching your repositories (${MAGENTA_COLOR}${ORG_NAME}${RESET_COLOR}) (limit: ${REPO_LIMIT})...${RESET_COLOR}"
    else
        echo "${BLUE_COLOR}Fetching repositories from ${MAGENTA_COLOR}${ORG_NAME}${RESET_COLOR} (limit: ${REPO_LIMIT})...${RESET_COLOR}"
    fi
    repos=$(gh repo list "$ORG_NAME" --limit "$REPO_LIMIT" --archived=false --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null)
fi

if [[ -z "$repos" ]]; then
    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} No repositories found or gh command failed"
    exit 1
fi

debug "Repos to process: $(echo "$repos" | wc -l) repositories"
debug "First repo: $(echo "$repos" | head -1)"

# Emit org marker for headless mode (TUI integration)
emit_org

# ═══════════════════════════════════════════════════════════════════════════════
# PARALLELISM CONFIGURATION
# Auto-split the total parallel pool between repo and file parallelism
# Heuristic: sqrt(PARALLEL) repos, remaining for files (capped by actual repo count)
# ═══════════════════════════════════════════════════════════════════════════════
repo_count=$(echo "$repos" | wc -l)

# Calculate ideal repo parallelism using sqrt heuristic
# sqrt(16) = 4 repos, sqrt(9) = 3 repos, sqrt(4) = 2 repos, sqrt(1) = 1 repo
REPO_PARALLEL=$(echo "scale=0; sqrt($GUILD_PARALLEL)" | bc)
[[ $REPO_PARALLEL -lt 1 ]] && REPO_PARALLEL=1
# Don't use more repo workers than we have repos
[[ $REPO_PARALLEL -gt $repo_count ]] && REPO_PARALLEL=$repo_count

# File parallelism gets the remaining budget (at least 1)
FILE_PARALLEL=$((GUILD_PARALLEL / REPO_PARALLEL))
[[ $FILE_PARALLEL -lt 1 ]] && FILE_PARALLEL=1

# Export for use in subprocesses (GNU Parallel workers)
# Note: GUILD_PARALLEL not exported - "PARALLEL" is a reserved GNU Parallel variable
export REPO_PARALLEL FILE_PARALLEL

debug "Parallelism: $REPO_PARALLEL repos × $FILE_PARALLEL files = $((REPO_PARALLEL * FILE_PARALLEL)) max workers"
echo "${CYAN_COLOR}Parallelism:${RESET_COLOR} ${REPO_PARALLEL} repos × ${FILE_PARALLEL} files/repo (total pool: ${GUILD_PARALLEL})"

# Track overall stats
total_repos=0
repos_with_issues=0
total_files_scanned=0
declare -A repo_issues=()    # repo -> "count:file1|file2|..." (currently unused)
# Initialize empty to avoid "unbound variable" with set -u
# Bash associative arrays need explicit =() for set -u safety
declare -A orphan_repos=()   # track orphaned repos
declare -A tool_stats=()     # tool -> "issues_count"
declare -A tool_file_counts=() # tool -> "files_to_check" (for guild training)

# Initialize tool stats
for tool in "${tools_list[@]}"; do
    tool_stats["$tool"]=0
    tool_file_counts["$tool"]=0
done

# Process each repository
# Member tool timeout based on strictness level
# Base timeout is 5 minutes (300s), scaled by strictness:
# -s (strict) = 2x base timeout
# -S (super strict) = 3x base timeout
BASE_TIMEOUT=${MEMBER_TIMEOUT:-300}  # Default 5 minutes, or user-provided value
if [[ "$STRICTNESS_FLAG" == "-S" ]]; then
    MEMBER_TIMEOUT=$((BASE_TIMEOUT * 3))   # 3x for super strict
elif [[ "$STRICTNESS_FLAG" == "-s" ]]; then
    MEMBER_TIMEOUT=$((BASE_TIMEOUT * 2))   # 2x for strict
else
    MEMBER_TIMEOUT=$BASE_TIMEOUT           # 1x for normal
fi
debug "Member timeout: ${MEMBER_TIMEOUT}s (base: ${BASE_TIMEOUT}s, strictness: ${STRICTNESS_FLAG:-none})"

fi  # End of main mode initialization (worker mode skips to here)

# ═══════════════════════════════════════════════════════════════════════════════
# SINGLE REPOSITORY PROCESSING FUNCTION
# Processes one repository: sync, run all tools, report results
# Returns 0 if clean, 1 if issues found, 2 on error
# ═══════════════════════════════════════════════════════════════════════════════
process_single_repo() {
    local repo="$1"
    [[ -z "$repo" ]] && return 2

    local repo_had_issues=false
    local files_scanned_in_repo=0

    echo ""
    local header_text="Repository: ${repo}"
    local header_len=${#header_text}
    local separator_line
    separator_line=$(guild_make_separator "$header_len" "═")
    echo "${BLUE_COLOR}${separator_line}${RESET_COLOR}"
    echo "${BLUE_COLOR}Repository: ${MAGENTA_COLOR}${repo}${RESET_COLOR}"
    echo "${BLUE_COLOR}${separator_line}${RESET_COLOR}"

    # Sync repository (clone or pull)
    local sync_result_file
    sync_result_file=$(mktemp)

    # Run sync in background, capture result to temp file
    (sync_repo "$repo" > "$sync_result_file") &
    local sync_pid=$!

    # Show spinner while syncing
    while kill -0 "$sync_pid" 2>/dev/null; do
        guild_show_spinner "Syncing repository..."
        sleep 0.1
    done

    wait "$sync_pid" || true
    guild_clear_spinner
    local sync_result
    sync_result=$(cat "$sync_result_file")
    rm -f "$sync_result_file"

    # Handle sync result
    local org="${repo%/*}"
    local name="${repo#*/}"
    local repo_path="$REPOS_DIR/$org/$name"

    case "$sync_result" in
        CLONED)
            echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Cloned repository"
            ;;
        UPDATED)
            echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Updated repository"
            ;;
        ORPHAN)
            echo ""
            echo "${YELLOW_COLOR}╔════════════════════════════════════════╗${RESET_COLOR}"
            echo "${YELLOW_COLOR}║ ${WARNING_SYMBOL} ORPHANED REPO - No longer on remote  ║${RESET_COLOR}"
            echo "${YELLOW_COLOR}╚════════════════════════════════════════╝${RESET_COLOR}"
            # Note: orphan tracking is done by caller via output parsing
            ;;
        SKIP)
            echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Skipping - no remote and no local copy"
            return 0
            ;;
        FAILED)
            echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Failed to clone ${repo}"
            return 2
            ;;
    esac

    if [[ ! -d "$repo_path" ]]; then
        echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Repository path not found: $repo_path"
        return 2
    fi

    # Run each tool on the repository
    for tool in "${tools_list[@]}"; do
        local tool_exe
        tool_exe=$(get_tool_executable "$tool")
        local tool_display_name
        tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"

        echo ""
        echo "${CYAN_COLOR}Consulting ${tool_display_name}${RESET_COLOR}"

        # Handle repository-scope tools (run once per repo, not per file)
        if tool_has_repository_scope "$tool"; then
            # In guild training mode, just report that this tool will run
            if [[ "$DRYRUN" == true ]]; then
                echo "${CYAN_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Repository-scope tool (1 invocation)"
                continue
            fi

            local temp_results
            temp_results=$(mktemp)
            local exit_code=0

            # Run tool in background with spinner, with timeout for robustness
            (timeout "$MEMBER_TIMEOUT" "$tool_exe" $STRICTNESS_FLAG -g "$SIGIL" -nn "$repo_path" > /dev/null 2>&1; echo $? > "$temp_results") &
            local tool_pid=$!

            while kill -0 "$tool_pid" 2>/dev/null; do
                guild_show_spinner "Analyzing repository..."
                sleep 0.1
            done

            wait "$tool_pid" || true
            guild_clear_spinner

            exit_code=$(cat "$temp_results" 2>/dev/null || echo "2")
            rm -f "$temp_results"

            # Handle timeout case (exit code 124 from timeout command)
            if [[ "$exit_code" -eq 124 ]]; then
                echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Tool timed out after ${MEMBER_TIMEOUT}s - skipping"
                continue
            fi

            if [[ "$exit_code" -eq 0 ]]; then
                echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Clean - repository checked"
            elif [[ "$exit_code" -eq 1 ]]; then
                repo_had_issues=true
                # Get detailed output (no -g sigil - data already recorded in first call)
                local issues
                issues=$("$tool_exe" $STRICTNESS_FLAG -d --prefix="    " "$repo_path" 2>&1) || true
                echo "${FAIL_COLOR}${XMARK}${RESET_COLOR} Issues found"
                if [[ -n "$issues" ]]; then
                    echo "$issues"
                fi
            else
                echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Tool error (exit code: $exit_code)"
            fi

            continue
        fi

        # Find files for this tool (with spinner for slow operations)
        local files=()
        local files_temp
        files_temp=$(mktemp)

        (find_files_for_tool "$tool" "$repo_path" > "$files_temp") &
        local find_pid=$!

        while kill -0 "$find_pid" 2>/dev/null; do
            guild_show_spinner "Finding files..."
            sleep 0.1
        done
        wait "$find_pid" || true
        guild_clear_spinner

        while IFS= read -r -d '' file; do
            [[ -n "$file" ]] && files+=("$file")
        done < "$files_temp"
        rm -f "$files_temp"

        local total_files=${#files[@]}
        ((files_scanned_in_repo += total_files)) || true

        if [[ $total_files -eq 0 ]]; then
            echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} No matching files found"
            continue
        fi

        # In guild training mode, just report the count and skip actual analysis
        if [[ "$DRYRUN" == true ]]; then
            echo "${CYAN_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Files to check: ${BLUE_COLOR}${total_files}${RESET_COLOR}"
            continue
        fi

        # Check files with tool in parallel using GNU Parallel
        local problem_files=()
        declare -A file_issues
        local temp_results
        temp_results=$(mktemp)

        # Export tool info for parallel workers (cleaner than nested quoting)
        export GUILD_FILE_TOOL_EXE="$tool_exe"
        export GUILD_FILE_TOOL_STRICTNESS="$STRICTNESS_FLAG"
        export GUILD_FILE_TOOL_SIGIL="$SIGIL"

        # Run parallel checks with overall timeout for robustness
        # Using GNU Parallel instead of xargs -P for consistency
        printf "%s\0" "${files[@]}" | timeout "$MEMBER_TIMEOUT" parallel \
            -0 \
            -j "$FILE_PARALLEL" \
            --will-cite \
            'exit_code=0
             "$GUILD_FILE_TOOL_EXE" $GUILD_FILE_TOOL_STRICTNESS -g "$GUILD_FILE_TOOL_SIGIL" -nn {} 2>/dev/null || exit_code=$?
             if [[ $exit_code -eq 1 ]]; then
                 issues=$("$GUILD_FILE_TOOL_EXE" $GUILD_FILE_TOOL_STRICTNESS -d --prefix="    " {} 2>&1)
                 printf "PROBLEM:%s|||%s\0" {} "$issues"
             fi' > "$temp_results" 2>/dev/null &

        local file_parallel_pid=$!

        while kill -0 "$file_parallel_pid" 2>/dev/null; do
            guild_show_spinner "Scanning ${BLUE_COLOR}${total_files}${RESET_COLOR} files..."
            sleep 0.1
        done

        wait "$file_parallel_pid" || true
        guild_clear_spinner

        # Clean up exported variables
        unset GUILD_FILE_TOOL_EXE GUILD_FILE_TOOL_STRICTNESS GUILD_FILE_TOOL_SIGIL

        # Parse results
        while IFS= read -r -d '' record; do
            if [[ "$record" == PROBLEM:* ]]; then
                local rest="${record#PROBLEM:}"
                local file="${rest%%|||*}"
                local issues="${rest#*|||}"
                problem_files+=("$file")
                file_issues["$file"]="$issues"
            fi
        done < "$temp_results"

        rm -f "$temp_results"

        local problem_count=${#problem_files[@]}

        if [[ $problem_count -eq 0 ]]; then
            echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Clean - ${BLUE_COLOR}${total_files}${RESET_COLOR} files checked"
        else
            repo_had_issues=true
            echo "${FAIL_COLOR}${XMARK}${RESET_COLOR} Issues found - ${BLUE_COLOR}${problem_count}${RESET_COLOR} of ${BLUE_COLOR}${total_files}${RESET_COLOR} files"

            for pfile in "${problem_files[@]}"; do
                local display_file="${pfile#$repo_path/}"
                echo "  ${MAGENTA_COLOR}${display_file}${RESET_COLOR}"
                if [[ -n "${file_issues["$pfile"]:-}" ]]; then
                    echo "${file_issues["$pfile"]}"
                fi
            done
        fi

        unset file_issues
    done

    # Visual separator between repositories for readability
    echo ""
    echo "================================================================================"

    # Return status: 0 = clean, 1 = issues found
    if [[ "$repo_had_issues" == true ]]; then
        return 1
    else
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# WORKER MODE EXECUTION
# If invoked as a parallel worker, execute the repo processing and exit
# Now that process_single_repo is defined, we can call it
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "${WORKER_MODE:-false}" == true ]]; then
    process_single_repo "$WORKER_REPO"
    exit $?
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN REPOSITORY PROCESSING
# Process all repositories using GNU Parallel for parallelism
# ═══════════════════════════════════════════════════════════════════════════════
debug "Starting repository processing with GNU Parallel (${REPO_PARALLEL} repos in parallel)"

# Export environment variables for worker processes
export GUILD_WORKER_REPOS_DIR="$REPOS_DIR"
export GUILD_WORKER_SIGIL="$SIGIL"
export GUILD_WORKER_STRICTNESS_FLAG="$STRICTNESS_FLAG"
export GUILD_WORKER_MEMBER_TIMEOUT="$MEMBER_TIMEOUT"
export GUILD_WORKER_FILE_PARALLEL="$FILE_PARALLEL"
export GUILD_WORKER_DRYRUN="$DRYRUN"
export GUILD_WORKER_SCAN_ALL_OVERRIDE="$SCAN_ALL_OVERRIDE"
export GUILD_WORKER_DEBUG="$DEBUG"
export GUILD_WORKER_TOOLS_LIST="$(IFS=':'; echo "${tools_list[*]}")"

# Create joblog for tracking completion status
parallel_joblog=$(mktemp)

# Run GNU Parallel with grouped output per repository
# --group: buffer output so each repo's output appears together (no interleaving)
# --jobs: control repo-level parallelism
# --joblog: track exit codes for counting repos with issues
# Note: Not using --bar/--progress/--eta as they conflict with --group output
parallel_opts=(--jobs "$REPO_PARALLEL" --group --joblog "$parallel_joblog")

# Show processing message before starting parallel jobs
echo ""
echo "${CYAN_COLOR}Processing ${REPO_PARALLEL} repositories in parallel...${RESET_COLOR}"

# Note: || true prevents set -e from exiting on non-zero (repos with issues return 1)
# We use joblog to track which repos had issues, not the parallel exit code
echo "$repos" | parallel "${parallel_opts[@]}" "$0 --parallel-worker {}" || true

# Count total repos and repos with issues from joblog
# Joblog format: Seq Host Starttime JobRuntime Send Receive Exitval Signal Command
total_repos=$(awk 'NR>1 {count++} END {print count+0}' "$parallel_joblog")
repos_with_issues=$(awk 'NR>1 && $7==1 {count++} END {print count+0}' "$parallel_joblog")
rm -f "$parallel_joblog"

# Query summary stats from database (files scanned and issues per member)
# This is more reliable than tracking in-process since workers run in parallel
stats_json=$(npx tsx "$SCRIPT_DIR/lib/guild-db.ts" query-stats "$SIGIL" 2>/dev/null || echo '{}')
total_files_scanned=$(echo "$stats_json" | jq -r '.total_files_scanned // 0')

# Populate tool_stats from database results and calculate total issues
total_issues=0
for tool in "${tools_list[@]}"; do
    # Convert tool folder name to db member name (e.g., "ascii-cutterman" stays same)
    member_key="$tool"
    issues=$(echo "$stats_json" | jq -r ".member_stats[\"$member_key\"].issues_found // 0")
    tool_stats["$tool"]=$issues
    total_issues=$((total_issues + issues))
done

# Clean up exported variables
unset GUILD_WORKER_REPOS_DIR GUILD_WORKER_SIGIL GUILD_WORKER_STRICTNESS_FLAG
unset GUILD_WORKER_MEMBER_TIMEOUT GUILD_WORKER_FILE_PARALLEL GUILD_WORKER_DRYRUN
unset GUILD_WORKER_SCAN_ALL_OVERRIDE GUILD_WORKER_DEBUG GUILD_WORKER_TOOLS_LIST

# Generate member testaments (reports) - skip in dryrun mode
if [[ "$DRYRUN" != true ]]; then
    echo ""
    echo "${BLUE_COLOR}$(guild_make_separator 81 "═")${RESET_COLOR}"
    echo "${BLUE_COLOR}                              MEMBERS' TESTAMENTS${RESET_COLOR}"
    echo "${BLUE_COLOR}$(guild_make_separator 81 "═")${RESET_COLOR}"

    for tool in "${tools_list[@]}"; do
        tool_exe=$(get_tool_executable "$tool")
        tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"

        report_output=$("$tool_exe" $STRICTNESS_FLAG -r "$SIGIL" 2>&1)

        if [[ -n "$report_output" ]]; then
            echo ""
            echo "${CYAN_COLOR}${tool_display_name}:${RESET_COLOR}"
            echo "$report_output"
        fi
    done
fi

# End the conclave session (skip in dryrun mode)
# Note: || true ensures DB failures don't prevent showing the summary
if [[ "$DRYRUN" != true ]]; then
    end_conclave_session || true
fi

# Final summary
echo ""
echo "${BLUE_COLOR}$(guild_make_separator 81 "═")${RESET_COLOR}"
if [[ "$DRYRUN" == true ]]; then
    echo "${BLUE_COLOR}                            GUILD TRAINING SUMMARY${RESET_COLOR}"
else
    echo "${BLUE_COLOR}                                FINAL DECISION${RESET_COLOR}"
fi
echo "${BLUE_COLOR}$(guild_make_separator 81 "═")${RESET_COLOR}"
echo ""
echo "${YELLOW_COLOR}Total repositories synced:${RESET_COLOR} ${BLUE_COLOR}${total_repos}${RESET_COLOR}"
if [[ "$DRYRUN" == true ]]; then
    echo "${YELLOW_COLOR}Total files to scan:${RESET_COLOR} ${BLUE_COLOR}${total_files_scanned}${RESET_COLOR}"
    echo ""
    echo "${CYAN_COLOR}Files per Guild Member:${RESET_COLOR}"
    for tool in "${tools_list[@]}"; do
        tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
        file_count=${tool_file_counts["$tool"]}
        echo "  ${MAGENTA_COLOR}${tool_display_name}:${RESET_COLOR} ${BLUE_COLOR}${file_count}${RESET_COLOR} files"
    done
else
    echo "${YELLOW_COLOR}Total files scanned:${RESET_COLOR} ${BLUE_COLOR}${total_files_scanned}${RESET_COLOR}"
    echo "${YELLOW_COLOR}Repositories with issues:${RESET_COLOR} ${BLUE_COLOR}${repos_with_issues}${RESET_COLOR}"
fi

# Show orphaned repos if any
if [[ ${#orphan_repos[@]} -gt 0 ]]; then
    echo ""
    echo "${YELLOW_COLOR}${WARNING_SYMBOL} Orphaned repositories (no longer on remote):${RESET_COLOR}"
    # Bash uses ${!array[@]} for keys instead of zsh ${(k)array}
    for repo in "${!orphan_repos[@]}"; do
        echo "  ${MAGENTA_COLOR}${repo}${RESET_COLOR}"
    done
fi

# Show per-tool stats (skip in dryrun mode)
if [[ "$DRYRUN" != true ]]; then
    echo ""
    guild_table_header "Indictments Of The Conclave"
    for tool in "${tools_list[@]}"; do
        tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
        count=${tool_stats["$tool"]}
        if [[ $count -eq 0 ]]; then
            guild_table_status_row "${tool_display_name}:" "0" "true"
        else
            guild_table_status_row "${tool_display_name}:" "${count}" "false"
        fi
    done
    guild_table_footer
fi

echo ""
if [[ "$DRYRUN" == true ]]; then
    echo "${SUCCESS_COLOR}${CHECKMARK} Guild training complete - members are ready${RESET_COLOR}"
    emit_done "0"
    exit 0
elif [[ $total_issues -eq 0 ]]; then
    echo "${SUCCESS_COLOR}${CHECKMARK} All repositories are clean!${RESET_COLOR}"
    emit_done "0"
    exit 0
else
    echo "${FAIL_COLOR}${XMARK} ${total_issues} issue(s) found across ${repos_with_issues} repository(s)${RESET_COLOR}"
    emit_done "1"
    exit 1
fi
