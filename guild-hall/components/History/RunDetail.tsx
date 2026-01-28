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
        <Text>Organization:  {run.org_name || "(no org)"}</Text>
        <Text>Duration:      {duration}</Text>
        <Text>
          Repositories:  {run.repo_count ?? 0} scanned, {run.repos_with_issues ?? 0} with issues
        </Text>
        <Text>Files:         {(run.total_files_scanned ?? 0).toLocaleString()} total</Text>
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
