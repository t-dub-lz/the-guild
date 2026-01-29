// guild-hall/components/Current/LiveLog.tsx
import React from "react";
import { Box, Text } from "ink";

// Strip ANSI escape codes - they conflict with Ink's rendering
const ANSI_REGEX = /\x1b\[[0-9;]*m/g;
function stripAnsi(str: string): string {
  return str.replace(ANSI_REGEX, "");
}

// Truncate line to max width to prevent overflow
function truncateLine(str: string, maxWidth: number): string {
  if (str.length <= maxWidth) return str;
  return str.slice(0, maxWidth - 1) + "…";
}

interface LiveLogProps {
  lines: string[];
  maxLines?: number;
  maxWidth?: number;
}

export function LiveLog({ lines, maxLines = 20, maxWidth = 80 }: LiveLogProps) {
  // Strip ANSI codes, truncate long lines, and take last N lines
  const displayLines = lines
    .slice(-maxLines)
    .map((line) => truncateLine(stripAnsi(line), maxWidth));

  return (
    <Box
      flexDirection="column"
      width="50%"
      flexGrow={1}
      flexShrink={1}
      overflow="hidden"
      borderStyle="single"
      borderRight
      borderTop={false}
      borderBottom={false}
      borderLeft={false}
      paddingX={1}
    >
      {displayLines.map((line, i) => {
        // Color code based on content
        let color: string | undefined;
        if (line.includes("✓") || line.includes("clean")) {
          color = "green";
        } else if (line.includes("✗") || line.includes("issue") || line.includes("FINDING")) {
          color = "red";
        } else if (line.startsWith("[REPO:")) {
          color = "cyan";
        }

        return (
          <Text key={i} color={color} wrap="truncate">
            {line}
          </Text>
        );
      })}
    </Box>
  );
}
