// guild-hall/components/Footer.tsx
import React from "react";
import { Box, Text } from "ink";

interface FooterProps {
  hints: string;
  runCount: number;
  org?: string;
  status?: string;
}

export function Footer({ hints, runCount, org, status }: FooterProps) {
  return (
    <Box
      borderStyle="single"
      borderTop
      borderBottom={false}
      borderLeft={false}
      borderRight={false}
      paddingX={1}
      justifyContent="space-between"
    >
      <Text dimColor>{hints}</Text>
      <Box>
        {status && (
          <Text color="yellow" bold>
            {status}
            {"  "}
          </Text>
        )}
        <Text dimColor>
          {runCount} runs{org ? ` │ ${org}` : ""}
        </Text>
      </Box>
    </Box>
  );
}
