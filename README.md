# The Guild of Aberrant Computation

A multi-tool code scanning framework that scans repositories and applies
various specialized scanning tools ("Guild Members") to them.

## Quick Start

```bash
# Scan all repos in an org
./conclave.zsh -n myorg

# Scan specific repos
./conclave.zsh org/repo1,org/repo2

# Scan with 20 parallel jobs
./conclave.zsh -n myorg -j 20
```

## Usage

```
conclave.zsh [OPTIONS] [repo1,repo2,...]

Options:
  -n <org>      Organization name (default: legalzoom)
  -l <number>   Limit number of repos to fetch (default: 10000)
  -j <number>   Number of parallel jobs (default: 10)
  -a            Scan all text files (overrides per-tool config)
  -s            Strict mode (passed to tools that support it)
  -S            Super strict mode
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
  tool-name.sh   # or .ts, .py, .js, .zsh - executable with same name as folder
  config.json    # tool configuration
```

The main executable must have the same name as its containing folder. Extensions
supported: `.sh`, `.zsh`, `.ts`, `.py`, `.js`, or no extension.

### Tool Config (config.json)

Each tool requires a `config.json` file:

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

### Tool Interface

Tools receive a file path as the first argument and should:
- Exit `0` if the file is clean / passes inspection
- Exit `1` if the file has issues
- Support `-nn` flag for quiet mode (no output, just exit code)
- Support `-d` flag for detailed output
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

### Secretary

Reports file statistics (lines, words, characters). A simple demonstration
tool showing the multi-tool architecture.

**Patterns**: All text files (`scanAllText: true`)

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

3. Create `config.json`:
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

- `zsh` - Shell interpreter
- `gh` - GitHub CLI (for repo listing and cloning)
- `jq` or `python3` - For parsing config.json
- Tool-specific dependencies (e.g., `bun` for TypeScript tools)
