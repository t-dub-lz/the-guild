# The Guild of Aberrant Computation

A multi-tool code scanning framework that scans repositories and applies
various specialized scanning tools ("Guild Members") to them.

## Quick Start

```bash
# Check system dependencies
make setup

# Install project dependencies (lib + guild-hall)
make install

# Scan all your own GitHub repos (default)
make conclave

# Scan all repos in an org
make conclave ARGS="-o myorg"

# Scan specific repos
make conclave ARGS="org/repo1,org/repo2"

# Scan with 20 parallel jobs
make conclave ARGS="-o myorg -j 20"

# Launch the Guild Hall TUI
make hall
```

## Usage

```
conclave.sh [OPTIONS] [repo1,repo2,...]

Options:
  -o <org>      Organization name (default: your GitHub user)
  -l <number>   Limit number of repos to fetch (default: 10000)
  -j <number>   Number of parallel jobs (default: 10)
  -a            Scan all text files (overrides per-tool config)
  -s            Strict mode (passed to tools that support it)
  -S            Super strict mode
  -n            Dry-run / training mode (counts files only)
  -h, --help    Show help

Arguments:
  [repos]       Comma-separated list of repos (e.g., org/repo1,org/repo2)
                If omitted, fetches all repos from the organization
```

## Architecture

### Guild Members (Tools)

Each subdirectory is a "Guild Member" - a scanning tool. The convention:

```
tool-name/
  tool-name.sh   # or .ts, .py, .js - executable with same name as folder
  config.jsonc   # tool configuration in JSONC format
```

The main executable must have the same name as its containing folder. Extensions
supported: `.sh`, `.ts`, `.py`, `.js`, or no extension.

### Tool Config (config.jsonc)

Each tool requires a `config.jsonc` file:

```json
{
  "name": "Human-readable name",
  "description": "What this tool does",
  "patterns": ["*.md", "*.txt"],
  "scanAllText": false
}
```

| Field | Description |
|-------|-------------|
| `name` | Display name shown in output |
| `description` | Brief description of the tool |
| `patterns` | Array of glob patterns for files to scan |
| `scanAllText` | If `true`, scans all text files (ignores patterns) |
| `repositoryScope` | If `true`, operates per-repo instead of per-file |

### Tool Interface

Tools receive a file path as the first argument and should:
- Exit `0` if the file is clean / passes inspection
- Exit `1` if the file has issues
- Exit `2` to indicate that the tool itself encountered an error
- Support `-n` flag for no output to stdout, only stderr
- Support `-nn` flag for no output at all (to either stdout or stderr)
- Support `-d` flag for details ONLY (omitting header/footer output that might
  happen in "regular" standalone operation)
- Support `--prefix="..."` for indented output

### Repository Cache (.repos/)

Repositories are cached locally in `.repos/` for faster subsequent scans:

```
.repos/
  org-name/
    repo-name/   # git working copy
```

- **First run**: Clones repositories
- **Subsequent runs**: Pulls latest changes from default branch
- **Orphaned repos**: If a repo is deleted from remote, it's flagged but preserved locally

The `.repos/` directory is git-ignored except for its README.

## Current Guild Members

### ASCII Cutterman

Detects Unicode smuggling, invisible formatting characters, and homoglyphs
in text files. Useful for finding:
- Unicode tag characters (steganography)
- Zero-width spaces and invisible formatting
- Cyrillic/Latin homoglyph substitutions

**Patterns**: `*.md`, `*.txt`

### Catburglar

Analyzes GitHub PRs for Snyk check failures. Operates at the repository
level via GitHub API calls to identify PRs blocked by failing security checks.

**Scope**: Repository-level (no file patterns)

### Secretary

Flags files exceeding 5,000 lines of code. Useful for identifying overly
large files that may need refactoring.

**Patterns**: All text files (`scanAllText: true`)

### Sentinel

Runs Snyk vulnerability scans (SCA and optionally SAST) on repositories.
Reports critical, high, medium, and low severity vulnerabilities with
upgrade path information.

**Scope**: Repository-level (no file patterns)

### The Judge

Analyzes AI agent instruction files (CLAUDE.md, .cursorrules, AGENTS.md,
copilot-instructions.md, etc.) for security issues, verbosity, and clarity
using OpenAI. Covers instruction files for all major AI coding assistants.

**Patterns**: AI agent instruction files across all major tools

## Adding a New Tool

1. Create a folder with your tool name:
   ```bash
   mkdir my-tool
   ```

2. Add an executable with the same name:
   ```bash
   touch my-tool/my-tool.sh
   chmod +x my-tool/my-tool.sh
   ```

3. Create `config.jsonc`:
   ```json
   {
     "name": "My Tool",
     "description": "Does something useful",
     "patterns": ["*.js", "*.ts"],
     "scanAllText": false
   }
   ```

4. Implement the tool interface:
   - Accept file path as `$1`
   - Exit `0` for clean, `1` for issues
   - Support `-nn` (quiet) and `-d` (detailed) flags

## Dependencies

- `bash` - Shell interpreter
- `bun` - TypeScript runtime and package manager
- `gh` - GitHub CLI (for repo listing and cloning)
- `jq` - JSON processor (for parsing config.jsonc)
- `parallel` - GNU Parallel (for concurrent repo processing)
- `bc` - Calculator (for parallelism heuristics)

Run `make setup` to verify all dependencies are present.

## Guild Hall (TUI)

Guild Hall provides an interactive terminal interface for The Guild.

### Quick Start

```bash
# Install all dependencies
make install

# Launch TUI
make hall
```

### Features

- **New Run**: Configure and launch scans with visual form
- **Current**: Monitor active scans with live progress
- **History**: Browse past runs and drill into findings

### Navigation

| Key | Action |
|-----|--------|
| `h/←` `l/→` | Switch tabs |
| `j/↓` `k/↑` | Navigate lists/forms |
| `Enter` | Select/activate |
| `Space` | Toggle checkbox |
| `Esc` | Go back |
| `q` | Quit |
| `1` `2` `3` | Jump to tab |
