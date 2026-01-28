#!/usr/bin/env bun
import React from "react";
import { render, Text, Box } from "ink";

function App() {
  return (
    <Box flexDirection="column">
      <Text bold color="cyan">
        ⚔️ Guild Hall
      </Text>
      <Text dimColor>Press q to quit</Text>
    </Box>
  );
}

render(<App />);
