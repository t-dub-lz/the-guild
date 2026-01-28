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
