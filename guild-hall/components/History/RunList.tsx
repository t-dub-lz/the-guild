// guild-hall/components/History/RunList.tsx
import React from "react";
import { Box, Text } from "ink";
import type { ConclaveRun } from "../../hooks/useDatabase";

// Short codes for each guild member
const MEMBER_CODES: Record<string, string> = {
  "ascii-cutterman": "AC",
  "secretary": "SE",
  "sentinel": "SN",
  "catburglar": "CB",
  "the-judge": "TJ",
};

// Parse members JSON and return short codes
function formatMembers(membersJson: string | null): string {
  if (!membersJson) return "─────";
  try {
    const members = JSON.parse(membersJson) as string[];
    // Show codes for included members, dash for excluded
    const allMembers = ["ascii-cutterman", "secretary", "sentinel", "catburglar", "the-judge"];
    return allMembers
      .map((m) => (members.includes(m) ? MEMBER_CODES[m] : "──"))
      .join(" ");
  } catch {
    return "─────";
  }
}

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
      <Text dimColor>
        Members: AC=ASCII Cutterman  SE=Secretary  SN=Sentinel  CB=Catburglar  TJ=The Judge
      </Text>
      <Text dimColor>{"─".repeat(85)}</Text>

      {visibleRuns.length === 0 ? (
        <Text dimColor>No runs found</Text>
      ) : (
        visibleRuns.map((run, i) => {
          const actualIndex = i + scrollOffset;
          const isSelected = focused && actualIndex === selectedIndex;
          const hasIssues = (run.repos_with_issues ?? 0) > 0;

          // Format date
          const date = new Date(run.started_at);
          const dateStr = date.toISOString().slice(0, 16).replace("T", " ");

          return (
            <Box key={run.sigil}>
              <Text bold={isSelected} inverse={isSelected}>
                {isSelected ? "▸" : " "} {dateStr}
              </Text>
              <Text>{"  "}</Text>
              <Text>{(run.org_name || "(no org)").padEnd(15)}</Text>
              <Text>{String(run.repo_count ?? 0).padStart(4)} repos</Text>
              <Text>{"  "}</Text>
              <Text color={hasIssues ? "red" : "green"}>
                {String(run.repos_with_issues ?? 0).padStart(4)} issues
              </Text>
              <Text>{"  "}</Text>
              <Text color={hasIssues ? "red" : "green"}>
                {hasIssues ? "✗" : "✓"}
              </Text>
              <Text>{"  "}</Text>
              <Text dimColor>{formatMembers(run.members)}</Text>
            </Box>
          );
        })
      )}
    </Box>
  );
}
