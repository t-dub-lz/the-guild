// guild-hall/components/Current/LiveLog.tsx
import React from "react";
import { Box, Text } from "ink";

interface LiveLogProps {
  lines: string[];
  maxLines?: number;
}

export function LiveLog({ lines, maxLines = 20 }: LiveLogProps) {
  const displayLines = lines.slice(-maxLines);

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
