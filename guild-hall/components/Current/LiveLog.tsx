// guild-hall/components/Current/LiveLog.tsx
import React from "react";
import { Box, Text } from "ink";

// Strip ALL escape sequences - ANSI colors, cursor movements, etc.
const ESCAPE_REGEX = /\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][AB012]|\x1b[>=]?/g;
// Also strip carriage returns and other control characters
const CONTROL_REGEX = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\r]/g;

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

// Get color for a line based on content
function getLineColor(line: string): string | undefined {
  if (line.includes("✓") || line.includes("clean")) return "green";
  if (line.includes("✗") || line.includes("issue") || line.includes("FINDING")) return "red";
  if (line.startsWith("[REPO:") || line.startsWith("[SIGIL:")) return "cyan";
  return undefined;
}

interface LiveLogProps {
  lines: string[];
  height: number;
  width: number;
}

export function LiveLog({ lines, height, width }: LiveLogProps) {
  // Calculate usable dimensions (account for border)
  const usableHeight = Math.max(1, height - 1);
  const usableWidth = Math.max(10, width - 3); // border + padding

  // Process lines: sanitize, truncate, filter empty
  const processedLines = lines
    .map((line) => truncateLine(sanitizeLine(line), usableWidth))
    .filter((line) => line.length > 0);

  // Take exactly the last N lines that fit, pad with empty if needed
  const displayLines: string[] = [];
  const startIdx = Math.max(0, processedLines.length - usableHeight);
  for (let i = 0; i < usableHeight; i++) {
    const lineIdx = startIdx + i;
    displayLines.push(lineIdx < processedLines.length ? processedLines[lineIdx] : "");
  }

  // Render as a single pre-formatted text block to avoid flex issues
  return (
    <Box
      flexDirection="column"
      width={width}
      height={height}
      borderStyle="single"
      borderRight
      borderTop={false}
      borderBottom={false}
      borderLeft={false}
      paddingLeft={1}
    >
      {displayLines.map((line, i) => (
        <Text key={i} color={getLineColor(line)}>
          {line || " "}
        </Text>
      ))}
    </Box>
  );
}
