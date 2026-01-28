// Hook for read-only access to the guild.db SQLite database
// Uses bun:sqlite which is built-in to Bun runtime (no external dependency needed)

import { Database } from "bun:sqlite";
import { useState, useEffect, useCallback, useRef } from "react";
import { queries } from "../queries/runs";

// Path to guild.db relative to guild-hall directory
const DB_PATH = "../guild.db";

export interface ConclaveRun {
  sigil: string;
  started_at: string;
  ended_at: string | null;
  org_name: string | null;
  repo_count: number | null;
  repos_with_issues: number | null;
  total_files_scanned: number | null;
  members: string | null;
  dryrun: number | null;
}

export function useDatabase() {
  const dbRef = useRef<Database | null>(null);

  // Lazy initialization of database connection
  // Opens DB only when first query is executed, not on hook mount
  const getDb = useCallback(() => {
    if (!dbRef.current) {
      dbRef.current = new Database(DB_PATH, { readonly: true });
    }
    return dbRef.current;
  }, []);

  // Cleanup on unmount - ensures DB connection is properly closed
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
