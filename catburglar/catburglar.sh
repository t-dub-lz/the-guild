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

# ═══════════════════════════════════════════════════════════════════════════════
# GUILD MEMBER SETUP
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source guild utilities
source "${SCRIPT_DIR}/../lib/guild-utils.sh"

# Initialize as guild member
guild_init "catburglar" "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# CATBURGLAR-SPECIFIC FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Check GitHub CLI authentication
check_gh_auth() {
    if ! gh auth status &> /dev/null; then
        guild_error "GitHub CLI not authenticated"
        exit 2
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
    local data_file="$GUILD_TEMP_DIR/pr_data.json"

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

    # Combine Snyk failures (use -c for compact single-line JSON output)
    snyk_details=$(echo "$snyk_status $snyk_checkruns" | jq -sc 'add // [] | unique_by(.pr_number)' 2>/dev/null || echo "[]")
    snyk_failures=$(echo "$snyk_details" | jq 'length' 2>/dev/null || echo "0")

    # Output: total_prs|failing_prs|snyk_blocked_prs|snyk_details_json
    printf "%s|%s|%s|%s\n" "$total_prs" "$all_failures" "$snyk_failures" "$snyk_details"
}

# Output detailed information about Snyk-blocked PRs
output_details() {
    local snyk_details="$1"
    local prefix="$2"

    local count
    count=$(echo "$snyk_details" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -gt 0 ]]; then
        echo "$snyk_details" | jq -r --arg prefix "$prefix" '.[] | "\($prefix)PR #\(.pr_number): \(.title[0:60])\n\($prefix)  \(.url)\n\($prefix)  Check: \(.check) (\(.state))"' 2>/dev/null
    fi
}

# Generate and output the aggregated report
generate_report() {
    local sigil="$1"

    if [[ ! -f "$GUILD_DB" ]]; then
        echo "No data collected for this session."
        return
    fi

    # Query scans from database
    local scans_json
    scans_json=$("$GUILD_TSX" "$GUILD_DB" query-scans catburglar "$sigil" 2>/dev/null || echo "[]")

    if [[ "$scans_json" == "[]" ]]; then
        echo "No data collected for this session."
        return
    fi

    # Query findings from database
    local findings_json
    findings_json=$("$GUILD_TSX" "$GUILD_DB" query-findings catburglar "$sigil" 2>/dev/null || echo "[]")

    # Aggregate data using jq
    local total_repos total_prs total_failing total_snyk
    total_repos=$(echo "$scans_json" | jq '[.[].repo] | unique | length' 2>/dev/null || echo "0")
    total_prs=$(echo "$scans_json" | jq '[.[].total_prs] | add // 0' 2>/dev/null || echo "0")
    total_failing=$(echo "$scans_json" | jq '[.[].failing_prs] | add // 0' 2>/dev/null || echo "0")
    total_snyk=$(echo "$scans_json" | jq '[.[].snyk_blocked] | add // 0' 2>/dev/null || echo "0")

    # Output summary using guild table utilities
    printf "\n"
    guild_table_header "Snyk PR Check Analysis Summary"
    guild_table_row "Repositories analyzed:" "$total_repos" "$BLUE"
    guild_table_row "Total open PRs:" "$total_prs" "$BLUE"
    guild_table_row "PRs with any failing check:" "$total_failing" "$YELLOW"
    guild_table_row "PRs blocked by Snyk:" "$total_snyk" "$RED"
    guild_table_footer

    if [[ "$total_snyk" -eq 0 ]]; then
        printf "\n${GREEN}${CHECKMARK} All repositories clean - no Snyk-blocked PRs${NC}\n"
    else
        printf "\n${RED}${BOLD}${XMARK} Snyk-Blocked PRs by Repository:${NC}\n"
        printf "%s\n" "$(guild_make_separator 52 "─")"

        # Get repos with snyk issues
        local repos_with_issues
        repos_with_issues=$(echo "$scans_json" | jq -r '[.[] | select(.snyk_blocked > 0)] | unique_by(.repo) | .[].repo' 2>/dev/null || true)

        for repo in $repos_with_issues; do
            local count pr_findings
            count=$(echo "$scans_json" | jq -r --arg r "$repo" '[.[] | select(.repo == $r)] | .[0].snyk_blocked // 0' 2>/dev/null || echo "0")
            pr_findings=$(echo "$findings_json" | jq -r --arg r "$repo" '[.[] | select(.repo == $r)]' 2>/dev/null || echo "[]")

            printf "\n${MAGENTA}%s${NC} (${RED}%s blocked${NC}):\n" "$repo" "$count"
            echo "$pr_findings" | jq -r '.[] | "  • PR #\(.pr_number): \(.pr_title[0:50])...\n    \(.pr_url)"' 2>/dev/null || true
        done
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    # Parse arguments using guild utilities
    guild_parse_base_args "$@"

    # Report mode - generate aggregated report and exit
    if [[ "$GUILD_REPORT_MODE" == true && -n "$GUILD_SIGIL" ]]; then
        generate_report "$GUILD_SIGIL"
        exit 0
    fi

    # Normal mode - need a repo path
    if [[ -z "$GUILD_REPO_PATH" ]]; then
        guild_exit_error "No repository path provided"
    fi

    # Check dependencies EARLY for fast fail
    guild_check_commands "gh" "jq"

    # Check GitHub CLI authentication
    check_gh_auth

    # Create temp directory for this analysis
    guild_create_temp_dir

    # Extract repo name from path
    local repo_name
    repo_name=$(guild_extract_repo_name "$GUILD_REPO_PATH")

    if [[ -z "$repo_name" || "$repo_name" == "/" ]]; then
        guild_exit_error "Could not extract repo name from path: $GUILD_REPO_PATH"
    fi

    # Analyze the repository
    local result
    result=$(analyze_single_repo "$repo_name")

    # Parse result: total_prs|failing_prs|snyk_blocked_prs|snyk_details_json
    local total_prs failing_prs snyk_blocked snyk_details
    IFS='|' read -r total_prs failing_prs snyk_blocked snyk_details <<< "$result"

    # Record to guild database
    if [[ -n "$GUILD_SIGIL" ]]; then
        # Transform snyk_details to findings format (use -c for compact output)
        local findings_json
        findings_json=$(echo "$snyk_details" | jq -c '[.[] | {pr_number: .pr_number, pr_title: .title, pr_url: .url, check_name: .check, check_state: .state}]' 2>/dev/null || echo "[]")

        local scan_json
        scan_json=$(printf '{"sigil":"%s","repo":"%s","total_prs":%d,"failing_prs":%d,"snyk_blocked":%d}' \
            "$GUILD_SIGIL" "$repo_name" "${total_prs:-0}" "${failing_prs:-0}" "${snyk_blocked:-0}")

        guild_record_scan "$scan_json" "$findings_json"
    fi

    # Output based on mode
    if [[ "$snyk_blocked" -gt 0 ]]; then
        # Has Snyk-blocked PRs
        if [[ "$GUILD_DETAILS_ONLY" == true && "$GUILD_NO_STDOUT" != true ]]; then
            output_details "$snyk_details" "$GUILD_PREFIX"
        fi
        exit 1
    fi

    # Clean - no Snyk-blocked PRs
    exit 0
}

main "$@"
