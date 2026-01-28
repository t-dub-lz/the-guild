// SQL query definitions for reading conclave run data from guild.db
// These queries are used by the useDatabase hook to fetch run information

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
  // Member table name is dynamic (e.g., "snyk", "semgrep")
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
  // Returns findings joined with scan metadata for context
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
