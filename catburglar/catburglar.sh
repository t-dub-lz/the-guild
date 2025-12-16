#!/usr/bin/env bash
#
# Catburglar - Guild Member for Snyk PR Check Analysis
#
# Analyzes GitHub PRs for Snyk check failures. This is a repository-scope
# tool that runs once per repository (not per file).
#
# Guild Interface:
#   ./catburglar.sh -g <sigil> -nn <repo_path>     Check mode (silent)
#   ./catburglar.sh -g <sigil> -d <repo_path>      Details mode
#   ./catburglar.sh -r <sigil>                      Report mode
#
# Exit codes:
#   0 = No Snyk-blocked PRs
#   1 = Has Snyk-blocked PRs
#   2 = Tool error (missing deps, API failure, etc.)
#

set -euo pipefail

# Tool identification
TOOL_NAME="catburglar"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Guild interface flags
SILENT=false
NO_STDOUT=false
DETAILS_ONLY=false
PREFIX=""
SIGIL=""
REPORT_MODE=false
REPO_PATH=""

# Temp directory for this invocation
TEMP_DIR=""

# Cleanup function
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v gh &> /dev/null; then
        missing+=("gh")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$SILENT" != true ]]; then
            printf "${RED}Error: Missing dependencies: %s${NC}\n" "${missing[*]}" >&2
        fi
        exit 2
    fi

    # Check gh authentication
    if ! gh auth status &> /dev/null; then
        if [[ "$SILENT" != true ]]; then
            printf "${RED}Error: GitHub CLI not authenticated${NC}\n" >&2
        fi
        exit 2
    fi
}

# Extract org/repo name from repository path
# Path format: /path/to/.repos/org/reponame or just org/reponame
extract_repo_name() {
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

# Fetch PR data for a repository using GraphQL
fetch_pr_data() {
    local repo="$1"
    local owner="${repo%%/*}"
    local name="${repo##*/}"
    local output_file="$2"

    # GraphQL query to fetch all open PRs with status checks
    local query='
query($endCursor: String) {
  repository(owner:"'"$owner"'", name:"'"$name"'") {
    pullRequests(first:30, after:$endCursor, states:OPEN) {
      pageInfo { endCursor hasNextPage }
      nodes {
        number
        title
        url
        commits(last:1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first:100) {
                  nodes {
                    ... on StatusContext {
                      context
                      state
                    }
                    ... on CheckRun {
                      name
                      conclusion
                      status
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}'

    gh api graphql --paginate -f query="$query" > "$output_file" 2>/dev/null
}

# Analyze a single repository and return results
# Returns: total_prs|failing_prs|snyk_blocked_prs|snyk_details_json
analyze_single_repo() {
    local repo="$1"
    local data_file="$TEMP_DIR/pr_data.json"

    # Fetch PR data
    if ! fetch_pr_data "$repo" "$data_file" 2>/dev/null; then
        echo "0|0|0|[]"
        return
    fi

    # Check if file is empty or has no PRs
    if [[ ! -s "$data_file" ]]; then
        echo "0|0|0|[]"
        return
    fi

    # Count total PRs (sum across all pages)
    local total_prs=0
    while IFS= read -r count; do
        total_prs=$((total_prs + count))
    done < <(jq '[.data.repository.pullRequests.nodes[]? | .number] | length' "$data_file" 2>/dev/null || echo "0")

    # Find all failing checks (combine StatusContext and CheckRun failures)
    local failing_status failing_checkruns all_failures
    failing_status=$(jq -s '[.[] | .data.repository.pullRequests.nodes[]? |
      . as $pr |
      .commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes[]? |
      select(.context != null and .state != null and .state != "SUCCESS") |
      {pr_number: $pr.number, title: $pr.title, url: $pr.url, check: .context, state: .state}]' "$data_file" 2>/dev/null || echo "[]")

    failing_checkruns=$(jq -s '[.[] | .data.repository.pullRequests.nodes[]? |
      . as $pr |
      .commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes[]? |
      select(.name != null and .conclusion != null and .conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL") |
      {pr_number: $pr.number, title: $pr.title, url: $pr.url, check: .name, state: .conclusion}]' "$data_file" 2>/dev/null || echo "[]")

    # Combine and get unique failing PRs count
    all_failures=$(echo "$failing_status $failing_checkruns" | jq -s 'add // [] | [.[].pr_number] | unique | length' 2>/dev/null || echo "0")

    # Find Snyk-specific failures
    local snyk_status snyk_checkruns snyk_failures snyk_details
    snyk_status=$(jq -s '[.[] | .data.repository.pullRequests.nodes[]? |
      . as $pr |
      .commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes[]? |
      select(.context != null and (.context | ascii_downcase | contains("snyk")) and .state != "SUCCESS") |
      {pr_number: $pr.number, title: $pr.title, url: $pr.url, check: .context, state: .state}]' "$data_file" 2>/dev/null || echo "[]")

    snyk_checkruns=$(jq -s '[.[] | .data.repository.pullRequests.nodes[]? |
      . as $pr |
      .commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes[]? |
      select(.name != null and (.name | ascii_downcase | contains("snyk")) and .conclusion != null and .conclusion != "SUCCESS" and .conclusion != "SKIPPED") |
      {pr_number: $pr.number, title: $pr.title, url: $pr.url, check: .name, state: .conclusion}]' "$data_file" 2>/dev/null || echo "[]")

    # Combine Snyk failures
    snyk_details=$(echo "$snyk_status $snyk_checkruns" | jq -s 'add // [] | unique_by(.pr_number)' 2>/dev/null || echo "[]")
    snyk_failures=$(echo "$snyk_details" | jq 'length' 2>/dev/null || echo "0")

    # Output: total_prs|failing_prs|snyk_blocked_prs|snyk_details_json
    printf "%s|%s|%s|%s\n" "$total_prs" "$all_failures" "$snyk_failures" "$snyk_details"
}

# Output detailed information about Snyk-blocked PRs
output_details() {
    local repo="$1"
    local snyk_details="$2"
    local prefix="$3"

    local count
    count=$(echo "$snyk_details" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -gt 0 ]]; then
        echo "$snyk_details" | jq -r --arg prefix "$prefix" '.[] | "\($prefix)PR #\(.pr_number): \(.title[0:60])\n\($prefix)  \(.url)\n\($prefix)  Check: \(.check) (\(.state))"' 2>/dev/null
    fi
}

# Generate and output the aggregated report
generate_report() {
    local sigil="$1"
    local data_file="/tmp/guild-${TOOL_NAME}-${sigil}.dat"

    if [[ ! -f "$data_file" ]]; then
        echo "No data collected for this session."
        return
    fi

    # Read and aggregate data
    local total_repos=0
    local total_prs=0
    local total_failing=0
    local total_snyk=0
    local repos_with_snyk_issues=0
    local snyk_blocked_repos=()

    while IFS='|' read -r repo prs failing snyk details; do
        [[ -z "$repo" ]] && continue
        total_repos=$((total_repos + 1))
        total_prs=$((total_prs + ${prs:-0}))
        total_failing=$((total_failing + ${failing:-0}))
        total_snyk=$((total_snyk + ${snyk:-0}))

        if [[ "${snyk:-0}" -gt 0 ]]; then
            repos_with_snyk_issues=$((repos_with_snyk_issues + 1))
            snyk_blocked_repos+=("$repo:$snyk:$details")
        fi
    done < "$data_file"

    # Output summary
    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════════════════╗${NC}\n"
    printf "${BOLD}║         Snyk PR Check Analysis Summary            ║${NC}\n"
    printf "${BOLD}╠═══════════════════════════════════════════════════╣${NC}\n"
    printf "║ Repositories analyzed:     ${BLUE}%5d${NC}                  ║\n" "$total_repos"
    printf "║ Total open PRs:            ${BLUE}%5d${NC}                  ║\n" "$total_prs"
    printf "║ PRs with any failing check:${YELLOW}%5d${NC}                  ║\n" "$total_failing"
    printf "║ PRs blocked by Snyk:       ${RED}%5d${NC}                  ║\n" "$total_snyk"
    printf "${BOLD}╚═══════════════════════════════════════════════════╝${NC}\n"

    if [[ "$total_snyk" -eq 0 ]]; then
        printf "\n${GREEN}All repositories clean - no Snyk-blocked PRs${NC}\n"
    else
        printf "\n${RED}${BOLD}Snyk-Blocked PRs by Repository:${NC}\n"
        printf "────────────────────────────────────────────────────\n"

        for entry in "${snyk_blocked_repos[@]}"; do
            local repo="${entry%%:*}"
            local rest="${entry#*:}"
            local count="${rest%%:*}"
            local details="${rest#*:}"

            printf "\n${MAGENTA}%s${NC} (${RED}%s blocked${NC}):\n" "$repo" "$count"
            echo "$details" | jq -r '.[] | "  • PR #\(.pr_number): \(.title[0:50])...\n    \(.url)"' 2>/dev/null || true
        done
    fi

    # Clean up the data file
    rm -f "$data_file"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -nn)
                SILENT=true
                NO_STDOUT=true
                shift
                ;;
            -n)
                NO_STDOUT=true
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
                SIGIL="$2"
                shift 2
                ;;
            -r)
                SIGIL="$2"
                REPORT_MODE=true
                shift 2
                ;;
            -s|-S)
                # Strictness flags - ignored for this tool
                shift
                ;;
            -*)
                # Unknown flag - ignore
                shift
                ;;
            *)
                REPO_PATH="$1"
                shift
                ;;
        esac
    done
}

# Main execution
main() {
    parse_args "$@"

    # Report mode - generate aggregated report and exit
    if [[ "$REPORT_MODE" == true && -n "$SIGIL" ]]; then
        generate_report "$SIGIL"
        exit 0
    fi

    # Normal mode - need a repo path
    if [[ -z "$REPO_PATH" ]]; then
        if [[ "$SILENT" != true ]]; then
            printf "${RED}Error: No repository path provided${NC}\n" >&2
        fi
        exit 2
    fi

    # Check dependencies
    check_dependencies

    # Create temp directory for this analysis
    TEMP_DIR=$(mktemp -d)

    # Extract repo name from path
    local repo_name
    repo_name=$(extract_repo_name "$REPO_PATH")

    if [[ -z "$repo_name" || "$repo_name" == "/" ]]; then
        if [[ "$SILENT" != true ]]; then
            printf "${RED}Error: Could not extract repo name from path: %s${NC}\n" "$REPO_PATH" >&2
        fi
        exit 2
    fi

    # Analyze the repository
    local result
    result=$(analyze_single_repo "$repo_name")

    # Parse result: total_prs|failing_prs|snyk_blocked_prs|snyk_details_json
    local total_prs failing_prs snyk_blocked snyk_details
    IFS='|' read -r total_prs failing_prs snyk_blocked snyk_details <<< "$result"

    # Record to sigil data file for later aggregation
    if [[ -n "$SIGIL" ]]; then
        local data_file="/tmp/guild-${TOOL_NAME}-${SIGIL}.dat"
        # Store: repo|total_prs|failing_prs|snyk_blocked|snyk_details_json
        printf "%s|%s|%s|%s|%s\n" "$repo_name" "$total_prs" "$failing_prs" "$snyk_blocked" "$snyk_details" >> "$data_file"
    fi

    # Output based on mode
    if [[ "$snyk_blocked" -gt 0 ]]; then
        # Has Snyk-blocked PRs
        if [[ "$DETAILS_ONLY" == true && "$NO_STDOUT" != true ]]; then
            output_details "$repo_name" "$snyk_details" "$PREFIX"
        fi
        exit 1
    fi

    # Clean - no Snyk-blocked PRs
    exit 0
}

main "$@"
