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
