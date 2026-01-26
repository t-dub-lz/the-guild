# Guild Hall TUI Design

> A persistent, interactive terminal interface for The Guild of Aberrant Computation

**Date:** 2026-01-26
**Status:** Approved for implementation

---

## Overview

`guild-hall` is a standalone TUI application that provides interactive access to Guild scanning capabilities and historical run data. It complements the existing `conclave.sh` CLI, which remains unchanged for batch/CI usage.

### Goals

- **New runs:** Configure and launch scans with a visual form interface
- **Live monitoring:** Watch scan progress in real-time with per-member breakdown
- **Historical analysis:** Browse past runs and drill into findings

### Non-Goals

- Replacing `conclave.sh` (it remains the batch/headless workhorse)
- Reimplementing scan orchestration (guild-hall spawns conclave.sh)
- Supporting non-terminal interfaces (web UI, etc.)

---

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Runtime | Bun | Already in project, fast, native SQLite |
| UI Framework | Ink (React for CLI) | Component model fits hierarchical data |
| Database | bun:sqlite | Built-in, read-only access sufficient |
| Process | Bun.spawn | Stream stdout from conclave.sh |

---

## Architecture

```
guild-hall/
├── package.json          # Ink, React (bun:sqlite is built-in)
├── tsconfig.json
├── guild-hall.tsx        # Entry point
├── defaults.json         # User defaults (org, members, etc.)
├── components/
│   ├── App.tsx           # Root component, tab management
│   ├── TabBar.tsx        # [New Run] [Current] [History]
│   ├── Footer.tsx        # Keybindings + stats bar
│   ├── NewRun/
│   │   └── NewRunForm.tsx
│   ├── Current/
│   │   ├── Dashboard.tsx       # Single-line stats
│   │   ├── MemberCards.tsx     # Per-member progress
│   │   └── LiveLog.tsx         # Scrolling output
│   └── History/
│       ├── RunList.tsx
│       └── RunDetail.tsx
├── hooks/
│   ├── useDatabase.ts    # bun:sqlite queries (read-only)
│   ├── useKeys.ts        # Vim + arrow handling
│   └── useProcess.ts     # Spawns conclave.sh, streams output
└── queries/
    └── runs.ts           # SQL query definitions
```

### Key Architectural Decisions

1. **Reuses existing `guild.db`** - No schema changes needed
2. **Spawns `conclave.sh` as subprocess** - Doesn't reimplement orchestration
3. **Streams stdout** - Populates live log from process output
4. **Polls database** - Updates progress from scan/finding counts
5. **Read-only database access** - All writes go through conclave.sh

---

## Navigation Model

### Tab-Based Navigation

```
┌─────────────────────────────────────────────────────────────────────┐
│  [New Run]  [Current ⚔️]  [History]                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│                        (Tab Content Area)                           │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ ←/h →/l:tabs  ↑/k ↓/j:nav  Enter:select  q:quit │ 61 runs │ myorg  │
└─────────────────────────────────────────────────────────────────────┘
```

### Keybindings

| Key | Action |
|-----|--------|
| `h` / `←` | Previous tab |
| `l` / `→` | Next tab |
| `j` / `↓` | Navigate down in lists/forms |
| `k` / `↑` | Navigate up in lists/forms |
| `Enter` | Select/activate |
| `Space` | Toggle checkbox/radio |
| `Tab` | Jump between form sections |
| `Esc` | Back / return to tab bar |
| `q` | Quit (with confirmation if scan running) |
| `1` / `2` / `3` | Direct tab access |
| `g` | Jump to top of list |
| `G` | Jump to bottom of list |
| `/` | Search/filter (future) |
| `?` | Full help overlay |

### Visual Indicators

- **Bold/bright text** for all selected/current items
- **Fun emoji indicator** (e.g., `⚔️`) on active tab
- **`●`** on Current tab when scan is running
- **`✓`** (green) for clean/success states
- **`✗`** (red) for issues/failures

---

## Screen Designs

### New Run Tab

Single-form with all options visible, pre-populated from `defaults.json`:

```
┌─────────────────────────────────────────────────────────────────────┐
│  [New Run ⚔️]  [Current]  [History]                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Organization:  myorg                                               │
│                                                                     │
│  Repositories:  ● All from org                                      │
│                 ○ Select specific repos...                          │
│                                                                     │
│  Guild Members:                                                     │
│    [✓] ASCII Cutterman    [✓] Secretary                            │
│    [✓] Sentinel           [✓] Catburglar                           │
│    [✓] The Judge                                                    │
│                                                                     │
│  Options:                                                           │
│    [ ] Strict mode (-s)   [ ] Super strict (-S)                     │
│    [ ] Scan all files     [ ] Dry run                               │
│                                                                     │
│  Parallelism:  [10]  jobs                                           │
│                                                                     │
│            ┌──────────────────────┐                                 │
│            │   ⚔️  Begin Scan     │                                 │
│            └──────────────────────┘                                 │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ ↑/k ↓/j:move  Space:toggle  Enter:activate  Tab:section │ 61 runs  │
└─────────────────────────────────────────────────────────────────────┘
```

### Current Run Tab

Split-pane layout during active scan:

```
┌─────────────────────────────────────────────────────────────────────┐
│  [New Run]  [Current ⚔️]  [History]                                 │
├─────────────────────────────────────────────────────────────────────┤
│ ██████████████████░░░░░░░░░░ 63% │ 47/75 repos │ 1,842 files │ 12⚠ │
├────────────────────────────────────┬────────────────────────────────┤
│                                    │ myorg/api-service              │
│  ASCII Cutterman    ████████░░ 80% │   scanning auth/jwt.ts...      │
│    3 findings                      │   ✓ src/index.ts (clean)       │
│                                    │   ✗ src/utils.ts (2 issues)    │
│  Secretary          ██████████ 100%│ myorg/web-client               │
│    0 findings  ✓                   │   scanning components/Nav.tsx  │
│                                    │ myorg/shared-lib               │
│  Sentinel           ██████░░░░ 60% │   ✗ SNYK-JS-LODASH-1234        │
│    8 findings                      │   waiting for lock...          │
│                                    │ ──────────────────────────────│
│  Catburglar         ████░░░░░░ 40% │ [older output scrolls up]      │
│    1 finding                       │                                │
│                                    │                                │
│  The Judge          ░░░░░░░░░░ 0%  │                                │
│    waiting...                      │                                │
│                                    │                                │
├────────────────────────────────────┴────────────────────────────────┤
│ ↑/k ↓/j:select member  Enter:view findings  Esc:back │ Running...  │
└─────────────────────────────────────────────────────────────────────┘
```

**Components:**
- **Top bar:** Overall progress, repo count, file count, issue count
- **Left pane:** Per-member progress cards (selectable)
- **Right pane:** Streaming log output from conclave.sh

### History Tab

Chronological list of past runs:

```
┌─────────────────────────────────────────────────────────────────────┐
│  [New Run]  [Current]  [History ⚔️]                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Recent Conclaves                                                   │
│  ────────────────────────────────────────────────────────────────   │
│                                                                     │
│  ▸ 2026-01-26 14:32  myorg       75 repos   12 issues   ✗          │
│    2026-01-26 09:15  myorg       75 repos    0 issues   ✓          │
│    2026-01-25 16:45  other-org   23 repos    3 issues   ✗          │
│    2026-01-24 11:20  myorg       74 repos    0 issues   ✓          │
│    ...                                                              │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ ↑/k ↓/j:navigate  Enter:view details  /:search │ 61 runs │ myorg   │
└─────────────────────────────────────────────────────────────────────┘
```

### Run Detail View

Summary card when drilling into a historical run:

```
┌─────────────────────────────────────────────────────────────────────┐
│  ← Back                                                             │
│                                                                     │
│  Conclave: 2026-01-26 14:32                                         │
│  ══════════════════════════════════════════════════════════════     │
│  Organization:  myorg                                               │
│  Duration:      4m 32s                                              │
│  Repositories:  75 scanned, 8 with issues                           │
│  Files:         1,842 total                                         │
│                                                                     │
│  Members' Verdicts:                                                 │
│  ────────────────────────────────────────────────────────────────   │
│  ▸ ASCII Cutterman     3 issues   ✗                                │
│    Secretary           0 issues   ✓                                │
│    Sentinel            8 issues   ✗                                │
│    Catburglar          1 issue    ✗                                │
│    The Judge           0 issues   ✓                                │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ ↑/k ↓/j:select  Enter:view findings  Esc/Backspace:back │ 61 runs  │
└─────────────────────────────────────────────────────────────────────┘
```

### Findings Detail View

Per-member findings grouped by repo and file:

```
┌─────────────────────────────────────────────────────────────────────┐
│  ← Back to Conclave 2026-01-26                                      │
│                                                                     │
│  ASCII Cutterman Findings (3)                                       │
│  ══════════════════════════════════════════════════════════════     │
│                                                                     │
│  ▸ myorg/api-service                                               │
│    └─ src/utils.ts:42                                               │
│       Homoglyph detected: "а" (Cyrillic) replacing "a" (Latin)      │
│                                                                     │
│    └─ src/utils.ts:87                                               │
│       Invisible character: U+200B (zero-width space)                │
│                                                                     │
│  myorg/shared-lib                                                   │
│    └─ lib/helpers.js:15                                             │
│       Bidirectional text override detected                          │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ ↑/k ↓/j:navigate  Enter:open in editor  Esc:back │ 3 findings      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Process Integration

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                           guild-hall                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Ink/React UI                                                │   │
│  │    ↓ user clicks "Begin Scan"                               │   │
│  │    ↓                                                         │   │
│  │  useProcess hook                                             │   │
│  │    → spawns: conclave.sh -o myorg --headless                │   │
│  │    → captures stdout stream → LiveLog component             │   │
│  │    → watches exit code                                       │   │
│  │                                                              │   │
│  │  useDatabase hook (polling at configurable interval)        │   │
│  │    → SELECT from conclave WHERE sigil = ?                   │   │
│  │    → SELECT COUNT(*) from *_scans WHERE sigil = ?           │   │
│  │    → updates MemberCards, Dashboard                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  conclave.sh --headless                                      │   │
│  │    → writes to guild.db (scan records, findings)            │   │
│  │    → stdout: structured markers + progress messages         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  guild.db (SQLite with WAL mode)                            │   │
│  │    ← concurrent reads from guild-hall                       │   │
│  │    ← concurrent writes from conclave.sh                     │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Structured Output Markers

New markers for `conclave.sh` output (parseable by guild-hall):

```
[SIGIL:a1b2c3d4-5678-90ab-cdef]     # Run identifier, emitted at start
[ORG:myorg]                          # Organization being scanned
[REPO:START:myorg/api-service]       # Beginning repo scan
[REPO:END:myorg/api-service]         # Finished repo scan
[FILE:myorg/api-service:src/foo.ts]  # Currently scanning file
[MEMBER:ascii-cutterman:START]       # Member beginning work
[MEMBER:ascii-cutterman:END]         # Member finished
[FINDING:ascii-cutterman:myorg/api-service:src/foo.ts:42:homoglyph]
[PROGRESS:47:75]                     # repos completed : total
[DONE:0]                             # Exit code
```

**Benefits:**
- Faster UI updates (stdout is immediate vs DB write batching)
- LiveLog can syntax-highlight or filter by marker type
- Backwards compatible (markers are human-readable)
- Fallback: works via DB polling alone if markers missing

---

## Configuration

### `defaults.json`

```json
{
  "org": "myorg",
  "members": [
    "ascii-cutterman",
    "secretary",
    "sentinel",
    "catburglar",
    "the-judge"
  ],
  "parallelism": 10,
  "strict": false,
  "superStrict": false,
  "scanAll": false,
  "dryRun": false,
  "ui": {
    "pollIntervalMs": 500,
    "logBufferLines": 1000,
    "theme": "default"
  }
}
```

---

## Changes to conclave.sh

1. **Add `--headless` flag** - Suppresses interactive formatting, keeps structured output
2. **Emit structured markers** - As defined above, interspersed with normal output
3. **Print sigil at startup** - `[SIGIL:...]` line for guild-hall to capture

---

## Future Enhancements (Not in Scope)

- Search/filter in history list (`/` key stubbed)
- Theming support (`ui.theme` in config)
- Open findings in `$EDITOR`
- Compare runs side-by-side
- Export reports (JSON, HTML, etc.)

---

## Summary

`guild-hall` provides a rich, interactive interface to The Guild while preserving `conclave.sh` for batch operations. The tab-based navigation with vim keybindings offers efficient access to all three primary workflows: configuring new runs, monitoring active scans, and analyzing historical results.
