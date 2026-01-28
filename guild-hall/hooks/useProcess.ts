// guild-hall/hooks/useProcess.ts
import { useState, useCallback, useRef, useEffect } from "react";
import { Subprocess } from "bun";
import { resolve, dirname } from "path";

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

// Resolve paths relative to this file's location (hooks/useProcess.ts)
// import.meta.dir = guild-hall/hooks
// One level up = guild-hall
// Two levels up = the-guild (project root where conclave.sh lives)
const HOOKS_DIR = import.meta.dir;  // guild-hall/hooks
const GUILD_HALL_DIR = dirname(HOOKS_DIR);  // guild-hall
const PROJECT_ROOT = dirname(GUILD_HALL_DIR);  // the-guild
const CONCLAVE_PATH = resolve(PROJECT_ROOT, "conclave.sh");
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

    try {
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

    // Verify script exists before spawning
    const scriptFile = Bun.file(CONCLAVE_PATH);
    if (!await scriptFile.exists()) {
      throw new Error(`conclave.sh not found at ${CONCLAVE_PATH}`);
    }

    const proc = Bun.spawn([CONCLAVE_PATH, ...args], {
      cwd: PROJECT_ROOT,
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

    // Also stream stderr for error messages
    const stderrReader = proc.stderr.getReader();
    const readStderr = async () => {
      while (true) {
        const { done, value } = await stderrReader.read();
        if (done) break;
        const text = decoder.decode(value, { stream: true });
        for (const line of text.split("\n")) {
          if (line.trim()) {
            outputRef.current.push(`[stderr] ${line}`);
            setState((s) => ({ ...s, output: [...outputRef.current] }));
          }
        }
      }
    };
    readStderr();

    // Wait for process to exit
    const exitCode = await proc.exited;
    procRef.current = null;

    setState((s) => ({
      ...s,
      running: false,
      exitCode,
    }));
    } catch (err) {
      // Log error to output so it's visible in the TUI
      const errorMsg = `[ERROR] Failed to start process: ${err}`;
      outputRef.current.push(errorMsg);
      setState((s) => ({
        ...s,
        running: false,
        exitCode: -1,
        output: [...outputRef.current],
      }));
    }
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
