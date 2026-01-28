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
