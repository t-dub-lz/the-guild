#!/usr/bin/env -S npx tsx

import Database from 'better-sqlite3';
import { readFileSync, existsSync, readSync } from 'fs';
import { join, dirname } from 'path';
import { argv, exit, stdout, stderr } from 'process';

// Read all data from stdin synchronously (fd 0)
function readStdin(): string {
  const BUFSIZE = 65536;
  let data = '';
  const buf = Buffer.alloc(BUFSIZE);
  let bytesRead: number;
  try {
    // Read from file descriptor 0 (stdin) directly
    while ((bytesRead = readSync(0, buf, 0, BUFSIZE, null)) > 0) {
      data += buf.toString('utf8', 0, bytesRead);
    }
  } catch {
    // End of input or stdin not available
  }
  return data;
}

// ═══════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

const SCRIPT_DIR = dirname(new URL(import.meta.url).pathname);
const PROJECT_ROOT = dirname(SCRIPT_DIR);
const DB_PATH = join(PROJECT_ROOT, 'guild.db');

// Terminal formatting
const SUCCESS_COLOR = '\x1b[32m';
const FAIL_COLOR = '\x1b[31m';
const CYAN_COLOR = '\x1b[36m';
const RESET_COLOR = '\x1b[0m';
const CHECKMARK = '\u2713';
const XMARK = '\u2717';

// ═══════════════════════════════════════════════════════════════════════════
// TYPE DEFINITIONS
// ═══════════════════════════════════════════════════════════════════════════

interface ColumnDefinition {
  name: string;
  type: 'TEXT' | 'INTEGER' | 'REAL';
  required: boolean;
  default?: string | number;
  description?: string;
}

interface TableSchema {
  tableName: string;
  columns: ColumnDefinition[];
  indexes?: string[];
}

interface DbSchema {
  scans: TableSchema;
  findings?: TableSchema;
}

interface MemberConfig {
  name: string;
  dbSchema?: DbSchema;
}

interface ConclaveStartData {
  members: string[];
  excluded_members?: string[];
  org_name?: string;
  repo_limit?: number;
  strictness_flag?: string;
  scan_all_override?: boolean;
  dryrun?: boolean;
}

interface ConclaveEndData {
  repo_count: number;
  repos_with_issues: number;
  total_files_scanned: number;
}

interface InsertWithFindingsData {
  scan: Record<string, unknown>;
  findings?: Record<string, unknown>[];
}

// ═══════════════════════════════════════════════════════════════════════════
// DATABASE HELPERS
// ═══════════════════════════════════════════════════════════════════════════

function getDb(): Database.Database {
  const db = new Database(DB_PATH);
  db.pragma('foreign_keys = ON');
  return db;
}

// ═══════════════════════════════════════════════════════════════════════════
// DATABASE INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════

function initDatabase(): void {
  const db = getDb();

  // Create conclave table
  db.exec(`
    CREATE TABLE IF NOT EXISTS conclave (
      sigil TEXT PRIMARY KEY,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      org_name TEXT,
      repo_limit INTEGER,
      strictness_flag TEXT,
      scan_all_override INTEGER DEFAULT 0,
      dryrun INTEGER DEFAULT 0,
      members TEXT NOT NULL,
      excluded_members TEXT,
      repo_count INTEGER DEFAULT 0,
      repos_with_issues INTEGER DEFAULT 0,
      total_files_scanned INTEGER DEFAULT 0
    );
  `);

  // Create indexes
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_conclave_started_at ON conclave(started_at);
    CREATE INDEX IF NOT EXISTS idx_conclave_org_name ON conclave(org_name);
  `);

  db.close();
}

// ═══════════════════════════════════════════════════════════════════════════
// SCHEMA OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════

function stripJsoncComments(content: string): string {
  // Remove single-line comments
  let result = content.replace(/\/\/.*$/gm, '');
  // Remove multi-line comments
  result = result.replace(/\/\*[\s\S]*?\*\//g, '');
  return result;
}

function createTableFromSchema(db: Database.Database, schema: TableSchema, isScansTable: boolean): void {
  // Build column definitions
  const columns: string[] = [
    'id INTEGER PRIMARY KEY AUTOINCREMENT',
  ];

  if (isScansTable) {
    // Scans tables get sigil FK and created_at
    columns.push('sigil TEXT NOT NULL REFERENCES conclave(sigil) ON DELETE CASCADE');
  } else {
    // Findings tables get scan_id FK
    columns.push(`scan_id INTEGER NOT NULL REFERENCES ${schema.tableName.replace('_findings', '_scans')}(id) ON DELETE CASCADE`);
  }

  // Add user-defined columns
  for (const col of schema.columns) {
    let def = `${col.name} ${col.type}`;
    if (col.required) def += ' NOT NULL';
    if (col.default !== undefined) {
      if (typeof col.default === 'string') {
        def += ` DEFAULT '${col.default}'`;
      } else {
        def += ` DEFAULT ${col.default}`;
      }
    }
    columns.push(def);
  }

  if (isScansTable) {
    columns.push('created_at TEXT DEFAULT CURRENT_TIMESTAMP');
  }

  const createSql = `
    CREATE TABLE IF NOT EXISTS ${schema.tableName} (
      ${columns.join(',\n      ')}
    );
  `;

  db.exec(createSql);

  // Create indexes
  if (isScansTable) {
    db.exec(`CREATE INDEX IF NOT EXISTS idx_${schema.tableName}_sigil ON ${schema.tableName}(sigil);`);
  } else {
    db.exec(`CREATE INDEX IF NOT EXISTS idx_${schema.tableName}_scan_id ON ${schema.tableName}(scan_id);`);
  }

  if (schema.indexes) {
    for (const indexCol of schema.indexes) {
      db.exec(`CREATE INDEX IF NOT EXISTS idx_${schema.tableName}_${indexCol} ON ${schema.tableName}(${indexCol});`);
    }
  }
}

function registerMemberSchema(memberDir: string): void {
  const configPath = join(memberDir, 'config.jsonc');
  if (!existsSync(configPath)) {
    throw new Error(`Config not found: ${configPath}`);
  }

  const content = readFileSync(configPath, 'utf-8');
  const jsonContent = stripJsoncComments(content);

  let config: MemberConfig;
  try {
    config = JSON.parse(jsonContent);
  } catch (e) {
    throw new Error(`Failed to parse config: ${configPath}`);
  }

  if (!config.dbSchema) {
    stderr.write(`${CYAN_COLOR}Note:${RESET_COLOR} No dbSchema in ${configPath}, skipping\n`);
    return;
  }

  const db = getDb();

  // Create scans table
  createTableFromSchema(db, config.dbSchema.scans, true);

  // Create findings table if defined
  if (config.dbSchema.findings) {
    createTableFromSchema(db, config.dbSchema.findings, false);
  }

  db.close();
}

// ═══════════════════════════════════════════════════════════════════════════
// CONCLAVE OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════

function startConclave(sigil: string, data: ConclaveStartData): void {
  const db = getDb();
  const stmt = db.prepare(`
    INSERT INTO conclave (sigil, started_at, members, excluded_members, org_name, repo_limit, strictness_flag, scan_all_override, dryrun)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  stmt.run(
    sigil,
    new Date().toISOString(),
    JSON.stringify(data.members),
    data.excluded_members ? JSON.stringify(data.excluded_members) : null,
    data.org_name || null,
    data.repo_limit || null,
    data.strictness_flag || null,
    data.scan_all_override ? 1 : 0,
    data.dryrun ? 1 : 0
  );
  db.close();
}

function endConclave(sigil: string, stats: ConclaveEndData): void {
  const db = getDb();
  const stmt = db.prepare(`
    UPDATE conclave
    SET ended_at = ?, repo_count = ?, repos_with_issues = ?, total_files_scanned = ?
    WHERE sigil = ?
  `);
  stmt.run(
    new Date().toISOString(),
    stats.repo_count,
    stats.repos_with_issues,
    stats.total_files_scanned,
    sigil
  );
  db.close();
}

// ═══════════════════════════════════════════════════════════════════════════
// DATA INSERTION
// ═══════════════════════════════════════════════════════════════════════════

function insertScan(memberName: string, data: Record<string, unknown>): number {
  const db = getDb();
  const tableName = `${memberName.replace(/-/g, '_')}_scans`;

  const columns = Object.keys(data);
  const placeholders = columns.map(() => '?').join(', ');
  const values = columns.map(col => {
    const val = data[col];
    if (typeof val === 'object' && val !== null) {
      return JSON.stringify(val);
    }
    if (typeof val === 'boolean') {
      return val ? 1 : 0;
    }
    return val;
  });

  const stmt = db.prepare(`
    INSERT INTO ${tableName} (${columns.join(', ')})
    VALUES (${placeholders})
  `);
  const result = stmt.run(...values);
  db.close();

  return Number(result.lastInsertRowid);
}

function insertFinding(memberName: string, scanId: number, data: Record<string, unknown>): void {
  const db = getDb();
  const tableName = `${memberName.replace(/-/g, '_')}_findings`;

  const dataWithScanId = { scan_id: scanId, ...data };
  const columns = Object.keys(dataWithScanId);
  const placeholders = columns.map(() => '?').join(', ');
  const values = columns.map(col => {
    const val = dataWithScanId[col];
    if (typeof val === 'object' && val !== null) {
      return JSON.stringify(val);
    }
    if (typeof val === 'boolean') {
      return val ? 1 : 0;
    }
    return val;
  });

  const stmt = db.prepare(`
    INSERT INTO ${tableName} (${columns.join(', ')})
    VALUES (${placeholders})
  `);
  stmt.run(...values);
  db.close();
}

function insertWithFindings(memberName: string, data: InsertWithFindingsData): number {
  const db = getDb();
  const scansTable = `${memberName.replace(/-/g, '_')}_scans`;
  const findingsTable = `${memberName.replace(/-/g, '_')}_findings`;

  // Use a transaction for atomicity
  const insertScanStmt = (() => {
    const columns = Object.keys(data.scan);
    const placeholders = columns.map(() => '?').join(', ');
    return db.prepare(`INSERT INTO ${scansTable} (${columns.join(', ')}) VALUES (${placeholders})`);
  })();

  let insertFindingStmt: Database.Statement | null = null;

  const transaction = db.transaction(() => {
    // Insert scan
    const values = Object.keys(data.scan).map(col => {
      const val = data.scan[col];
      if (typeof val === 'object' && val !== null) return JSON.stringify(val);
      if (typeof val === 'boolean') return val ? 1 : 0;
      return val;
    });
    const result = insertScanStmt.run(...values);
    const scanId = Number(result.lastInsertRowid);

    // Insert findings if any
    if (data.findings && data.findings.length > 0) {
      for (const finding of data.findings) {
        const findingWithScanId = { scan_id: scanId, ...finding };
        const cols = Object.keys(findingWithScanId);
        const placeholders = cols.map(() => '?').join(', ');

        if (!insertFindingStmt) {
          insertFindingStmt = db.prepare(`INSERT INTO ${findingsTable} (${cols.join(', ')}) VALUES (${placeholders})`);
        }

        const vals = cols.map(col => {
          const val = findingWithScanId[col];
          if (typeof val === 'object' && val !== null) return JSON.stringify(val);
          if (typeof val === 'boolean') return val ? 1 : 0;
          return val;
        });
        insertFindingStmt.run(...vals);
      }
    }

    return scanId;
  });

  const scanId = transaction() as number;
  db.close();
  return scanId;
}

// ═══════════════════════════════════════════════════════════════════════════
// QUERY OPERATIONS
// ═══════════════════════════════════════════════════════════════════════════

function queryScans(memberName: string, sigil: string): unknown[] {
  const db = getDb();
  const tableName = `${memberName.replace(/-/g, '_')}_scans`;
  const stmt = db.prepare(`SELECT * FROM ${tableName} WHERE sigil = ?`);
  const results = stmt.all(sigil);
  db.close();
  return results;
}

function queryFindings(memberName: string, sigil: string): unknown[] {
  const db = getDb();
  const scansTable = `${memberName.replace(/-/g, '_')}_scans`;
  const findingsTable = `${memberName.replace(/-/g, '_')}_findings`;

  // Join findings with scans to get scan context (only use repo which all tables have)
  const stmt = db.prepare(`
    SELECT f.*, s.repo
    FROM ${findingsTable} f
    JOIN ${scansTable} s ON f.scan_id = s.id
    WHERE s.sigil = ?
  `);
  const results = stmt.all(sigil);
  db.close();
  return results;
}

function queryConclave(sigil: string): unknown {
  const db = getDb();
  const stmt = db.prepare(`SELECT * FROM conclave WHERE sigil = ?`);
  const result = stmt.get(sigil);
  db.close();
  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// CLI INTERFACE
// ═══════════════════════════════════════════════════════════════════════════

function printUsage(): void {
  stderr.write(`Usage: guild-db <command> [options]

${CYAN_COLOR}Guild Database CLI${RESET_COLOR} - SQLite storage for The Guild scan results

Commands:
  init                                    Initialize database (create conclave table)
  register <member-dir>                   Register member schema from config.jsonc

  start-conclave <sigil> <json>           Start a conclave session
  end-conclave <sigil> <json>             End a conclave session with stats
  query-conclave <sigil>                  Query conclave session info

  insert-scan <member> <json>             Insert a scan record (returns scan_id)
  insert-finding <member> <scan_id> <json> Insert a finding linked to scan
  insert-with-findings <member> <json>    Insert scan + findings atomically

  query-scans <member> <sigil>            Query scans for a sigil
  query-findings <member> <sigil>         Query findings for a sigil (with scan context)

Examples:
  guild-db init
  guild-db register ./ascii-cutterman
  guild-db start-conclave "abc-123" '{"members":["ascii-cutterman"]}'
  guild-db insert-scan ascii-cutterman '{"sigil":"abc-123","repo":"o/r","filepath":"f.md"}'
  guild-db query-scans ascii-cutterman "abc-123"
`);
}

function main(): void {
  const [, , command, ...args] = argv;

  try {
    switch (command) {
      case 'init':
        initDatabase();
        stdout.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Database initialized at ${DB_PATH}\n`);
        break;

      case 'register':
        if (!args[0]) { printUsage(); exit(1); }
        registerMemberSchema(args[0]);
        stdout.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Registered schema for ${args[0]}\n`);
        break;

      case 'start-conclave':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        startConclave(args[0], JSON.parse(args[1]));
        break;

      case 'end-conclave':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        endConclave(args[0], JSON.parse(args[1]));
        break;

      case 'query-conclave':
        if (!args[0]) { printUsage(); exit(1); }
        stdout.write(JSON.stringify(queryConclave(args[0])) + '\n');
        break;

      case 'insert-scan':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        const scanId = insertScan(args[0], JSON.parse(args[1]));
        stdout.write(JSON.stringify({ scan_id: scanId }) + '\n');
        break;

      case 'insert-finding':
        if (!args[0] || !args[1] || !args[2]) { printUsage(); exit(1); }
        insertFinding(args[0], parseInt(args[1], 10), JSON.parse(args[2]));
        break;

      case 'insert-with-findings':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        // Support stdin with '-' as second arg
        const jsonInput = args[1] === '-' ? readStdin() : args[1];
        const resultId = insertWithFindings(args[0], JSON.parse(jsonInput));
        stdout.write(JSON.stringify({ scan_id: resultId }) + '\n');
        break;

      case 'query-scans':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        stdout.write(JSON.stringify(queryScans(args[0], args[1])) + '\n');
        break;

      case 'query-findings':
        if (!args[0] || !args[1]) { printUsage(); exit(1); }
        stdout.write(JSON.stringify(queryFindings(args[0], args[1])) + '\n');
        break;

      case '-h':
      case '--help':
      case 'help':
        printUsage();
        break;

      default:
        stderr.write(`${FAIL_COLOR}${XMARK}${RESET_COLOR} Unknown command: ${command}\n`);
        printUsage();
        exit(1);
    }
  } catch (error) {
    stderr.write(`${FAIL_COLOR}${XMARK} Error:${RESET_COLOR} ${error instanceof Error ? error.message : error}\n`);
    exit(1);
  }
}

main();
