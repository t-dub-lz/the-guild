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
