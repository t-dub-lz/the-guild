#!/usr/bin/env zsh

# Colors and symbols matching ascii-cutterman.ts style
CHECKMARK='✓'
XMARK='✗'
DOWN_RIGHT_ARROW="╰─>"

SUCCESS_COLOR=$'\e[32m'
FAIL_COLOR=$'\e[31m'
YELLOW_COLOR=$'\e[33m'
BLUE_COLOR=$'\e[34m'
MAGENTA_COLOR=$'\e[35m'
NEON_GREEN=$'\e[92m'
RESET_COLOR=$'\e[0m'

# Spinner animation frames (zsh arrays are 1-indexed)
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_INDEX=1

# Default configuration
REPO_LIMIT=10000  # Default limit for fetching all repos
ORG_NAME="legalzoom"  # Default organization
TEMP_DIR=$(mktemp -d)
MD_CLEANER="./ascii-cutterman.ts"
SCAN_ALL=false  # Default to scanning only .md and .txt files
PARALLEL_JOBS=10  # Default number of parallel jobs
STRICTNESS_FLAG=""  # Strictness flag to pass to ascii-cutterman (-s or -S)

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW_COLOR}Cleaning up...${RESET_COLOR}"

    # Kill xargs and all its children if it's running
    if [[ -n "$xargs_pid" ]] && kill -0 "$xargs_pid" 2>/dev/null; then
        # Kill the entire process group
        kill -- -$xargs_pid 2>/dev/null || true
        wait "$xargs_pid" 2>/dev/null || true
    fi

    # Kill clone process if it's running
    if [[ -n "$clone_pid" ]] && kill -0 "$clone_pid" 2>/dev/null; then
        kill "$clone_pid" 2>/dev/null || true
        wait "$clone_pid" 2>/dev/null || true
    fi

    # Clean up temp directory
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null

    exit 1
}

# Set up traps
trap cleanup INT TERM

# Help function
show_help() {
    echo "Usage: cutter-patrol [OPTIONS] [repo1,repo2,...]"
    echo ""
    echo "Scans GitHub repositories for problematic Unicode characters in text files."
    echo ""
    echo "Options:"
    echo "  -n <org>        Organization name (default: legalzoom)"
    echo "  -l <number>     Limit number of repos to fetch (default: 10000)"
    echo "  -j <number>     Number of parallel jobs (default: 10)"
    echo "  -a              Scan all non-binary files (default: only .md and .txt)"
    echo "  -s              Strict: also detect invisible formatting characters"
    echo "  -S              Super strict: also detect homoglyphs"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Arguments:"
    echo "  [repos]         Optional comma-separated list of repos (e.g., org/repo1,org/repo2)"
    echo "                  If not provided, fetches all repos from the specified organization"
    exit 0
}

# Parse arguments
REPO_LIST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -n)
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
        -a)
            SCAN_ALL=true
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
            # Assume it's the repo list
            REPO_LIST="$1"
            shift
            ;;
    esac
done

# Ensure ascii-cutterman exists
if [[ ! -f "$MD_CLEANER" ]]; then
    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} ascii-cutterman.ts not found in current directory"
    exit 1
fi

# Track overall stats
total_repos=0
repos_with_issues=0
total_files_scanned=0
declare -A repo_issues  # Associative array to store repo issues

# Get list of repositories
if [[ -n "$REPO_LIST" ]]; then
    # Use provided repo list
    IFS=',' read -A repo_array <<< "$REPO_LIST"
    repos=$(printf "%s\n" "${repo_array[@]}")
    echo "${BLUE_COLOR}Processing specified repositories...${RESET_COLOR}"
else
    # Fetch from GitHub org
    echo "${BLUE_COLOR}Fetching repositories from ${MAGENTA_COLOR}${ORG_NAME}${RESET_COLOR} (limit: ${REPO_LIMIT})...${RESET_COLOR}"
    repos=$(gh repo list "$ORG_NAME" --limit "$REPO_LIMIT" --archived=false --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null)
fi

if [[ -z "$repos" ]]; then
    echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} No repositories found or gh command failed"
    exit 1
fi

# Function to clear spinner line
clear_spinner() {
    printf "\r\033[K"
}

# Process each repository
while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    
    ((total_repos++))
    
    echo ""
    echo "${BLUE_COLOR}Processing repository: ${MAGENTA_COLOR}${repo}${RESET_COLOR}"

    # Save the original directory where ascii-cutterman is located
    ORIG_DIR="$PWD"

    # Clone the repository with spinner
    cd "$TEMP_DIR"

    # Start clone in background
    gh repo clone "$repo" -- --quiet 2>/dev/null &
    clone_pid=$!

    # Show spinner while cloning
    while kill -0 "$clone_pid" 2>/dev/null; do
        printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Checking out repository..."
        SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
        sleep 0.1
    done

    # Wait for clone to complete and check exit code
    wait "$clone_pid"
    clone_exit=$?

    # Clear spinner line
    clear_spinner

    if [[ $clone_exit -ne 0 ]]; then
        echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Failed to clone ${repo}"
        cd "$ORIG_DIR"
        continue
    fi
    
    # Extract repo name from nameWithOwner format
    repo_dir="${repo#*/}"
    cd "$repo_dir" 2>/dev/null || {
        echo "${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Failed to enter ${repo_dir}"
        cd "$TEMP_DIR"
        rm -rf "$repo_dir" 2>/dev/null
        cd "$ORIG_DIR"
        continue
    }
    
    # Find files to scan
    files=()
    if [[ "$SCAN_ALL" == "true" ]]; then
        # Find all non-binary files
        while IFS= read -r -d '' file; do
            # Use file command to check if it's a text file
            if file --mime "$file" 2>/dev/null | grep -q "text/"; then
                files+=("$file")
            fi
        done < <(find . -type f -print0 2>/dev/null)
    else
        # Find only .md and .txt files
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find . -type f \( -name "*.md" -o -name "*.txt" \) -print0 2>/dev/null)
    fi
    
    total_files=${#files[@]}
    ((total_files_scanned += total_files))

    if [[ $total_files -eq 0 ]]; then
        echo ""  # New line after repo name
        if [[ "$SCAN_ALL" == "true" ]]; then
            echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} No text files found"
        else
            echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} No .md or .txt files found"
        fi
        cd "$TEMP_DIR"
        rm -rf "$repo_dir"
        cd "$ORIG_DIR"
        continue
    fi
    
    # Check each file with ascii-cutterman in parallel
    problem_files=()
    declare -A file_issues  # Store issues for each file

    # Create temp file for results
    temp_results=$(mktemp)

    # Run parallel checks using xargs in background
    printf '%s\0' "${files[@]}" | xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c '
        exit_code=0
        "$1" $2 -nn "{}" 2>/dev/null || exit_code=$?

        if [[ $exit_code -eq 1 ]]; then
            # Get detailed issues
            issues=$("$1" $2 -d --prefix="    " "{}" 2>&1)
            # Output in parseable format: PROBLEM:file|||issues
            printf "PROBLEM:%s|||%s\n" "{}" "$issues"
        fi
    ' _ "$ORIG_DIR/$MD_CLEANER" "$STRICTNESS_FLAG" > "$temp_results" &

    # Get the PID of the background process
    xargs_pid=$!

    # Show spinner while xargs is running
    while kill -0 "$xargs_pid" 2>/dev/null; do
        printf "\r${NEON_GREEN}${SPINNER_FRAMES[$SPINNER_INDEX]}${RESET_COLOR} Scanning ${BLUE_COLOR}${total_files}${RESET_COLOR} files (${BLUE_COLOR}${PARALLEL_JOBS}${RESET_COLOR} at a time)..."
        # Update spinner index for 1-indexed array
        SPINNER_INDEX=$(( SPINNER_INDEX % ${#SPINNER_FRAMES[@]} + 1 ))
        sleep 0.1
    done

    # Wait for xargs to complete
    wait "$xargs_pid"

    # Clear the spinner line
    clear_spinner

    # Parse results
    while IFS= read -r line; do
        if [[ "$line" == PROBLEM:* ]]; then
            # Extract file and issues from the line
            rest="${line#PROBLEM:}"
            file="${rest%%|||*}"
            issues="${rest#*|||}"
            problem_files+=("$file")
            file_issues["$file"]="$issues"
        fi
    done < "$temp_results"

    # Clean up temp file
    rm -f "$temp_results"
    
    problem_count=${#problem_files[@]}
    
    # Report results for this repo (new line after processing)
    echo ""
    if [[ $problem_count -eq 0 ]]; then
        echo "${SUCCESS_COLOR}${CHECKMARK} SUCCESS:${RESET_COLOR} clean - ${BLUE_COLOR}${total_files}${RESET_COLOR} files checked, all clean"
    else
        ((repos_with_issues++))
        echo "${FAIL_COLOR}${XMARK} FAIL:${RESET_COLOR} naughty! - ${BLUE_COLOR}${problem_count}${RESET_COLOR} of ${BLUE_COLOR}${total_files}${RESET_COLOR} files have issues"
        echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Problematic files:"
        
        # Store issues for summary
        issue_list=""
        for pfile in "${problem_files[@]}"; do
            # Remove leading ./ if present
            display_file="${pfile#./}"
            echo "    ${MAGENTA_COLOR}${display_file}${RESET_COLOR}"
            
            # Show the issue details for this file
            if [[ -n "${file_issues["$pfile"]}" ]]; then
                echo "${file_issues["$pfile"]}"
            fi
            
            issue_list="${issue_list}${display_file}|"
        done
        # Store in associative array with count and file list
        repo_issues["$repo"]="${problem_count}:${issue_list%|}"
    fi
    
    # Clean up
    cd "$TEMP_DIR"
    rm -rf "$repo_dir"
    cd "$ORIG_DIR"
    
done <<< "$repos"

# Final summary
echo ""
echo "${BLUE_COLOR}════════════════════════════════════════${RESET_COLOR}"
echo "${BLUE_COLOR}FINAL SUMMARY${RESET_COLOR}"
echo "${BLUE_COLOR}════════════════════════════════════════${RESET_COLOR}"
echo ""
echo "${YELLOW_COLOR}Total repositories scanned:${RESET_COLOR} ${BLUE_COLOR}${total_repos}${RESET_COLOR}"
echo "${YELLOW_COLOR}Total files scanned:${RESET_COLOR} ${BLUE_COLOR}${total_files_scanned}${RESET_COLOR}"
echo "${YELLOW_COLOR}Repositories with issues:${RESET_COLOR} ${BLUE_COLOR}${repos_with_issues}${RESET_COLOR}"

if [[ $repos_with_issues -eq 0 ]]; then
    echo ""
    echo "${SUCCESS_COLOR}${CHECKMARK} All repositories are clean!${RESET_COLOR}"
else
    echo ""
    echo "${FAIL_COLOR}${XMARK} Repositories with issues:${RESET_COLOR}"
    echo ""
    
    # Sort and display repos with issues
    for repo in ${(k)repo_issues}; do
        IFS=':' read -r count files <<< "${repo_issues[$repo]}"
        # Remove quotes if present
        repo_name="${repo%\"}"
        repo_name="${repo_name#\"}"
        echo "${MAGENTA_COLOR}${repo_name}${RESET_COLOR} - ${BLUE_COLOR}${count}${RESET_COLOR} file(s) with issues:"
        
        # Split and display files
        IFS='|' read -A file_array <<< "$files"
        for file in "${file_array[@]}"; do
            echo "${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} ${file}"
        done
        echo ""
    done
fi

# Clean up temp directory
rm -rf "$TEMP_DIR" 2>/dev/null

# Exit with appropriate code
[[ $repos_with_issues -eq 0 ]] && exit 0 || exit 1
