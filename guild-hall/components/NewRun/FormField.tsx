// guild-hall/components/NewRun/FormField.tsx
import React, { useState } from "react";
import { Box, Text, useInput } from "ink";

interface TextFieldProps {
  label: string;
  value: string;
  focused: boolean;
  editing?: boolean;
  onChange?: (value: string) => void;
  onEditComplete?: () => void;
}

export function TextField({ label, value, focused, editing, onChange, onEditComplete }: TextFieldProps) {
  // Handle text input when editing
  useInput(
    (input, key) => {
      if (!editing) return;

      // Exit editing mode on Enter or Escape
      if (key.return || key.escape) {
        onEditComplete?.();
        return;
      }

      if (!onChange) return;

      if (key.backspace || key.delete) {
        onChange(value.slice(0, -1));
      } else if (!key.ctrl && !key.meta && input && input.length === 1) {
        // Only add printable characters
        onChange(value + input);
      }
    },
    { isActive: editing }
  );

  return (
    <Box>
      <Text>{label}: </Text>
      <Text bold={focused} inverse={focused}>
        {" "}
        {value || "(empty)"}
        {editing ? "▌" : ""}{" "}
      </Text>
      {focused && !editing && <Text dimColor> (Enter to edit)</Text>}
      {editing && <Text dimColor> (Enter/Esc to confirm)</Text>}
    </Box>
  );
}

interface CheckboxProps {
  label: string;
  checked: boolean;
  focused: boolean;
  onChange?: (checked: boolean) => void;
}

export function Checkbox({ label, checked, focused }: CheckboxProps) {
  return (
    <Box>
      <Text bold={focused} inverse={focused}>
        [{checked ? "✓" : " "}]
      </Text>
      <Text> {label}</Text>
    </Box>
  );
}

interface RadioGroupProps {
  options: { value: string; label: string }[];
  selected: string;
  focused: boolean;
  focusedIndex: number;
}

export function RadioGroup({
  options,
  selected,
  focused,
  focusedIndex,
}: RadioGroupProps) {
  return (
    <Box flexDirection="column">
      {options.map((opt, i) => (
        <Box key={opt.value}>
          <Text bold={focused && i === focusedIndex} inverse={focused && i === focusedIndex}>
            {opt.value === selected ? "●" : "○"}
          </Text>
          <Text> {opt.label}</Text>
        </Box>
      ))}
    </Box>
  );
}

interface NumberFieldProps {
  label: string;
  value: number;
  focused: boolean;
  min?: number;
  max?: number;
}

export function NumberField({ label, value, focused }: NumberFieldProps) {
  return (
    <Box>
      <Text>{label}: </Text>
      <Text bold={focused} inverse={focused}>
        {" "}
        [{value}]{" "}
      </Text>
      <Text> jobs</Text>
    </Box>
  );
}
