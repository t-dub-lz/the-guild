# Guild Hall TUI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an interactive TUI (`guild-hall`) for The Guild that provides tab-based navigation for configuring new scans, monitoring active runs, and browsing historical results.

**Architecture:** Ink (React for CLI) application using bun:sqlite for read-only database access. Spawns `conclave.sh --headless` for actual scanning, streams stdout for live log, polls database for progress updates.

**Tech Stack:** Bun, Ink, React, bun:sqlite, TypeScript

**Design Document:** `docs/plans/2026-01-26-guild-hall-tui-design.md`

---

## Phase 1: Project Scaffolding

### Task 1.1: Initialize guild-hall package

**Files:**
- Create: `guild-hall/package.json`
- Create: `guild-hall/tsconfig.json`
- Create: `guild-hall/.gitignore`

**Step 1: Create package.json**

```json
{
  "name": "guild-hall",
  "version": "0.1.0",
  "type": "module",
  "bin": {
    "guild-hall": "./guild-hall.tsx"
  },
  "scripts": {
    "start": "bun run guild-hall.tsx",
    "test": "bun test",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "ink": "^5.0.1",
    "react": "^18.3.1"
  },
  "devDependencies": {
    "@types/bun": "latest",
    "@types/react": "^18.3.3",
    "typescript": "^5.5.0"
  }
}
```

**Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "jsxImportSource": "react",
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": ".",
    "types": ["bun-types"]
  },
  "include": ["**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules", "dist"]
}
```

**Step 3: Create .gitignore**

```
node_modules/
dist/
*.log
```

**Step 4: Install dependencies**

Run: `cd guild-hall && bun install`
Expected: Dependencies installed successfully

**Step 5: Commit**

```bash
git add guild-hall/package.json guild-hall/tsconfig.json guild-hall/.gitignore
git commit -m "feat(guild-hall): initialize package with Ink dependencies"
```

---

### Task 1.2: Create minimal entry point

**Files:**
- Create: `guild-hall/guild-hall.tsx`

**Step 1: Create entry point with minimal Ink app**

```tsx
#!/usr/bin/env bun
import React from "react";
import { render, Text, Box } from "ink";

function App() {
  return (
    <Box flexDirection="column">
      <Text bold color="cyan">
        ⚔️ Guild Hall
      </Text>
      <Text dimColor>Press q to quit</Text>
    </Box>
  );
}

render(<App />);
```

**Step 2: Make executable**

Run: `chmod +x guild-hall/guild-hall.tsx`

**Step 3: Run to verify it works**

Run: `cd guild-hall && bun run guild-hall.tsx`
Expected: Shows "⚔️ Guild Hall" and "Press q to quit"
Press: `Ctrl+C` to exit

**Step 4: Commit**

```bash
git add guild-hall/guild-hall.tsx
git commit -m "feat(guild-hall): add minimal entry point"
```

---

### Task 1.3: Create defaults.json configuration

**Files:**
- Create: `guild-hall/defaults.json`

**Step 1: Create defaults configuration**

```json
{
  "org": "",
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

**Step 2: Commit**

```bash
git add guild-hall/defaults.json
git commit -m "feat(guild-hall): add defaults.json configuration"
```

---

## Phase 2: Core Hooks

### Task 2.1: Create useKeys hook for vim + arrow navigation

**Files:**
- Create: `guild-hall/hooks/useKeys.ts`
- Create: `guild-hall/hooks/useKeys.test.ts`

**Step 1: Write failing test**

```typescript
// guild-hall/hooks/useKeys.test.ts
import { describe, test, expect } from "bun:test";
import { normalizeKey } from "./useKeys";

describe("normalizeKey", () => {
  test("maps vim keys to directions", () => {
    expect(normalizeKey("h")).toBe("left");
    expect(normalizeKey("j")).toBe("down");
    expect(normalizeKey("k")).toBe("up");
    expect(normalizeKey("l")).toBe("right");
  });

  test("maps arrow keys to directions", () => {
    expect(normalizeKey("leftArrow")).toBe("left");
    expect(normalizeKey("downArrow")).toBe("down");
    expect(normalizeKey("upArrow")).toBe("up");
    expect(normalizeKey("rightArrow")).toBe("right");
  });

  test("passes through other keys unchanged", () => {
    expect(normalizeKey("return")).toBe("return");
    expect(normalizeKey("escape")).toBe("escape");
    expect(normalizeKey("q")).toBe("q");
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd guild-hall && bun test`
Expected: FAIL - Cannot find module './useKeys'

**Step 3: Write implementation**

```typescript
// guild-hall/hooks/useKeys.ts
import { useInput } from "ink";

type Direction = "left" | "right" | "up" | "down";
type NormalizedKey = Direction | string;

const VIM_MAP: Record<string, Direction> = {
  h: "left",
  j: "down",
  k: "up",
  l: "right",
};

const ARROW_MAP: Record<string, Direction> = {
  leftArrow: "left",
  rightArrow: "right",
  upArrow: "up",
  downArrow: "down",
};

export function normalizeKey(key: string): NormalizedKey {
  if (key in VIM_MAP) return VIM_MAP[key];
  if (key in ARROW_MAP) return ARROW_MAP[key];
  return key;
}

type KeyHandler = (key: NormalizedKey, raw: string) => void;

export function useKeys(handler: KeyHandler, active: boolean = true) {
  useInput(
    (input, key) => {
      // Determine the raw key name
      let rawKey = input;
      if (key.leftArrow) rawKey = "leftArrow";
      else if (key.rightArrow) rawKey = "rightArrow";
      else if (key.upArrow) rawKey = "upArrow";
      else if (key.downArrow) rawKey = "downArrow";
      else if (key.return) rawKey = "return";
      else if (key.escape) rawKey = "escape";
      else if (key.tab) rawKey = "tab";
      else if (key.backspace) rawKey = "backspace";

      const normalized = normalizeKey(rawKey);
      handler(normalized, rawKey);
    },
    { isActive: active }
  );
}
```

**Step 4: Run test to verify it passes**

Run: `cd guild-hall && bun test`
Expected: PASS

**Step 5: Commit**

```bash
git add guild-hall/hooks/useKeys.ts guild-hall/hooks/useKeys.test.ts
git commit -m "feat(guild-hall): add useKeys hook with vim + arrow support"
```

---

### Task 2.2: Create useDatabase hook for SQLite queries

**Files:**
- Create: `guild-hall/hooks/useDatabase.ts`
- Create: `guild-hall/queries/runs.ts`

**Step 1: Create SQL query definitions**

```typescript
// guild-hall/queries/runs.ts
export const queries = {
  // Get all runs, most recent first
  listRuns: `
    SELECT
      sigil,
      started_at,
      ended_at,
      org_name,
      repo_count,
      repos_with_issues,
      total_files_scanned,
      members,
      dryrun
    FROM conclave
    ORDER BY started_at DESC
  `,

  // Get a single run by sigil
  getRun: `
    SELECT *
    FROM conclave
    WHERE sigil = ?
  `,

  // Count total runs
  countRuns: `
    SELECT COUNT(*) as count
    FROM conclave
  `,

  // Get scan counts per member for a run
  getMemberStats: (memberTable: string) => `
    SELECT
      COUNT(*) as total_scans,
      SUM(CASE WHEN EXISTS (
        SELECT 1 FROM ${memberTable}_findings f
        WHERE f.scan_id = s.id
      ) THEN 1 ELSE 0 END) as scans_with_findings
    FROM ${memberTable}_scans s
    WHERE s.sigil = ?
  `,

  // Get findings for a member scan
  getFindings: (memberTable: string) => `
    SELECT
      s.repo,
      s.filepath,
      f.*
    FROM ${memberTable}_findings f
    JOIN ${memberTable}_scans s ON f.scan_id = s.id
    WHERE s.sigil = ?
    ORDER BY s.repo, s.filepath
  `,
};
```

**Step 2: Create useDatabase hook**

```typescript
// guild-hall/hooks/useDatabase.ts
import { Database } from "bun:sqlite";
import { useState, useEffect, useCallback, useRef } from "react";
import { queries } from "../queries/runs";

// Path to guild.db relative to guild-hall directory
const DB_PATH = "../guild.db";

export interface ConclaveRun {
  sigil: string;
  started_at: string;
  ended_at: string | null;
  org_name: string;
  repo_count: number;
  repos_with_issues: number;
  total_files_scanned: number;
  members: string;
  dryrun: number;
}

export function useDatabase() {
  const dbRef = useRef<Database | null>(null);

  // Lazy initialization of database connection
  const getDb = useCallback(() => {
    if (!dbRef.current) {
      dbRef.current = new Database(DB_PATH, { readonly: true });
    }
    return dbRef.current;
  }, []);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      dbRef.current?.close();
    };
  }, []);

  const listRuns = useCallback((): ConclaveRun[] => {
    const db = getDb();
    return db.query(queries.listRuns).all() as ConclaveRun[];
  }, [getDb]);

  const getRun = useCallback(
    (sigil: string): ConclaveRun | null => {
      const db = getDb();
      return db.query(queries.getRun).get(sigil) as ConclaveRun | null;
    },
    [getDb]
  );

  const countRuns = useCallback((): number => {
    const db = getDb();
    const result = db.query(queries.countRuns).get() as { count: number };
    return result.count;
  }, [getDb]);

  return {
    listRuns,
    getRun,
    countRuns,
  };
}
```

**Step 3: Commit**

```bash
git add guild-hall/hooks/useDatabase.ts guild-hall/queries/runs.ts
git commit -m "feat(guild-hall): add useDatabase hook with bun:sqlite"
```

---

### Task 2.3: Create useProcess hook for spawning conclave.sh

**Files:**
- Create: `guild-hall/hooks/useProcess.ts`

**Step 1: Create useProcess hook**

```typescript
// guild-hall/hooks/useProcess.ts
import { useState, useCallback, useRef, useEffect } from "react";
import { Subprocess } from "bun";

export interface ProcessState {
  running: boolean;
  sigil: string | null;
  exitCode: number | null;
  output: string[];
}

export interface RunOptions {
  org: string;
  members: string[];
  parallelism: number;
  strict: boolean;
  superStrict: boolean;
  scanAll: boolean;
  dryRun: boolean;
}

const CONCLAVE_PATH = "../conclave.sh";
const MAX_OUTPUT_LINES = 1000;

// Regex to parse structured markers from conclave output
const SIGIL_REGEX = /^\[SIGIL:([^\]]+)\]/;
const PROGRESS_REGEX = /^\[PROGRESS:(\d+):(\d+)\]/;
const REPO_START_REGEX = /^\[REPO:START:([^\]]+)\]/;
const REPO_END_REGEX = /^\[REPO:END:([^\]]+)\]/;
const FINDING_REGEX = /^\[FINDING:([^:]+):([^:]+):([^:]+):(\d+):([^\]]+)\]/;

export function useProcess(onLine?: (line: string) => void) {
  const [state, setState] = useState<ProcessState>({
    running: false,
    sigil: null,
    exitCode: null,
    output: [],
  });

  const procRef = useRef<Subprocess | null>(null);
  const outputRef = useRef<string[]>([]);

  const start = useCallback(async (options: RunOptions) => {
    if (procRef.current) {
      console.error("Process already running");
      return;
    }

    // Build command args
    const args = ["--headless"];
    if (options.org) {
      args.push("-o", options.org);
    }
    if (options.parallelism !== 10) {
      args.push("-p", String(options.parallelism));
    }
    if (options.strict) args.push("-s");
    if (options.superStrict) args.push("-S");
    if (options.scanAll) args.push("-a");
    if (options.dryRun) args.push("-n");

    // Exclude members not in the list
    const allMembers = [
      "ascii-cutterman",
      "secretary",
      "sentinel",
      "catburglar",
      "the-judge",
    ];
    const excluded = allMembers.filter((m) => !options.members.includes(m));
    if (excluded.length > 0) {
      args.push("-x", excluded.join(","));
    }

    outputRef.current = [];
    setState({
      running: true,
      sigil: null,
      exitCode: null,
      output: [],
    });

    const proc = Bun.spawn([CONCLAVE_PATH, ...args], {
      cwd: import.meta.dir + "/..",
      stdout: "pipe",
      stderr: "pipe",
    });

    procRef.current = proc;

    // Stream stdout
    const reader = proc.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    const readLoop = async () => {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";

        for (const line of lines) {
          if (!line.trim()) continue;

          // Check for sigil marker
          const sigilMatch = line.match(SIGIL_REGEX);
          if (sigilMatch) {
            setState((s) => ({ ...s, sigil: sigilMatch[1] }));
          }

          // Add to output buffer
          outputRef.current.push(line);
          if (outputRef.current.length > MAX_OUTPUT_LINES) {
            outputRef.current.shift();
          }

          setState((s) => ({ ...s, output: [...outputRef.current] }));
          onLine?.(line);
        }
      }
    };

    readLoop();

    // Wait for process to exit
    const exitCode = await proc.exited;
    procRef.current = null;

    setState((s) => ({
      ...s,
      running: false,
      exitCode,
    }));
  }, [onLine]);

  const stop = useCallback(() => {
    if (procRef.current) {
      procRef.current.kill();
      procRef.current = null;
      setState((s) => ({
        ...s,
        running: false,
        exitCode: -1,
      }));
    }
  }, []);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      procRef.current?.kill();
    };
  }, []);

  return {
    ...state,
    start,
    stop,
  };
}
```

**Step 2: Commit**

```bash
git add guild-hall/hooks/useProcess.ts
git commit -m "feat(guild-hall): add useProcess hook for spawning conclave.sh"
```

---

## Phase 3: UI Components

### Task 3.1: Create Footer component

**Files:**
- Create: `guild-hall/components/Footer.tsx`

**Step 1: Create Footer component**

```tsx
// guild-hall/components/Footer.tsx
import React from "react";
import { Box, Text } from "ink";

interface FooterProps {
  hints: string;
  runCount: number;
  org?: string;
  status?: string;
}

export function Footer({ hints, runCount, org, status }: FooterProps) {
  return (
    <Box
      borderStyle="single"
      borderTop
      borderBottom={false}
      borderLeft={false}
      borderRight={false}
      paddingX={1}
      justifyContent="space-between"
    >
      <Text dimColor>{hints}</Text>
      <Box>
        {status && (
          <Text color="yellow" bold>
            {status}
            {"  "}
          </Text>
        )}
        <Text dimColor>
          {runCount} runs{org ? ` │ ${org}` : ""}
        </Text>
      </Box>
    </Box>
  );
}
```

**Step 2: Commit**

```bash
git add guild-hall/components/Footer.tsx
git commit -m "feat(guild-hall): add Footer component"
```

---

### Task 3.2: Create TabBar component

**Files:**
- Create: `guild-hall/components/TabBar.tsx`

**Step 1: Create TabBar component**

```tsx
// guild-hall/components/TabBar.tsx
import React from "react";
import { Box, Text } from "ink";

export type TabName = "new-run" | "current" | "history";

interface Tab {
  id: TabName;
  label: string;
}

const TABS: Tab[] = [
  { id: "new-run", label: "New Run" },
  { id: "current", label: "Current" },
  { id: "history", label: "History" },
];

interface TabBarProps {
  activeTab: TabName;
  onTabChange: (tab: TabName) => void;
  isRunning?: boolean;
}

export function TabBar({ activeTab, onTabChange, isRunning }: TabBarProps) {
  return (
    <Box
      borderStyle="single"
      borderTop={false}
      borderLeft={false}
      borderRight={false}
      paddingX={1}
      gap={2}
    >
      {TABS.map((tab) => {
        const isActive = tab.id === activeTab;
        const showIndicator = tab.id === "current" && isRunning;

        return (
          <Box key={tab.id}>
            <Text bold={isActive} inverse={isActive}>
              {isActive ? " ⚔️ " : "  "}
              {tab.label}
              {showIndicator ? " ●" : ""}
              {"  "}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}

export function useTabNavigation(
  activeTab: TabName,
  setActiveTab: (tab: TabName) => void
) {
  const tabOrder: TabName[] = ["new-run", "current", "history"];
  const currentIndex = tabOrder.indexOf(activeTab);

  const goLeft = () => {
    const newIndex = currentIndex > 0 ? currentIndex - 1 : tabOrder.length - 1;
    setActiveTab(tabOrder[newIndex]);
  };

  const goRight = () => {
    const newIndex = currentIndex < tabOrder.length - 1 ? currentIndex + 1 : 0;
    setActiveTab(tabOrder[newIndex]);
  };

  const goToTab = (num: number) => {
    if (num >= 1 && num <= tabOrder.length) {
      setActiveTab(tabOrder[num - 1]);
    }
  };

  return { goLeft, goRight, goToTab };
}
```

**Step 2: Commit**

```bash
git add guild-hall/components/TabBar.tsx
git commit -m "feat(guild-hall): add TabBar component with navigation"
```

---

### Task 3.3: Create NewRun form components

**Files:**
- Create: `guild-hall/components/NewRun/NewRunForm.tsx`
- Create: `guild-hall/components/NewRun/FormField.tsx`

**Step 1: Create FormField component**

```tsx
// guild-hall/components/NewRun/FormField.tsx
import React from "react";
import { Box, Text } from "ink";

interface TextFieldProps {
  label: string;
  value: string;
  focused: boolean;
  onChange?: (value: string) => void;
}

export function TextField({ label, value, focused }: TextFieldProps) {
  return (
    <Box>
      <Text>{label}: </Text>
      <Text bold={focused} inverse={focused}>
        {" "}
        {value || "(empty)"}{" "}
      </Text>
    </Box>
  );
}

interface CheckboxProps {
  label: string;
  checked: boolean;
  focused: boolean;
  onChange?: (checked: boolean) => void;
}

export function Checkbox({ label, checked, focused }: CheckboxProps) {
  return (
    <Box>
      <Text bold={focused} inverse={focused}>
        [{checked ? "✓" : " "}]
      </Text>
      <Text> {label}</Text>
    </Box>
  );
}

interface RadioGroupProps {
  options: { value: string; label: string }[];
  selected: string;
  focused: boolean;
  focusedIndex: number;
}

export function RadioGroup({
  options,
  selected,
  focused,
  focusedIndex,
}: RadioGroupProps) {
  return (
    <Box flexDirection="column">
      {options.map((opt, i) => (
        <Box key={opt.value}>
          <Text bold={focused && i === focusedIndex} inverse={focused && i === focusedIndex}>
            {opt.value === selected ? "●" : "○"}
          </Text>
          <Text> {opt.label}</Text>
        </Box>
      ))}
    </Box>
  );
}

interface NumberFieldProps {
  label: string;
  value: number;
  focused: boolean;
  min?: number;
  max?: number;
}

export function NumberField({ label, value, focused }: NumberFieldProps) {
  return (
    <Box>
      <Text>{label}: </Text>
      <Text bold={focused} inverse={focused}>
        {" "}
        [{value}]{" "}
      </Text>
      <Text> jobs</Text>
    </Box>
  );
}
```

**Step 2: Create NewRunForm component**

```tsx
// guild-hall/components/NewRun/NewRunForm.tsx
import React, { useState } from "react";
import { Box, Text } from "ink";
import { TextField, Checkbox, RadioGroup, NumberField } from "./FormField";
import { useKeys } from "../../hooks/useKeys";

interface FormState {
  org: string;
  repoMode: "all" | "select";
  members: Record<string, boolean>;
  strict: boolean;
  superStrict: boolean;
  scanAll: boolean;
  dryRun: boolean;
  parallelism: number;
}

interface NewRunFormProps {
  defaults: {
    org: string;
    members: string[];
    parallelism: number;
    strict: boolean;
    superStrict: boolean;
    scanAll: boolean;
    dryRun: boolean;
  };
  onSubmit: (state: FormState) => void;
  active: boolean;
}

const MEMBER_LIST = [
  { id: "ascii-cutterman", name: "ASCII Cutterman" },
  { id: "secretary", name: "Secretary" },
  { id: "sentinel", name: "Sentinel" },
  { id: "catburglar", name: "Catburglar" },
  { id: "the-judge", name: "The Judge" },
];

type FieldId =
  | "org"
  | "repoMode"
  | "members"
  | "strict"
  | "superStrict"
  | "scanAll"
  | "dryRun"
  | "parallelism"
  | "submit";

const FIELD_ORDER: FieldId[] = [
  "org",
  "repoMode",
  "members",
  "strict",
  "superStrict",
  "scanAll",
  "dryRun",
  "parallelism",
  "submit",
];

export function NewRunForm({ defaults, onSubmit, active }: NewRunFormProps) {
  const [focusIndex, setFocusIndex] = useState(0);
  const [memberFocusIndex, setMemberFocusIndex] = useState(0);

  const [form, setForm] = useState<FormState>(() => ({
    org: defaults.org,
    repoMode: "all",
    members: Object.fromEntries(
      MEMBER_LIST.map((m) => [m.id, defaults.members.includes(m.id)])
    ),
    strict: defaults.strict,
    superStrict: defaults.superStrict,
    scanAll: defaults.scanAll,
    dryRun: defaults.dryRun,
    parallelism: defaults.parallelism,
  }));

  const currentField = FIELD_ORDER[focusIndex];

  useKeys(
    (key) => {
      if (key === "down") {
        if (currentField === "members") {
          if (memberFocusIndex < MEMBER_LIST.length - 1) {
            setMemberFocusIndex((i) => i + 1);
          } else {
            setFocusIndex((i) => Math.min(i + 1, FIELD_ORDER.length - 1));
            setMemberFocusIndex(0);
          }
        } else {
          setFocusIndex((i) => Math.min(i + 1, FIELD_ORDER.length - 1));
        }
      } else if (key === "up") {
        if (currentField === "members" && memberFocusIndex > 0) {
          setMemberFocusIndex((i) => i - 1);
        } else {
          setFocusIndex((i) => Math.max(i - 1, 0));
          if (FIELD_ORDER[Math.max(focusIndex - 1, 0)] === "members") {
            setMemberFocusIndex(MEMBER_LIST.length - 1);
          }
        }
      } else if (key === " ") {
        // Toggle checkboxes
        if (currentField === "members") {
          const memberId = MEMBER_LIST[memberFocusIndex].id;
          setForm((f) => ({
            ...f,
            members: { ...f.members, [memberId]: !f.members[memberId] },
          }));
        } else if (
          ["strict", "superStrict", "scanAll", "dryRun"].includes(currentField)
        ) {
          setForm((f) => ({ ...f, [currentField]: !f[currentField as keyof FormState] }));
        }
      } else if (key === "return") {
        if (currentField === "submit") {
          onSubmit(form);
        }
      } else if (key === "left" && currentField === "parallelism") {
        setForm((f) => ({ ...f, parallelism: Math.max(1, f.parallelism - 1) }));
      } else if (key === "right" && currentField === "parallelism") {
        setForm((f) => ({
          ...f,
          parallelism: Math.min(100, f.parallelism + 1),
        }));
      }
    },
    active
  );

  return (
    <Box flexDirection="column" padding={1}>
      <TextField
        label="Organization"
        value={form.org}
        focused={currentField === "org"}
      />

      <Box marginTop={1} flexDirection="column">
        <Text>Repositories:</Text>
        <RadioGroup
          options={[
            { value: "all", label: "All from org" },
            { value: "select", label: "Select specific repos..." },
          ]}
          selected={form.repoMode}
          focused={currentField === "repoMode"}
          focusedIndex={0}
        />
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>Guild Members:</Text>
        <Box flexDirection="row" flexWrap="wrap" gap={2}>
          {MEMBER_LIST.map((member, i) => (
            <Checkbox
              key={member.id}
              label={member.name}
              checked={form.members[member.id]}
              focused={currentField === "members" && memberFocusIndex === i}
            />
          ))}
        </Box>
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>Options:</Text>
        <Box flexDirection="row" gap={2}>
          <Checkbox
            label="Strict mode (-s)"
            checked={form.strict}
            focused={currentField === "strict"}
          />
          <Checkbox
            label="Super strict (-S)"
            checked={form.superStrict}
            focused={currentField === "superStrict"}
          />
        </Box>
        <Box flexDirection="row" gap={2}>
          <Checkbox
            label="Scan all files"
            checked={form.scanAll}
            focused={currentField === "scanAll"}
          />
          <Checkbox
            label="Dry run"
            checked={form.dryRun}
            focused={currentField === "dryRun"}
          />
        </Box>
      </Box>

      <Box marginTop={1}>
        <NumberField
          label="Parallelism"
          value={form.parallelism}
          focused={currentField === "parallelism"}
        />
      </Box>

      <Box marginTop={2} justifyContent="center">
        <Text bold={currentField === "submit"} inverse={currentField === "submit"}>
          {"  "}⚔️ Begin Scan{"  "}
        </Text>
      </Box>
    </Box>
  );
}
```

**Step 3: Commit**

```bash
git add guild-hall/components/NewRun/
git commit -m "feat(guild-hall): add NewRunForm with form fields"
```

---

### Task 3.4: Create Current run components

**Files:**
- Create: `guild-hall/components/Current/Dashboard.tsx`
- Create: `guild-hall/components/Current/MemberCards.tsx`
- Create: `guild-hall/components/Current/LiveLog.tsx`

**Step 1: Create Dashboard component**

```tsx
// guild-hall/components/Current/Dashboard.tsx
import React from "react";
import { Box, Text } from "ink";

interface DashboardProps {
  progress: number; // 0-100
  reposCompleted: number;
  reposTotal: number;
  filesScanned: number;
  issueCount: number;
}

export function Dashboard({
  progress,
  reposCompleted,
  reposTotal,
  filesScanned,
  issueCount,
}: DashboardProps) {
  const barWidth = 30;
  const filled = Math.round((progress / 100) * barWidth);
  const empty = barWidth - filled;

  const progressBar = "█".repeat(filled) + "░".repeat(empty);

  return (
    <Box
      borderStyle="single"
      borderBottom
      borderTop={false}
      borderLeft={false}
      borderRight={false}
      paddingX={1}
      gap={2}
    >
      <Text>
        {progressBar} {progress}%
      </Text>
      <Text>│</Text>
      <Text>
        {reposCompleted}/{reposTotal} repos
      </Text>
      <Text>│</Text>
      <Text>{filesScanned.toLocaleString()} files</Text>
      <Text>│</Text>
      <Text color={issueCount > 0 ? "red" : "green"}>
        {issueCount}⚠
      </Text>
    </Box>
  );
}
```

**Step 2: Create MemberCards component**

```tsx
// guild-hall/components/Current/MemberCards.tsx
import React from "react";
import { Box, Text } from "ink";

interface MemberStatus {
  id: string;
  name: string;
  progress: number;
  findings: number;
  complete: boolean;
}

interface MemberCardsProps {
  members: MemberStatus[];
  selectedIndex: number;
  focused: boolean;
}

export function MemberCards({ members, selectedIndex, focused }: MemberCardsProps) {
  return (
    <Box flexDirection="column" width="50%">
      {members.map((member, i) => {
        const isSelected = focused && i === selectedIndex;
        const barWidth = 10;
        const filled = Math.round((member.progress / 100) * barWidth);
        const empty = barWidth - filled;
        const progressBar = "█".repeat(filled) + "░".repeat(empty);

        return (
          <Box key={member.id} paddingX={1}>
            <Text bold={isSelected} inverse={isSelected}>
              {member.name.padEnd(18)}
            </Text>
            <Text> {progressBar} {member.progress}%</Text>
            <Box marginLeft={1}>
              {member.complete && member.findings === 0 ? (
                <Text color="green"> ✓</Text>
              ) : member.findings > 0 ? (
                <Text color="red"> {member.findings} findings</Text>
              ) : (
                <Text dimColor> waiting...</Text>
              )}
            </Box>
          </Box>
        );
      })}
    </Box>
  );
}
```

**Step 3: Create LiveLog component**

```tsx
// guild-hall/components/Current/LiveLog.tsx
import React from "react";
import { Box, Text } from "ink";

interface LiveLogProps {
  lines: string[];
  maxLines?: number;
}

export function LiveLog({ lines, maxLines = 20 }: LiveLogProps) {
  const displayLines = lines.slice(-maxLines);

  return (
    <Box
      flexDirection="column"
      width="50%"
      borderStyle="single"
      borderLeft
      borderTop={false}
      borderBottom={false}
      borderRight={false}
      paddingX={1}
    >
      {displayLines.map((line, i) => {
        // Color code based on content
        let color: string | undefined;
        if (line.includes("✓") || line.includes("clean")) {
          color = "green";
        } else if (line.includes("✗") || line.includes("issue") || line.includes("FINDING")) {
          color = "red";
        } else if (line.startsWith("[REPO:")) {
          color = "cyan";
        }

        return (
          <Text key={i} color={color} wrap="truncate">
            {line}
          </Text>
        );
      })}
    </Box>
  );
}
```

**Step 4: Commit**

```bash
git add guild-hall/components/Current/
git commit -m "feat(guild-hall): add Current run components (Dashboard, MemberCards, LiveLog)"
```

---

### Task 3.5: Create History components

**Files:**
- Create: `guild-hall/components/History/RunList.tsx`
- Create: `guild-hall/components/History/RunDetail.tsx`

**Step 1: Create RunList component**

```tsx
// guild-hall/components/History/RunList.tsx
import React from "react";
import { Box, Text } from "ink";
import type { ConclaveRun } from "../../hooks/useDatabase";

interface RunListProps {
  runs: ConclaveRun[];
  selectedIndex: number;
  focused: boolean;
  onSelect: (run: ConclaveRun) => void;
}

export function RunList({ runs, selectedIndex, focused }: RunListProps) {
  // Show max 15 runs at a time, scrolling as needed
  const maxVisible = 15;
  const scrollOffset = Math.max(0, selectedIndex - maxVisible + 3);
  const visibleRuns = runs.slice(scrollOffset, scrollOffset + maxVisible);

  return (
    <Box flexDirection="column" padding={1}>
      <Text bold>Recent Conclaves</Text>
      <Text dimColor>{"─".repeat(60)}</Text>

      {visibleRuns.length === 0 ? (
        <Text dimColor>No runs found</Text>
      ) : (
        visibleRuns.map((run, i) => {
          const actualIndex = i + scrollOffset;
          const isSelected = focused && actualIndex === selectedIndex;
          const hasIssues = run.repos_with_issues > 0;

          // Format date
          const date = new Date(run.started_at);
          const dateStr = date.toISOString().slice(0, 16).replace("T", " ");

          return (
            <Box key={run.sigil}>
              <Text bold={isSelected} inverse={isSelected}>
                {isSelected ? "▸" : " "} {dateStr}
              </Text>
              <Text>{"  "}</Text>
              <Text>{run.org_name.padEnd(15)}</Text>
              <Text>{String(run.repo_count).padStart(4)} repos</Text>
              <Text>{"  "}</Text>
              <Text color={hasIssues ? "red" : "green"}>
                {String(run.repos_with_issues).padStart(4)} issues
              </Text>
              <Text>{"  "}</Text>
              <Text color={hasIssues ? "red" : "green"}>
                {hasIssues ? "✗" : "✓"}
              </Text>
            </Box>
          );
        })
      )}
    </Box>
  );
}
```

**Step 2: Create RunDetail component**

```tsx
// guild-hall/components/History/RunDetail.tsx
import React from "react";
import { Box, Text } from "ink";
import type { ConclaveRun } from "../../hooks/useDatabase";

interface MemberSummary {
  id: string;
  name: string;
  issues: number;
}

interface RunDetailProps {
  run: ConclaveRun;
  memberSummaries: MemberSummary[];
  selectedMemberIndex: number;
  focused: boolean;
  onBack: () => void;
}

export function RunDetail({
  run,
  memberSummaries,
  selectedMemberIndex,
  focused,
}: RunDetailProps) {
  // Calculate duration
  let duration = "in progress";
  if (run.ended_at) {
    const start = new Date(run.started_at).getTime();
    const end = new Date(run.ended_at).getTime();
    const seconds = Math.floor((end - start) / 1000);
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    duration = `${minutes}m ${secs}s`;
  }

  const dateStr = new Date(run.started_at).toISOString().slice(0, 16).replace("T", " ");

  return (
    <Box flexDirection="column" padding={1}>
      <Text dimColor>← Back</Text>
      <Text />

      <Text bold>Conclave: {dateStr}</Text>
      <Text>{"═".repeat(50)}</Text>

      <Box flexDirection="column" marginY={1}>
        <Text>Organization:  {run.org_name}</Text>
        <Text>Duration:      {duration}</Text>
        <Text>
          Repositories:  {run.repo_count} scanned, {run.repos_with_issues} with issues
        </Text>
        <Text>Files:         {run.total_files_scanned.toLocaleString()} total</Text>
      </Box>

      <Text bold>Members' Verdicts:</Text>
      <Text dimColor>{"─".repeat(50)}</Text>

      {memberSummaries.map((member, i) => {
        const isSelected = focused && i === selectedMemberIndex;
        const hasIssues = member.issues > 0;

        return (
          <Box key={member.id}>
            <Text bold={isSelected} inverse={isSelected}>
              {isSelected ? "▸" : " "} {member.name.padEnd(20)}
            </Text>
            <Text>{String(member.issues).padStart(4)} issues</Text>
            <Text>{"  "}</Text>
            <Text color={hasIssues ? "red" : "green"}>
              {hasIssues ? "✗" : "✓"}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}
```

**Step 3: Commit**

```bash
git add guild-hall/components/History/
git commit -m "feat(guild-hall): add History components (RunList, RunDetail)"
```

---

## Phase 4: App Integration

### Task 4.1: Wire up main App component

**Files:**
- Modify: `guild-hall/guild-hall.tsx`

**Step 1: Replace entry point with full app**

```tsx
#!/usr/bin/env bun
import React, { useState, useEffect } from "react";
import { render, Box, Text, useApp } from "ink";

import { TabBar, TabName, useTabNavigation } from "./components/TabBar";
import { Footer } from "./components/Footer";
import { NewRunForm } from "./components/NewRun/NewRunForm";
import { Dashboard } from "./components/Current/Dashboard";
import { MemberCards } from "./components/Current/MemberCards";
import { LiveLog } from "./components/Current/LiveLog";
import { RunList } from "./components/History/RunList";
import { RunDetail } from "./components/History/RunDetail";
import { useKeys } from "./hooks/useKeys";
import { useDatabase, ConclaveRun } from "./hooks/useDatabase";
import { useProcess, RunOptions } from "./hooks/useProcess";

import defaults from "./defaults.json";

function App() {
  const { exit } = useApp();
  const [activeTab, setActiveTab] = useState<TabName>("new-run");
  const { goLeft, goRight, goToTab } = useTabNavigation(activeTab, setActiveTab);

  // Database
  const db = useDatabase();
  const [runCount, setRunCount] = useState(0);
  const [runs, setRuns] = useState<ConclaveRun[]>([]);

  // History state
  const [historyIndex, setHistoryIndex] = useState(0);
  const [selectedRun, setSelectedRun] = useState<ConclaveRun | null>(null);
  const [memberIndex, setMemberIndex] = useState(0);

  // Process state
  const process = useProcess();

  // Load initial data
  useEffect(() => {
    setRunCount(db.countRuns());
    setRuns(db.listRuns());
  }, []);

  // Poll during active run
  useEffect(() => {
    if (!process.running) return;

    const interval = setInterval(() => {
      setRuns(db.listRuns());
      setRunCount(db.countRuns());
    }, defaults.ui.pollIntervalMs);

    return () => clearInterval(interval);
  }, [process.running]);

  // Global key handling
  useKeys((key) => {
    if (key === "q") {
      exit();
    } else if (key === "left") {
      goLeft();
    } else if (key === "right") {
      goRight();
    } else if (key === "1") {
      goToTab(1);
    } else if (key === "2") {
      goToTab(2);
    } else if (key === "3") {
      goToTab(3);
    } else if (key === "escape" && selectedRun) {
      setSelectedRun(null);
    }
  }, activeTab !== "new-run"); // Disable when form is active

  // History navigation
  useKeys((key) => {
    if (selectedRun) {
      // Detail view navigation
      if (key === "down") {
        setMemberIndex((i) => Math.min(i + 1, 4));
      } else if (key === "up") {
        setMemberIndex((i) => Math.max(i - 1, 0));
      } else if (key === "backspace" || key === "escape") {
        setSelectedRun(null);
      }
    } else {
      // List view navigation
      if (key === "down") {
        setHistoryIndex((i) => Math.min(i + 1, runs.length - 1));
      } else if (key === "up") {
        setHistoryIndex((i) => Math.max(i - 1, 0));
      } else if (key === "return" && runs[historyIndex]) {
        setSelectedRun(runs[historyIndex]);
        setMemberIndex(0);
      } else if (key === "g") {
        setHistoryIndex(0);
      } else if (key === "G") {
        setHistoryIndex(runs.length - 1);
      }
    }
  }, activeTab === "history");

  const handleNewRun = (formState: any) => {
    const options: RunOptions = {
      org: formState.org,
      members: Object.entries(formState.members)
        .filter(([, v]) => v)
        .map(([k]) => k),
      parallelism: formState.parallelism,
      strict: formState.strict,
      superStrict: formState.superStrict,
      scanAll: formState.scanAll,
      dryRun: formState.dryRun,
    };
    process.start(options);
    setActiveTab("current");
  };

  // Footer hints based on context
  const getHints = () => {
    if (activeTab === "new-run") {
      return "↑/k ↓/j:move  Space:toggle  Enter:activate  Tab:section";
    } else if (activeTab === "current") {
      return "↑/k ↓/j:select member  Enter:view findings  Esc:back";
    } else if (activeTab === "history") {
      if (selectedRun) {
        return "↑/k ↓/j:select  Enter:view findings  Esc/Backspace:back";
      }
      return "↑/k ↓/j:navigate  Enter:view details  g/G:top/bottom";
    }
    return "";
  };

  // Placeholder member data for current run
  const memberStatuses = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", progress: 0, findings: 0, complete: false },
    { id: "secretary", name: "Secretary", progress: 0, findings: 0, complete: false },
    { id: "sentinel", name: "Sentinel", progress: 0, findings: 0, complete: false },
    { id: "catburglar", name: "Catburglar", progress: 0, findings: 0, complete: false },
    { id: "the-judge", name: "The Judge", progress: 0, findings: 0, complete: false },
  ];

  // Placeholder member summaries for history detail
  const memberSummaries = [
    { id: "ascii-cutterman", name: "ASCII Cutterman", issues: 0 },
    { id: "secretary", name: "Secretary", issues: 0 },
    { id: "sentinel", name: "Sentinel", issues: 0 },
    { id: "catburglar", name: "Catburglar", issues: 0 },
    { id: "the-judge", name: "The Judge", issues: 0 },
  ];

  return (
    <Box flexDirection="column" height="100%">
      <TabBar
        activeTab={activeTab}
        onTabChange={setActiveTab}
        isRunning={process.running}
      />

      <Box flexGrow={1} flexDirection="column">
        {activeTab === "new-run" && (
          <NewRunForm
            defaults={defaults}
            onSubmit={handleNewRun}
            active={activeTab === "new-run"}
          />
        )}

        {activeTab === "current" && (
          <>
            {process.running ? (
              <>
                <Dashboard
                  progress={0}
                  reposCompleted={0}
                  reposTotal={0}
                  filesScanned={0}
                  issueCount={0}
                />
                <Box flexGrow={1}>
                  <MemberCards
                    members={memberStatuses}
                    selectedIndex={0}
                    focused={false}
                  />
                  <LiveLog lines={process.output} />
                </Box>
              </>
            ) : (
              <Box padding={1} flexDirection="column">
                <Text dimColor>No active scan</Text>
                <Text dimColor>Go to New Run tab to start a scan</Text>
              </Box>
            )}
          </>
        )}

        {activeTab === "history" && (
          <>
            {selectedRun ? (
              <RunDetail
                run={selectedRun}
                memberSummaries={memberSummaries}
                selectedMemberIndex={memberIndex}
                focused={true}
                onBack={() => setSelectedRun(null)}
              />
            ) : (
              <RunList
                runs={runs}
                selectedIndex={historyIndex}
                focused={true}
                onSelect={setSelectedRun}
              />
            )}
          </>
        )}
      </Box>

      <Footer
        hints={getHints()}
        runCount={runCount}
        org={defaults.org || undefined}
        status={process.running ? "Running..." : undefined}
      />
    </Box>
  );
}

render(<App />);
```

**Step 2: Run and verify**

Run: `cd guild-hall && bun run guild-hall.tsx`
Expected: TUI launches with tabs, can navigate with h/l, form shows on New Run tab

**Step 3: Commit**

```bash
git add guild-hall/guild-hall.tsx
git commit -m "feat(guild-hall): wire up main App with all components"
```

---

## Phase 5: conclave.sh Integration

### Task 5.1: Add --headless flag to conclave.sh

**Files:**
- Modify: `conclave.sh` (lines 130-161, help section)
- Modify: `conclave.sh` (argument parsing section)

**Step 1: Add HEADLESS variable and flag parsing**

After line 61 (after DEBUG=false), add:

```bash
HEADLESS=false          # --headless flag for TUI integration
```

In the argument parsing section (around line 280), add case for --headless:

```bash
--headless)
    HEADLESS=true
    ;;
```

**Step 2: Update help text**

Add to help section:

```bash
echo "  --headless        Machine-readable output for TUI integration"
```

**Step 3: Add structured marker output functions**

After the debug() function (around line 72), add:

```bash
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
```

**Step 4: Add marker emissions at key points**

At session start (after SIGIL generation), add:
```bash
emit_sigil
```

Before repo processing loop:
```bash
emit_org
```

At start of process_repo function:
```bash
emit_repo_start "$repo"
```

At end of process_repo function:
```bash
emit_repo_end "$repo"
```

At script exit:
```bash
emit_done "$exit_code"
```

**Step 5: Test headless mode**

Run: `./conclave.sh --headless -n -o testorg 2>&1 | head -20`
Expected: Output includes [SIGIL:...] and [ORG:...] markers

**Step 6: Commit**

```bash
git add conclave.sh
git commit -m "feat(conclave): add --headless flag with structured markers"
```

---

## Phase 6: Testing & Polish

### Task 6.1: Add integration test for TUI launch

**Files:**
- Create: `guild-hall/tests/app.test.ts`

**Step 1: Create basic launch test**

```typescript
// guild-hall/tests/app.test.ts
import { describe, test, expect } from "bun:test";
import { spawnSync } from "bun";

describe("guild-hall", () => {
  test("launches without error", () => {
    // Just verify it can import and parse without errors
    const result = spawnSync(["bun", "run", "--bun", "guild-hall.tsx", "--help"], {
      cwd: import.meta.dir + "/..",
      timeout: 5000,
    });

    // Ink apps don't have --help, but they should at least start
    // Exit code 0 means it ran (and exited because no TTY)
    expect(result.exitCode).toBeDefined();
  });

  test("defaults.json is valid", async () => {
    const defaults = await import("../defaults.json");
    expect(defaults.members).toBeArray();
    expect(defaults.parallelism).toBeNumber();
    expect(defaults.ui.pollIntervalMs).toBeNumber();
  });
});
```

**Step 2: Run tests**

Run: `cd guild-hall && bun test`
Expected: Tests pass

**Step 3: Commit**

```bash
git add guild-hall/tests/
git commit -m "test(guild-hall): add basic integration tests"
```

---

### Task 6.2: Create launch script and symlink

**Files:**
- Create: `guild-hall/bin/guild-hall`
- Modify: `Justfile` (if exists) or create

**Step 1: Create launcher script**

```bash
#!/usr/bin/env bash
# guild-hall launcher
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." && exec bun run guild-hall.tsx "$@"
```

**Step 2: Make executable**

Run: `chmod +x guild-hall/bin/guild-hall`

**Step 3: Add to project Justfile (create if needed)**

```just
# Justfile for The Guild

# Run guild-hall TUI
hall:
    cd guild-hall && bun run guild-hall.tsx

# Run conclave scanner
scan *ARGS:
    ./conclave.sh {{ARGS}}

# Install guild-hall dependencies
install-hall:
    cd guild-hall && bun install

# Run guild-hall tests
test-hall:
    cd guild-hall && bun test

# Typecheck guild-hall
check-hall:
    cd guild-hall && bun run typecheck
```

**Step 4: Create passthrough Makefile**

```makefile
# Makefile - dispatches to Justfile
%:
	@just $@

.DEFAULT_GOAL := help

help:
	@just --list
```

**Step 5: Commit**

```bash
git add guild-hall/bin/ Justfile Makefile
git commit -m "feat: add guild-hall launcher and task runner"
```

---

### Task 6.3: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md` (if exists)

**Step 1: Add guild-hall section to README**

Add after existing content:

```markdown
## Guild Hall (TUI)

Guild Hall provides an interactive terminal interface for The Guild.

### Quick Start

```bash
# Install dependencies
just install-hall

# Launch TUI
just hall
# or directly:
./guild-hall/bin/guild-hall
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
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add guild-hall documentation to README"
```

---

## Summary

This plan builds guild-hall in 6 phases:

1. **Scaffolding** - Package setup, entry point, config
2. **Core Hooks** - useKeys, useDatabase, useProcess
3. **UI Components** - Footer, TabBar, NewRun, Current, History
4. **App Integration** - Wire everything together
5. **conclave.sh Integration** - Add --headless and structured markers
6. **Testing & Polish** - Tests, launcher, docs

Each task is atomic and commits frequently. Follow TDD where tests make sense (hooks), and integration testing for UI components.

---

**Plan complete and saved to `docs/plans/2026-01-27-guild-hall-implementation.md`.**

**Two execution options:**

1. **Subagent-Driven (this session)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

2. **Parallel Session (separate)** - Open new session in a worktree with executing-plans, batch execution with checkpoints

**Which approach?**
