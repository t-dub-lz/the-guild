#!/usr/bin/env zsh

# The Guild Conclave - Multi-tool repository scanner
# Discovers and runs all Guild Member tools against repositories

# Colors and symbols
CHECKMARK='✓'
XMARK='✗'
DOWN_RIGHT_ARROW="╰─>"
WARNING_SYMBOL='⚠'

SUCCESS_COLOR=$'\e[32m'
FAIL_COLOR=$'\e[31m'
YELLOW_COLOR=$'\e[33m'
BLUE_COLOR=$'\e[34m'
MAGENTA_COLOR=$'\e[35m'
NEON_GREEN=$'\e[92m'
CYAN_COLOR=$'\e[36m'
RESET_COLOR=$'\e[0m'

# Spinner animation frames (zsh arrays are 1-indexed)
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_INDEX=1

# Default configuration
REPO_LIMIT=10000
ORG_NAME=""
SCRIPT_DIR="${0:A:h}"  # Directory where this script lives
REPOS_DIR="$SCRIPT_DIR/.repos"
PARALLEL_JOBS=10
STRICTNESS_FLAG=""
SCAN_ALL_OVERRIDE=false  # -a flag overrides per-tool config
DRYRUN=false             # -n flag for guild training mode (counts files only)
EXCLUDED_MEMBERS=()      # -x flag to exclude specific members

# Generate unique sigil (UUID) for this session
SIGIL=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | sha256sum | cut -c1-36)

# Load environment variables from .env file if it exists
# This allows Guild members to access secrets like OPENAI_API_KEY
load_env_file() {
    local env_file="$SCRIPT_DIR/.env"

    if [[ -f "$env_file" ]]; then
        # Read .env file line by line
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
            if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${match[1]}"
            fi

            # Export the variable
            export "$key=$value"
        done < "$env_file"
    fi
}

# Load .env before any tool invocations
load_env_file

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW_COLOR}Cleaning up...${RESET_COLOR}"

    # Kill xargs and all its children if it's running
    if [[ -n "$xargs_pid" ]] && kill -0 "$xargs_pid" 2>/dev/null; then
        kill -- -$xargs_pid 2>/dev/null || true
        wait "$xargs_pid" 2>/dev/null || true
    fi

    # Kill sync process if it's running
    if [[ -n "$sync_pid" ]] && kill -0 "$sync_pid" 2>/dev/null; then
        kill "$sync_pid" 2>/dev/null || true
        wait "$sync_pid" 2>/dev/null || true
    fi

    exit 1
}

trap cleanup INT TERM

# Help function
show_help() {
    echo "Usage: conclave.zsh [OPTIONS] [repo1,repo2,...]"
    echo ""
    echo "The Guild Conclave - Multi-tool repository scanner"
    echo "Discovers and runs all Guild Member tools against repositories."
    echo ""
    echo "Options:"
    echo "  -o <org>        Organization name (default: your GitHub user)"
    echo "  -l <number>     Limit number of repos to fetch (default: 10000)"
    echo "  -j <number>     Number of parallel jobs (default: 10)"
    echo "  -x <members>    Exclude members by folder name (comma-separated)"
    echo "  -a              Scan all text files (overrides per-tool config)"
    echo "  -n              Guild training - count files without running analysis"
    echo "  -s              Strict mode"
    echo "  -S              Super strict mode"
    echo "  -h, --help      Show this help message"
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

# Function to clear spinner line
clear_spinner() {
    printf "\r\033[K"
}

# Discover Guild Member tools
# Each tool lives in its own folder, with the main executable having the same name as the folder
discover_tools() {
    local tools=()
    for dir in "$SCRIPT_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local dirname="${dir%/}"
        dirname="${dirname##*/}"

        # Skip hidden dirs, .repos, node_modules
        [[ "$dirname" == .* ]] && continue
        [[ "$dirname" == "node_modules" ]] && continue
        [[ "$dirname" == ".repos" ]] && continue

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

# Strip JSONC comments from input
# Removes // comments on their own lines and /* */ block comments
strip_jsonc_comments() {
    local input="$1"
    echo "$input" | sed -e '/^[[:space:]]*\/\//d' -e 's|/\*.*\*/||g'
}

# Read tool config value using jq or python fallback (supports JSONC)
get_tool_config() {
    local tool_name="$1"
    local key="$2"
    local config_file="$SCRIPT_DIR/$tool_name/config.jsonc"
    local json_content

    # Read and strip JSONC comments
    json_content=$(strip_jsonc_comments "$(cat "$config_file")")

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
    json_content=$(strip_jsonc_comments "$(cat "$config_file")")

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
    local val=$(get_tool_config "$tool_name" "scanAllText")
    [[ "$val" == "true" ]]
}

# Check if tool ignores the -a (scan all) override
tool_ignores_all() {
    local tool_name="$1"
    local val=$(get_tool_config "$tool_name" "ignoreAll")
    [[ "$val" == "true" ]]
}

# Check if tool operates at repository scope (once per repo, not per file)
tool_has_repository_scope() {
    local tool_name="$1"
    local val=$(get_tool_config "$tool_name" "repositoryScope")
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

# Sync a repository (clone or pull)
# Returns: CLONED, UPDATED, ORPHAN, or SKIP
sync_repo() {
    local repo="$1"
    local org="${repo%/*}"
    local name="${repo#*/}"
    local local_path="$REPOS_DIR/$org/$name"
    local is_orphan=false

    # Check if remote exists
    if ! gh repo view "$repo" &>/dev/null 2>&1; then
        is_orphan=true
    fi

    if [[ -d "$local_path/.git" ]]; then
        # Repo exists locally
        if [[ "$is_orphan" == true ]]; then
            echo "ORPHAN"
        else
            # Update existing repo
            cd "$local_path"
            local default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
            git fetch origin --quiet 2>/dev/null
            git reset --hard "origin/$default_branch" --quiet 2>/dev/null
            cd - >/dev/null
            echo "UPDATED"
        fi
    elif [[ "$is_orphan" == false ]]; then
        # Clone new repo
        mkdir -p "$REPOS_DIR/$org"
        if gh repo clone "$repo" "$local_path" -- --quiet 2>/dev/null; then
            echo "CLONED"
        else
            echo "FAILED"
        fi
    else
        echo "SKIP"
    fi
}

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

# Parse arguments
REPO_LIST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -o)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -n requires an organization name"
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
        -j)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -j requires a number"
                exit 1
            fi
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -x)
            if [[ -z "$2" ]]; then
                echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -x requires comma-separated member folder names" >&2
                exit 1
            fi
            IFS=',' read -A EXCLUDED_MEMBERS <<< "$2"
            # Validate each excluded member exists
            for member in "${EXCLUDED_MEMBERS[@]}"; do
                local member_dir="$SCRIPT_DIR/$member"
                local has_config=false
                local has_exe=false
                [[ -f "$member_dir/config.jsonc" ]] && has_config=true
                for ext in "" ".sh" ".zsh" ".ts" ".py" ".js"; do
                    [[ -f "$member_dir/${member}${ext}" ]] && has_exe=true && break
                done
                if [[ "$has_config" != true || "$has_exe" != true ]]; then
                    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Unknown member: ${member}" >&2
                    echo "  Available members:" >&2
                    for dir in "$SCRIPT_DIR"/*/; do
                        [[ ! -d "$dir" ]] && continue
                        local dirname="${dir%/}"
                        dirname="${dirname##*/}"
                        [[ "$dirname" == .* || "$dirname" == "node_modules" || "$dirname" == ".repos" ]] && continue
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

# Ensure .repos directory exists
mkdir -p "$REPOS_DIR"

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
    local tool_display_name=$(get_tool_config "$tool" "name")
    [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
    echo "  ${CYAN_COLOR}${tool_display_name}${RESET_COLOR}"
done
if [[ ${#EXCLUDED_MEMBERS[@]} -gt 0 ]]; then
    echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Excluded from conclave: ${BLUE_COLOR}${#EXCLUDED_MEMBERS[@]}${RESET_COLOR}"
    for excluded in "${EXCLUDED_MEMBERS[@]}"; do
        local excluded_display_name=$(get_tool_config "$excluded" "name")
        [[ -z "$excluded_display_name" ]] && excluded_display_name="$excluded"
        echo "  ${MAGENTA_COLOR}${excluded_display_name}${RESET_COLOR}"
    done
fi
echo ""

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
    local members_json=$(printf '%s\n' "${tools_list[@]}" | jq -R . | jq -s . 2>/dev/null)

    # Build excluded members JSON array (if any)
    local excluded_json="null"
    if [[ ${#EXCLUDED_MEMBERS[@]} -gt 0 ]]; then
        excluded_json=$(printf '%s\n' "${EXCLUDED_MEMBERS[@]}" | jq -R . | jq -s . 2>/dev/null)
    fi

    # Build config JSON
    local config_json=$(jq -n \
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

# Initialize database
if init_database; then
    echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Guild Database initialized"
    start_conclave_session
fi

# Get list of repositories
if [[ -n "$REPO_LIST" ]]; then
    IFS=',' read -A repo_array <<< "$REPO_LIST"
    repos=$(printf "%s\n" "${repo_array[@]}")
    echo "${BLUE_COLOR}Processing specified repositories...${RESET_COLOR}"
else
    # If no org specified, use the authenticated user's repos
    if [[ -z "$ORG_NAME" ]]; then
        ORG_NAME=$(gh api user -q '.login' 2>/dev/null)
        if [[ -z "$ORG_NAME" ]]; then
            echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Could not determine GitHub user. Use -n to specify an org."
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

# Track overall stats
total_repos=0
repos_with_issues=0
total_files_scanned=0
declare -A repo_issues       # repo -> "count:file1|file2|..."
declare -A orphan_repos      # track orphaned repos
declare -A tool_stats        # tool -> "issues_count"
declare -A tool_file_counts  # tool -> "files_to_check" (for guild training)

# Initialize tool stats
for tool in "${tools_list[@]}"; do
    tool_stats["$tool"]=0
    tool_file_counts["$tool"]=0
done

# Process each repository
while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue

    ((total_repos++))

    echo ""
    local header_text="Repository: ${repo}"
    local header_len=${#header_text}
    local separator_line="${(l:$header_len::═:)}"
    echo "${BLUE_COLOR}${separator_line}${RESET_COLOR}"
    echo "${BLUE_COLOR}Repository: ${MAGENTA_COLOR}${repo}${RESET_COLOR}"
    echo "${BLUE_COLOR}${separator_line}${RESET_COLOR}"

    # Sync repository (clone or pull)
    local sync_result_file=$(mktemp)

    # Run sync in background, capture result to temp file
    (sync_repo "$repo" > "$sync_result_file") &
    sync_pid=$!

    # Show spinner immediately, then update in loop
    printf "${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Syncing repository..."
    while kill -0 "$sync_pid" 2>/dev/null; do
        sleep 0.1
        SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
        printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Syncing repository..."
    done

    wait "$sync_pid"
    clear_spinner
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
            orphan_repos["$repo"]=1
            ;;
        SKIP)
            echo "${YELLOW_COLOR}${WARNING_SYMBOL}${RESET_COLOR} Skipping - no remote and no local copy"
            continue
            ;;
        FAILED)
            echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Failed to clone ${repo}"
            continue
            ;;
    esac

    if [[ ! -d "$repo_path" ]]; then
        echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Repository path not found: $repo_path"
        continue
    fi

    # Run each tool on the repository
    repo_had_issues=false

    for tool in "${tools_list[@]}"; do
        local tool_exe=$(get_tool_executable "$tool")
        local tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"

        echo ""
        echo "${CYAN_COLOR}Consulting ${tool_display_name}${RESET_COLOR}"

        # Handle repository-scope tools (run once per repo, not per file)
        if tool_has_repository_scope "$tool"; then
            # In guild training mode, just report that this tool will run
            if [[ "$DRYRUN" == true ]]; then
                tool_file_counts["$tool"]=$((tool_file_counts["$tool"] + 1))
                echo "${CYAN_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Repository-scope tool (1 invocation)"
                continue
            fi

            local temp_results=$(mktemp)
            local exit_code=0

            # Run tool in background with spinner
            ("$tool_exe" $STRICTNESS_FLAG -g "$SIGIL" -nn "$repo_path" > /dev/null 2>&1; echo $? > "$temp_results") &
            local tool_pid=$!

            printf "${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Analyzing repository..."
            while kill -0 "$tool_pid" 2>/dev/null; do
                sleep 0.1
                SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
                printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Analyzing repository..."
            done
            wait "$tool_pid"
            clear_spinner

            exit_code=$(cat "$temp_results")
            rm -f "$temp_results"

            if [[ "$exit_code" -eq 0 ]]; then
                echo "${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Clean - repository checked"
            elif [[ "$exit_code" -eq 1 ]]; then
                repo_had_issues=true
                tool_stats["$tool"]=$((tool_stats["$tool"] + 1))

                # Get detailed output
                local issues=$("$tool_exe" $STRICTNESS_FLAG -g "$SIGIL" -d --prefix="    " "$repo_path" 2>&1)
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
        local files_temp=$(mktemp)

        (find_files_for_tool "$tool" "$repo_path" > "$files_temp") &
        local find_pid=$!

        printf "${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Finding files..."
        while kill -0 "$find_pid" 2>/dev/null; do
            sleep 0.1
            SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
            printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Finding files..."
        done
        wait "$find_pid"
        clear_spinner

        while IFS= read -r -d '' file; do
            [[ -n "$file" ]] && files+=("$file")
        done < "$files_temp"
        rm -f "$files_temp"

        local total_files=${#files[@]}
        ((total_files_scanned += total_files))

        if [[ $total_files -eq 0 ]]; then
            echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} No matching files found"
            continue
        fi

        # In guild training mode, just report the count and skip actual analysis
        if [[ "$DRYRUN" == true ]]; then
            tool_file_counts["$tool"]=$((tool_file_counts["$tool"] + total_files))
            echo "${CYAN_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Files to check: ${BLUE_COLOR}${total_files}${RESET_COLOR}"
            continue
        fi

        # Check files with tool in parallel
        local problem_files=()
        declare -A file_issues
        local temp_results=$(mktemp)

        # Run parallel checks
        # Use null byte (\0) as record separator to handle multi-line tool output
        printf '%s\0' "${files[@]}" | xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c '
            exit_code=0
            "$1" $2 -g "$3" -nn "{}" 2>/dev/null || exit_code=$?

            if [[ $exit_code -eq 1 ]]; then
                issues=$("$1" $2 -g "$3" -d --prefix="    " "{}" 2>&1)
                # Use null byte as record separator to preserve multi-line issues
                printf "PROBLEM:%s|||%s\0" "{}" "$issues"
            fi
        ' _ "$tool_exe" "$STRICTNESS_FLAG" "$SIGIL" > "$temp_results" 2>/dev/null &

        xargs_pid=$!

        # Show spinner immediately, then update in loop
        printf "${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Scanning ${BLUE_COLOR}${total_files}${RESET_COLOR} files..."
        while kill -0 "$xargs_pid" 2>/dev/null; do
            sleep 0.1
            SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
            printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Scanning ${BLUE_COLOR}${total_files}${RESET_COLOR} files..."
        done

        wait "$xargs_pid"
        clear_spinner

        # Parse results - use null byte as record delimiter to handle multi-line issues
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
            tool_stats["$tool"]=$((tool_stats["$tool"] + problem_count))
            echo "${FAIL_COLOR}${XMARK}${RESET_COLOR} Issues found - ${BLUE_COLOR}${problem_count}${RESET_COLOR} of ${BLUE_COLOR}${total_files}${RESET_COLOR} files"

            for pfile in "${problem_files[@]}"; do
                local display_file="${pfile#$repo_path/}"
                echo "  ${MAGENTA_COLOR}${display_file}${RESET_COLOR}"
                if [[ -n "${file_issues["$pfile"]}" ]]; then
                    echo "${file_issues["$pfile"]}"
                fi
            done
        fi

        unset file_issues
    done

    if [[ "$repo_had_issues" == true ]]; then
        ((repos_with_issues++))
    fi

done <<< "$repos"

# Generate member testaments (reports) - skip in dryrun mode
if [[ "$DRYRUN" != true ]]; then
    echo ""
    echo "${BLUE_COLOR}═════════════════════════════════════════════════════════════════════════════════${RESET_COLOR}"
    echo "${BLUE_COLOR}                              MEMBERS' TESTAMENTS${RESET_COLOR}"
    echo "${BLUE_COLOR}═════════════════════════════════════════════════════════════════════════════════${RESET_COLOR}"

    for tool in "${tools_list[@]}"; do
        local tool_exe=$(get_tool_executable "$tool")
        local tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"

        local report_output=$("$tool_exe" $STRICTNESS_FLAG -r "$SIGIL" 2>&1)

        if [[ -n "$report_output" ]]; then
            echo ""
            echo "${CYAN_COLOR}${tool_display_name}:${RESET_COLOR}"
            echo "$report_output"
        fi
    done
fi

# End conclave session in database
end_conclave_session() {
    local lib_dir="$SCRIPT_DIR/lib"
    local guild_db="$lib_dir/guild-db.ts"

    [[ ! -f "$guild_db" ]] && return 1

    local stats_json=$(jq -n \
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

# End the conclave session (skip in dryrun mode)
if [[ "$DRYRUN" != true ]]; then
    end_conclave_session
fi

# Final summary
echo ""
echo "${BLUE_COLOR}═════════════════════════════════════════════════════════════════════════════════${RESET_COLOR}"
if [[ "$DRYRUN" == true ]]; then
    echo "${BLUE_COLOR}                            GUILD TRAINING SUMMARY${RESET_COLOR}"
else
    echo "${BLUE_COLOR}                                FINAL DECISION${RESET_COLOR}"
fi
echo "${BLUE_COLOR}═════════════════════════════════════════════════════════════════════════════════${RESET_COLOR}"
echo ""
echo "${YELLOW_COLOR}Total repositories synced:${RESET_COLOR} ${BLUE_COLOR}${total_repos}${RESET_COLOR}"
if [[ "$DRYRUN" == true ]]; then
    echo "${YELLOW_COLOR}Total files to scan:${RESET_COLOR} ${BLUE_COLOR}${total_files_scanned}${RESET_COLOR}"
    echo ""
    echo "${CYAN_COLOR}Files per Guild Member:${RESET_COLOR}"
    for tool in "${tools_list[@]}"; do
        local tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
        local file_count=${tool_file_counts["$tool"]}
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
    for repo in ${(k)orphan_repos}; do
        echo "  ${MAGENTA_COLOR}${repo}${RESET_COLOR}"
    done
fi

# Show per-tool stats (skip in dryrun mode)
if [[ "$DRYRUN" != true ]]; then
    echo ""
    echo "${CYAN_COLOR}Indictments Of The Conclave:${RESET_COLOR}"
    for tool in "${tools_list[@]}"; do
        local tool_display_name=$(get_tool_config "$tool" "name")
        [[ -z "$tool_display_name" ]] && tool_display_name="$tool"
        local count=${tool_stats["$tool"]}
        if [[ $count -eq 0 ]]; then
            echo "  ${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} ${tool_display_name}: ${BLUE_COLOR}0${RESET_COLOR} issues"
        else
            echo "  ${FAIL_COLOR}${XMARK}${RESET_COLOR} ${tool_display_name}: ${BLUE_COLOR}${count}${RESET_COLOR} issues"
        fi
    done
fi

echo ""
if [[ "$DRYRUN" == true ]]; then
    echo "${SUCCESS_COLOR}${CHECKMARK} Guild training complete - members are ready${RESET_COLOR}"
    exit 0
elif [[ $repos_with_issues -eq 0 ]]; then
    echo "${SUCCESS_COLOR}${CHECKMARK} All repositories are clean!${RESET_COLOR}"
    exit 0
else
    echo "${FAIL_COLOR}${XMARK} ${repos_with_issues} repository(s) have issues${RESET_COLOR}"
    exit 1
fi
