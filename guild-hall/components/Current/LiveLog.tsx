// guild-hall/components/Current/LiveLog.tsx
import React from "react";
import { Box, Text } from "ink";

// Strip ALL escape sequences - ANSI colors, cursor movements, etc.
const ESCAPE_REGEX = /\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][AB012]|\x1b[>=]?/g;
// Also strip carriage returns and other control characters
const CONTROL_REGEX = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g;

function sanitizeLine(str: string): string {
  return str
    .replace(ESCAPE_REGEX, "")
    .replace(CONTROL_REGEX, "")
    .trim();
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
  maxHeight?: number;
}

export function LiveLog({ lines, maxLines = 15, maxWidth = 60, maxHeight }: LiveLogProps) {
  // Sanitize, truncate, and take last N lines
  const displayLines = lines
    .slice(-maxLines)
    .map((line) => truncateLine(sanitizeLine(line), maxWidth))
    .filter((line) => line.length > 0); // Remove empty lines

  return (
    <Box
      flexDirection="column"
      width="50%"
      height={maxHeight}
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
        } else if (line.startsWith("[REPO:") || line.startsWith("[SIGIL:")) {
          color = "cyan";
        }

        return (
          <Text key={i} color={color}>
            {line}
          </Text>
        );
      })}
    </Box>
  );
}
