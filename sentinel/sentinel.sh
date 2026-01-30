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

# ═══════════════════════════════════════════════════════════════════════════════
# GUILD MEMBER SETUP
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source guild utilities
source "${SCRIPT_DIR}/../lib/guild-utils.sh"

# Initialize as guild member
guild_init "sentinel" "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# SENTINEL-SPECIFIC FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Check Snyk authentication using public CLI interface only
check_snyk_auth() {
    # Check SNYK_TOKEN environment variable first (CI/CD scenarios)
    if [[ -n "${SNYK_TOKEN:-}" ]]; then
        return 0
    fi

    # Check for API token via snyk config CLI
    local api_token
    api_token=$(snyk config get api 2>/dev/null || echo "")
    if [[ -n "$api_token" ]]; then
        return 0
    fi

    # Check for OAuth authentication via snyk config CLI
    local oauth_token
    oauth_token=$(snyk config get INTERNAL_OAUTH_TOKEN_STORAGE 2>/dev/null || echo "")
    if [[ -n "$oauth_token" ]]; then
        return 0
    fi

    # No authentication found
    guild_error "Snyk CLI not authenticated"
    if [[ "$GUILD_SILENT" != true ]]; then
        printf "Run 'snyk auth' to authenticate with Snyk\n" >&2
    fi
    exit 2
}

# Run SCA scan (snyk test) with optional spinner
# Returns: exit_code|critical|high|medium|low|findings_json|error_msg
run_sca_scan() {
    local repo_path="$1"
    local output_file="$GUILD_TEMP_DIR/sca_output.json"
    local exit_code_file="$GUILD_TEMP_DIR/sca_exit_code"
    local exit_code=0

    # Run snyk test in background with JSON output
    # Note: snyk returns 1 if vulnerabilities found (not an error!)
    (snyk test --json --all-projects "$repo_path" > "$output_file" 2>&1; echo $? > "$exit_code_file") &
    local scan_pid=$!

    # Show spinner while scan is running (unless silent)
    if [[ "$GUILD_SILENT" != true && "$GUILD_NO_STDOUT" != true ]]; then
        while kill -0 "$scan_pid" 2>/dev/null; do
            guild_show_spinner "Running SCA scan..."
            sleep 0.1
        done
        guild_clear_spinner
    fi

    wait "$scan_pid" 2>/dev/null || true
    exit_code=$(cat "$exit_code_file" 2>/dev/null || echo "0")

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

# Run SAST scan (snyk code test) with optional spinner
# Returns: exit_code|critical|high|medium|low|findings_json|error_msg
run_sast_scan() {
    local repo_path="$1"
    local output_file="$GUILD_TEMP_DIR/sast_output.json"
    local exit_code_file="$GUILD_TEMP_DIR/sast_exit_code"
    local exit_code=0

    # Run snyk code test in background with JSON output
    (snyk code test --json "$repo_path" > "$output_file" 2>&1; echo $? > "$exit_code_file") &
    local scan_pid=$!

    # Show spinner while scan is running (unless silent)
    if [[ "$GUILD_SILENT" != true && "$GUILD_NO_STDOUT" != true ]]; then
        while kill -0 "$scan_pid" 2>/dev/null; do
            guild_show_spinner "Running SAST scan..."
            sleep 0.1
        done
        guild_clear_spinner
    fi

    wait "$scan_pid" 2>/dev/null || true
    exit_code=$(cat "$exit_code_file" 2>/dev/null || echo "0")

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

    # Count by severity
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
    if [[ "$GUILD_STRICTNESS" == "-s" || "$GUILD_STRICTNESS" == "-S" ]]; then
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
    local total_repos repos_with_vulns total_vulns
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

    # Output summary using guild table utilities
    printf "\n"
    guild_table_header "Snyk Vulnerability Scan Summary"
    guild_table_row "Repositories scanned:" "$total_repos" "$BLUE"
    guild_table_row "Repos with vulnerabilities:" "$repos_with_vulns" "$YELLOW"
    guild_table_divider
    guild_table_section "SCA (Dependency) Findings:"
    guild_table_row "  Critical:" "$sca_critical" "$RED"
    guild_table_row "  High:" "$sca_high" "$YELLOW"
    guild_table_row "  Medium:" "$sca_medium" "$BLUE"
    guild_table_row "  Low:" "$sca_low"
    guild_table_divider
    guild_table_section "SAST (Code) Findings:"
    guild_table_row "  Critical:" "$sast_critical" "$RED"
    guild_table_row "  High:" "$sast_high" "$YELLOW"
    guild_table_row "  Medium:" "$sast_medium" "$BLUE"
    guild_table_row "  Low:" "$sast_low"
    guild_table_footer

    # Show repos with critical issues
    local critical_repos
    critical_repos=$(echo "$scans_json" | jq -r '[.[] | select(.sca_critical > 0 or .sast_critical > 0)] | unique_by(.repo) | .[].repo' 2>/dev/null || true)

    if [[ -n "$critical_repos" ]]; then
        printf "\n${RED}${BOLD}${XMARK} Repositories with Critical Issues:${NC}\n"
        printf "%s\n" "$(guild_make_separator 52 "─")"
        for repo in $critical_repos; do
            local repo_criticals
            repo_criticals=$(echo "$scans_json" | jq -r --arg r "$repo" '[.[] | select(.repo == $r)] | .[0] | "\(.sca_critical + .sast_critical) critical"' 2>/dev/null || echo "? critical")
            printf "${MAGENTA}%s${NC} (%s)\n" "$repo" "$repo_criticals"
        done
    fi

    if [[ "$total_vulns" -eq 0 ]]; then
        printf "\n${GREEN}${CHECKMARK} All repositories clean - no vulnerabilities found${NC}\n"
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
    guild_check_commands "snyk" "jq"

    # Check Snyk authentication
    check_snyk_auth

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
    result=$(analyze_single_repo "$GUILD_REPO_PATH")

    # Parse result
    local scan_type total_vulns sca_critical sca_high sca_medium sca_low
    local sast_critical sast_high sast_medium sast_low sca_error sast_error
    local findings_json has_vulns

    IFS='|' read -r scan_type total_vulns \
        sca_critical sca_high sca_medium sca_low \
        sast_critical sast_high sast_medium sast_low \
        sca_error sast_error \
        findings_json has_vulns <<< "$result"

    # Record to guild database using utility
    if [[ -n "$GUILD_SIGIL" ]]; then
        local scan_json
        scan_json=$(printf '{"sigil":"%s","repo":"%s","scan_type":"%s","sca_critical":%d,"sca_high":%d,"sca_medium":%d,"sca_low":%d,"sast_critical":%d,"sast_high":%d,"sast_medium":%d,"sast_low":%d,"total_vulns":%d,"sca_error":%s,"sast_error":%s}' \
            "$GUILD_SIGIL" "$repo_name" "$scan_type" \
            "${sca_critical:-0}" "${sca_high:-0}" "${sca_medium:-0}" "${sca_low:-0}" \
            "${sast_critical:-0}" "${sast_high:-0}" "${sast_medium:-0}" "${sast_low:-0}" \
            "${total_vulns:-0}" \
            "${sca_error:+\"$sca_error\"}${sca_error:-null}" \
            "${sast_error:+\"$sast_error\"}${sast_error:-null}")

        guild_record_scan "$scan_json" "${findings_json:-[]}"
    fi

    # Output based on mode
    if [[ "$has_vulns" == "true" ]]; then
        # Has vulnerabilities
        if [[ "$GUILD_DETAILS_ONLY" == true && "$GUILD_NO_STDOUT" != true ]]; then
            output_details "$findings_json" "$GUILD_PREFIX"
        fi
        exit 1
    fi

    # Clean - no vulnerabilities
    exit 0
}

main "$@"
