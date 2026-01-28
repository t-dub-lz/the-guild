// guild-hall/components/NewRun/FormField.tsx
import React from "react";
import { Box, Text } from "ink";

interface TextFieldProps {
  label: string;
  value: string;
  focused: boolean;
  onChange?: (value: string) => void;
}

export function TextField({ label, value, focused }: TextFieldProps) {
  return (
    <Box>
      <Text>{label}: </Text>
      <Text bold={focused} inverse={focused}>
        {" "}
        {value || "(empty)"}{" "}
      </Text>
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
