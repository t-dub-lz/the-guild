#!/usr/bin/env bash
#
# Sentinel - Guild Member for Snyk Vulnerability Scanning
#
# Runs Snyk scans on repositories to detect vulnerabilities.
# Normal mode runs SCA (dependency) scanning only.
# Strict modes (-s/-S) add SAST (code) scanning.
#
# Guild Interface:
#   ./sentinel.sh -g <sigil> -nn <repo_path>     Check mode (silent)
#   ./sentinel.sh -g <sigil> -d <repo_path>      Details mode
#   ./sentinel.sh -r <sigil>                      Report mode
#
# Exit codes:
#   0 = No vulnerabilities found
#   1 = Vulnerabilities found
#   2 = Tool error (missing deps, auth failure, etc.)
#

set -euo pipefail

# Tool identification
TOOL_NAME="sentinel"

# Guild DB path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUILD_DB="${SCRIPT_DIR}/../lib/guild-db.ts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
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
STRICTNESS_FLAG=""

# Temp directory for this invocation
TEMP_DIR=""

# Cleanup function
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Check dependencies - CALLED EARLY for fast fail
check_dependencies() {
    local missing=()

    if ! command -v snyk &> /dev/null; then
        missing+=("snyk")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$SILENT" != true ]]; then
            printf "${RED}Error: Missing dependencies: %s${NC}\n" "${missing[*]}" >&2
            if [[ " ${missing[*]} " =~ " snyk " ]]; then
                printf "Install Snyk CLI: npm install -g snyk\n" >&2
            fi
        fi
        exit 2
    fi
}

# Check Snyk authentication
check_snyk_auth() {
    # Check if Snyk config file exists with credentials
    local config_file="${HOME}/.config/configstore/snyk.json"

    if [[ -f "$config_file" ]]; then
        # Config exists - check for OAuth token or API token
        # OAuth uses INTERNAL_OAUTH_TOKEN_STORAGE, API uses api key
        local has_token
        has_token=$(jq -e '.INTERNAL_OAUTH_TOKEN_STORAGE // .api // empty' "$config_file" 2>/dev/null || echo "")
        if [[ -n "$has_token" ]]; then
            return 0
        fi
    fi

    # Fallback: check if API token is set via snyk config or environment
    local token
    token=$(snyk config get api 2>/dev/null || echo "")
    if [[ -n "$token" ]]; then
        return 0
    fi

    # Check SNYK_TOKEN environment variable
    if [[ -n "${SNYK_TOKEN:-}" ]]; then
        return 0
    fi

    # No authentication found
    if [[ "$SILENT" != true ]]; then
        printf "${RED}Error: Snyk CLI not authenticated${NC}\n" >&2
        printf "Run 'snyk auth' to authenticate with Snyk\n" >&2
    fi
    exit 2
}

# Extract org/repo name from repository path
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

# Run SCA scan (snyk test)
# Returns: exit_code|critical|high|medium|low|findings_json|error_msg
run_sca_scan() {
    local repo_path="$1"
    local output_file="$TEMP_DIR/sca_output.json"
    local exit_code=0

    # Run snyk test with JSON output
    # Note: snyk returns 1 if vulnerabilities found (not an error!)
    snyk test --json --all-projects "$repo_path" > "$output_file" 2>&1 || exit_code=$?

    # Handle exit codes
    # 0 = no vulnerabilities
    # 1 = vulnerabilities found (success, parse results)
    # 2 = CLI error
    # 3 = no supported projects found

    if [[ $exit_code -eq 2 ]]; then
        local error_msg
        error_msg=$(jq -r '.error // "Snyk CLI error"' "$output_file" 2>/dev/null || echo "Snyk CLI error")
        echo "${exit_code}|0|0|0|0|[]|${error_msg}"
        return
    fi

    if [[ $exit_code -eq 3 ]]; then
        # No supported projects - not an error, just nothing to scan
        echo "0|0|0|0|0|[]|"
        return
    fi

    # Parse results (exit code 0 or 1)
    parse_sca_results "$output_file" "$exit_code"
}

# Parse SCA results from JSON
parse_sca_results() {
    local json_file="$1"
    local exit_code="$2"

    # Handle array of results (--all-projects) or single result
    local is_array
    is_array=$(jq 'if type == "array" then "yes" else "no" end' "$json_file" 2>/dev/null || echo "no")

    local critical=0 high=0 medium=0 low=0
    local findings="[]"

    if [[ "$is_array" == '"yes"' ]]; then
        # Multiple projects - aggregate results
        critical=$(jq '[.[] | .vulnerabilities[]? | select(.severity == "critical")] | length' "$json_file" 2>/dev/null || echo 0)
        high=$(jq '[.[] | .vulnerabilities[]? | select(.severity == "high")] | length' "$json_file" 2>/dev/null || echo 0)
        medium=$(jq '[.[] | .vulnerabilities[]? | select(.severity == "medium")] | length' "$json_file" 2>/dev/null || echo 0)
        low=$(jq '[.[] | .vulnerabilities[]? | select(.severity == "low")] | length' "$json_file" 2>/dev/null || echo 0)

        # Extract findings (deduplicated by vuln ID)
        findings=$(jq -c '[.[] | .vulnerabilities[]? | {
            vuln_id: (.identifiers.CVE[0] // .id // "unknown"),
            source: "sca",
            severity: .severity,
            title: .title,
            package_name: .packageName,
            package_version: .version,
            cvss_score: (.cvssScore // null),
            is_upgradable: (if .isUpgradable then 1 else 0 end)
        }] | unique_by(.vuln_id)' "$json_file" 2>/dev/null || echo "[]")
    else
        # Single project result
        critical=$(jq '[.vulnerabilities[]? | select(.severity == "critical")] | length' "$json_file" 2>/dev/null || echo 0)
        high=$(jq '[.vulnerabilities[]? | select(.severity == "high")] | length' "$json_file" 2>/dev/null || echo 0)
        medium=$(jq '[.vulnerabilities[]? | select(.severity == "medium")] | length' "$json_file" 2>/dev/null || echo 0)
        low=$(jq '[.vulnerabilities[]? | select(.severity == "low")] | length' "$json_file" 2>/dev/null || echo 0)

        findings=$(jq -c '[.vulnerabilities[]? | {
            vuln_id: (.identifiers.CVE[0] // .id // "unknown"),
            source: "sca",
            severity: .severity,
            title: .title,
            package_name: .packageName,
            package_version: .version,
            cvss_score: (.cvssScore // null),
            is_upgradable: (if .isUpgradable then 1 else 0 end)
        }] | unique_by(.vuln_id)' "$json_file" 2>/dev/null || echo "[]")
    fi

    echo "${exit_code}|${critical}|${high}|${medium}|${low}|${findings}|"
}

# Run SAST scan (snyk code test)
# Returns: exit_code|critical|high|medium|low|findings_json|error_msg
run_sast_scan() {
    local repo_path="$1"
    local output_file="$TEMP_DIR/sast_output.json"
    local exit_code=0

    # Run snyk code test with JSON output
    snyk code test --json "$repo_path" > "$output_file" 2>&1 || exit_code=$?

    # Handle exit codes (same as SCA)
    if [[ $exit_code -eq 2 ]]; then
        local error_msg
        error_msg=$(jq -r '.error // "Snyk Code CLI error"' "$output_file" 2>/dev/null || echo "Snyk Code CLI error")
        echo "${exit_code}|0|0|0|0|[]|${error_msg}"
        return
    fi

    if [[ $exit_code -eq 3 ]]; then
        # No supported files - not an error
        echo "0|0|0|0|0|[]|"
        return
    fi

    # Parse results
    parse_sast_results "$output_file" "$exit_code"
}

# Parse SAST results from JSON
parse_sast_results() {
    local json_file="$1"
    local exit_code="$2"

    # SAST results have a different structure - runs array with results
    local critical=0 high=0 medium=0 low=0
    local findings="[]"

    # Count by severity (Snyk Code uses 1-3 scale, map to severity names)
    # Level 1 = low, 2 = medium, 3 = high
    # Note: Snyk Code doesn't typically have "critical" but we handle it just in case
    critical=$(jq '[.runs[]?.results[]? | select(.level == "error" and .properties.priorityScore >= 900)] | length' "$json_file" 2>/dev/null || echo 0)
    high=$(jq '[.runs[]?.results[]? | select(.level == "error" or .level == "warning")] | length' "$json_file" 2>/dev/null || echo 0)
    medium=$(jq '[.runs[]?.results[]? | select(.level == "note")] | length' "$json_file" 2>/dev/null || echo 0)
    low=$(jq '[.runs[]?.results[]? | select(.level == "none" or .level == null)] | length' "$json_file" 2>/dev/null || echo 0)

    # Extract findings
    findings=$(jq -c '[.runs[]?.results[]? | {
        vuln_id: (.ruleId // "unknown"),
        source: "sast",
        severity: (if .level == "error" then "high" elif .level == "warning" then "medium" else "low" end),
        title: (.message.text // .ruleId // "Code issue"),
        file_path: (.locations[0]?.physicalLocation?.artifactLocation?.uri // null),
        line_number: (.locations[0]?.physicalLocation?.region?.startLine // null),
        cwe: (.properties.cwe[0] // null)
    }]' "$json_file" 2>/dev/null || echo "[]")

    echo "${exit_code}|${critical}|${high}|${medium}|${low}|${findings}|"
}

# Analyze a single repository
# Returns structured results for database recording
analyze_single_repo() {
    local repo_path="$1"
    local scan_type="sca"

    # Initialize counters
    local sca_critical=0 sca_high=0 sca_medium=0 sca_low=0
    local sast_critical=0 sast_high=0 sast_medium=0 sast_low=0
    local sca_error="" sast_error=""
    local sca_findings="[]" sast_findings="[]"
    local has_vulns=false

    # Always run SCA scan
    local sca_result
    sca_result=$(run_sca_scan "$repo_path")

    # Parse SCA result: exit_code|critical|high|medium|low|findings_json|error_msg
    IFS='|' read -r sca_exit sca_critical sca_high sca_medium sca_low sca_findings sca_error <<< "$sca_result"

    if [[ $sca_exit -eq 1 ]]; then
        has_vulns=true
    fi

    # Run SAST if strict mode is enabled
    if [[ "$STRICTNESS_FLAG" == "-s" || "$STRICTNESS_FLAG" == "-S" ]]; then
        scan_type="both"
        local sast_result
        sast_result=$(run_sast_scan "$repo_path")

        IFS='|' read -r sast_exit sast_critical sast_high sast_medium sast_low sast_findings sast_error <<< "$sast_result"

        if [[ $sast_exit -eq 1 ]]; then
            has_vulns=true
        fi
    fi

    # Calculate total vulnerabilities
    local total_vulns=$((sca_critical + sca_high + sca_medium + sca_low + sast_critical + sast_high + sast_medium + sast_low))

    # Combine findings (use jq to merge arrays)
    local all_findings
    all_findings=$(echo "$sca_findings $sast_findings" | jq -sc 'add // []' 2>/dev/null || echo "[]")

    # Output structured result
    # Format: scan_type|total|sca_c|sca_h|sca_m|sca_l|sast_c|sast_h|sast_m|sast_l|sca_error|sast_error|findings_json|has_vulns
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$scan_type" "$total_vulns" \
        "$sca_critical" "$sca_high" "$sca_medium" "$sca_low" \
        "$sast_critical" "$sast_high" "$sast_medium" "$sast_low" \
        "$sca_error" "$sast_error" \
        "$all_findings" "$has_vulns"
}

# Output detailed findings for -d mode
output_details() {
    local findings_json="$1"
    local prefix="$2"

    # Group by severity and output
    local count
    count=$(echo "$findings_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        return
    fi

    # Output critical first, then high, medium, low
    for severity in critical high medium low; do
        echo "$findings_json" | jq -r --arg sev "$severity" --arg prefix "$prefix" '
            .[] | select(.severity == $sev) |
            if .source == "sca" then
                "\($prefix)[\(.severity | ascii_upcase)] \(.vuln_id) - \(.title)\n\($prefix)  Package: \(.package_name)@\(.package_version)"
            else
                "\($prefix)[\(.severity | ascii_upcase)] \(.vuln_id) - \(.title)\n\($prefix)  File: \(.file_path):\(.line_number // "?")"
            end
        ' 2>/dev/null || true
    done
}

# Generate aggregated report for -r mode
generate_report() {
    local sigil="$1"

    if [[ ! -f "$GUILD_DB" ]]; then
        echo "No data collected for this session."
        return
    fi

    # Query scans from database
    local scans_json
    scans_json=$(npx tsx "$GUILD_DB" query-scans sentinel "$sigil" 2>/dev/null || echo "[]")

    if [[ "$scans_json" == "[]" ]]; then
        echo "No data collected for this session."
        return
    fi

    # Query findings from database
    local findings_json
    findings_json=$(npx tsx "$GUILD_DB" query-findings sentinel "$sigil" 2>/dev/null || echo "[]")

    # Aggregate statistics
    local total_repos total_vulns repos_with_vulns
    local sca_critical sca_high sca_medium sca_low
    local sast_critical sast_high sast_medium sast_low

    total_repos=$(echo "$scans_json" | jq '[.[].repo] | unique | length' 2>/dev/null || echo "0")
    repos_with_vulns=$(echo "$scans_json" | jq '[.[] | select(.total_vulns > 0)] | [.[].repo] | unique | length' 2>/dev/null || echo "0")
    total_vulns=$(echo "$scans_json" | jq '[.[].total_vulns] | add // 0' 2>/dev/null || echo "0")

    sca_critical=$(echo "$scans_json" | jq '[.[].sca_critical] | add // 0' 2>/dev/null || echo "0")
    sca_high=$(echo "$scans_json" | jq '[.[].sca_high] | add // 0' 2>/dev/null || echo "0")
    sca_medium=$(echo "$scans_json" | jq '[.[].sca_medium] | add // 0' 2>/dev/null || echo "0")
    sca_low=$(echo "$scans_json" | jq '[.[].sca_low] | add // 0' 2>/dev/null || echo "0")

    sast_critical=$(echo "$scans_json" | jq '[.[].sast_critical] | add // 0' 2>/dev/null || echo "0")
    sast_high=$(echo "$scans_json" | jq '[.[].sast_high] | add // 0' 2>/dev/null || echo "0")
    sast_medium=$(echo "$scans_json" | jq '[.[].sast_medium] | add // 0' 2>/dev/null || echo "0")
    sast_low=$(echo "$scans_json" | jq '[.[].sast_low] | add // 0' 2>/dev/null || echo "0")

    # Output summary
    printf "\n"
    printf "${BOLD}+===================================================+${NC}\n"
    printf "${BOLD}|       Snyk Vulnerability Scan Summary             |${NC}\n"
    printf "${BOLD}+===================================================+${NC}\n"
    printf "| Repositories scanned:        ${BLUE}%5d${NC}                |\n" "$total_repos"
    printf "| Repos with vulnerabilities:  ${YELLOW}%5d${NC}                |\n" "$repos_with_vulns"
    printf "+---------------------------------------------------+\n"
    printf "| ${CYAN}SCA (Dependency) Findings:${NC}                        |\n"
    printf "|   Critical:                  ${RED}%5d${NC}                |\n" "$sca_critical"
    printf "|   High:                      ${YELLOW}%5d${NC}                |\n" "$sca_high"
    printf "|   Medium:                    ${BLUE}%5d${NC}                |\n" "$sca_medium"
    printf "|   Low:                       %5d                |\n" "$sca_low"
    printf "+---------------------------------------------------+\n"
    printf "| ${CYAN}SAST (Code) Findings:${NC}                             |\n"
    printf "|   Critical:                  ${RED}%5d${NC}                |\n" "$sast_critical"
    printf "|   High:                      ${YELLOW}%5d${NC}                |\n" "$sast_high"
    printf "|   Medium:                    ${BLUE}%5d${NC}                |\n" "$sast_medium"
    printf "|   Low:                       %5d                |\n" "$sast_low"
    printf "${BOLD}+===================================================+${NC}\n"

    # Show repos with critical issues
    local critical_repos
    critical_repos=$(echo "$scans_json" | jq -r '[.[] | select(.sca_critical > 0 or .sast_critical > 0)] | unique_by(.repo) | .[].repo' 2>/dev/null || true)

    if [[ -n "$critical_repos" ]]; then
        printf "\n${RED}${BOLD}Repositories with Critical Issues:${NC}\n"
        printf "────────────────────────────────────────────────────\n"
        for repo in $critical_repos; do
            local repo_criticals
            repo_criticals=$(echo "$scans_json" | jq -r --arg r "$repo" '[.[] | select(.repo == $r)] | .[0] | "\(.sca_critical + .sast_critical) critical"' 2>/dev/null || echo "? critical")
            printf "${MAGENTA}%s${NC} (%s)\n" "$repo" "$repo_criticals"
        done
    fi

    if [[ "$total_vulns" -eq 0 ]]; then
        printf "\n${GREEN}All repositories clean - no vulnerabilities found${NC}\n"
    fi
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
            -s)
                STRICTNESS_FLAG="-s"
                shift
                ;;
            -S)
                STRICTNESS_FLAG="-S"
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

    # Check dependencies EARLY for fast fail
    check_dependencies

    # Check authentication
    check_snyk_auth

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
    result=$(analyze_single_repo "$REPO_PATH")

    # Parse result
    local scan_type total_vulns sca_critical sca_high sca_medium sca_low
    local sast_critical sast_high sast_medium sast_low sca_error sast_error
    local findings_json has_vulns

    IFS='|' read -r scan_type total_vulns \
        sca_critical sca_high sca_medium sca_low \
        sast_critical sast_high sast_medium sast_low \
        sca_error sast_error \
        findings_json has_vulns <<< "$result"

    # Record to guild database
    if [[ -n "$SIGIL" && -f "$GUILD_DB" ]]; then
        local insert_data
        insert_data=$(cat <<EOF
{"scan":{"sigil":"${SIGIL}","repo":"${repo_name}","scan_type":"${scan_type}","sca_critical":${sca_critical:-0},"sca_high":${sca_high:-0},"sca_medium":${sca_medium:-0},"sca_low":${sca_low:-0},"sast_critical":${sast_critical:-0},"sast_high":${sast_high:-0},"sast_medium":${sast_medium:-0},"sast_low":${sast_low:-0},"total_vulns":${total_vulns:-0},"sca_error":${sca_error:+\"$sca_error\"}${sca_error:-null},"sast_error":${sast_error:+\"$sast_error\"}${sast_error:-null}},"findings":${findings_json:-[]}}
EOF
)
        npx tsx "$GUILD_DB" insert-with-findings sentinel - <<< "$insert_data" >/dev/null 2>&1 || true
    fi

    # Output based on mode
    if [[ "$has_vulns" == "true" ]]; then
        # Has vulnerabilities
        if [[ "$DETAILS_ONLY" == true && "$NO_STDOUT" != true ]]; then
            output_details "$findings_json" "$PREFIX"
        fi
        exit 1
    fi

    # Clean - no vulnerabilities
    exit 0
}

main "$@"
