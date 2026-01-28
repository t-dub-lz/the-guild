// guild-hall/components/NewRun/NewRunForm.tsx
import React, { useState } from "react";
import { Box, Text } from "ink";
import { TextField, Checkbox, RadioGroup, NumberField } from "./FormField";
import { useKeys } from "../../hooks/useKeys";

interface FormState {
  org: string;
  repoMode: "all" | "select";
  members: Record<string, boolean>;
  strict: boolean;
  superStrict: boolean;
  scanAll: boolean;
  dryRun: boolean;
  parallelism: number;
}

interface NewRunFormProps {
  defaults: {
    org: string;
    members: string[];
    parallelism: number;
    strict: boolean;
    superStrict: boolean;
    scanAll: boolean;
    dryRun: boolean;
  };
  onSubmit: (state: FormState) => void;
  active: boolean;
}

const MEMBER_LIST = [
  { id: "ascii-cutterman", name: "ASCII Cutterman" },
  { id: "secretary", name: "Secretary" },
  { id: "sentinel", name: "Sentinel" },
  { id: "catburglar", name: "Catburglar" },
  { id: "the-judge", name: "The Judge" },
];

type FieldId =
  | "org"
  | "repoMode"
  | "members"
  | "strict"
  | "superStrict"
  | "scanAll"
  | "dryRun"
  | "parallelism"
  | "submit";

const FIELD_ORDER: FieldId[] = [
  "org",
  "repoMode",
  "members",
  "strict",
  "superStrict",
  "scanAll",
  "dryRun",
  "parallelism",
  "submit",
];

export function NewRunForm({ defaults, onSubmit, active }: NewRunFormProps) {
  const [focusIndex, setFocusIndex] = useState(0);
  const [memberFocusIndex, setMemberFocusIndex] = useState(0);

  const [form, setForm] = useState<FormState>(() => ({
    org: defaults.org,
    repoMode: "all",
    members: Object.fromEntries(
      MEMBER_LIST.map((m) => [m.id, defaults.members.includes(m.id)])
    ),
    strict: defaults.strict,
    superStrict: defaults.superStrict,
    scanAll: defaults.scanAll,
    dryRun: defaults.dryRun,
    parallelism: defaults.parallelism,
  }));

  const currentField = FIELD_ORDER[focusIndex];

  useKeys(
    (key) => {
      if (key === "down") {
        if (currentField === "members") {
          if (memberFocusIndex < MEMBER_LIST.length - 1) {
            setMemberFocusIndex((i) => i + 1);
          } else {
            setFocusIndex((i) => Math.min(i + 1, FIELD_ORDER.length - 1));
            setMemberFocusIndex(0);
          }
        } else {
          setFocusIndex((i) => Math.min(i + 1, FIELD_ORDER.length - 1));
        }
      } else if (key === "up") {
        if (currentField === "members" && memberFocusIndex > 0) {
          setMemberFocusIndex((i) => i - 1);
        } else {
          setFocusIndex((i) => Math.max(i - 1, 0));
          if (FIELD_ORDER[Math.max(focusIndex - 1, 0)] === "members") {
            setMemberFocusIndex(MEMBER_LIST.length - 1);
          }
        }
      } else if (key === " ") {
        // Toggle checkboxes
        if (currentField === "members") {
          const memberId = MEMBER_LIST[memberFocusIndex].id;
          setForm((f) => ({
            ...f,
            members: { ...f.members, [memberId]: !f.members[memberId] },
          }));
        } else if (
          ["strict", "superStrict", "scanAll", "dryRun"].includes(currentField)
        ) {
          setForm((f) => ({ ...f, [currentField]: !f[currentField as keyof FormState] }));
        }
      } else if (key === "return") {
        if (currentField === "submit") {
          onSubmit(form);
        }
      } else if (key === "left" && currentField === "parallelism") {
        setForm((f) => ({ ...f, parallelism: Math.max(1, f.parallelism - 1) }));
      } else if (key === "right" && currentField === "parallelism") {
        setForm((f) => ({
          ...f,
          parallelism: Math.min(100, f.parallelism + 1),
        }));
      }
    },
    active
  );

  return (
    <Box flexDirection="column" padding={1}>
      <TextField
        label="Organization"
        value={form.org}
        focused={currentField === "org"}
      />

      <Box marginTop={1} flexDirection="column">
        <Text>Repositories:</Text>
        <RadioGroup
          options={[
            { value: "all", label: "All from org" },
            { value: "select", label: "Select specific repos..." },
          ]}
          selected={form.repoMode}
          focused={currentField === "repoMode"}
          focusedIndex={0}
        />
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>Guild Members:</Text>
        <Box flexDirection="row" flexWrap="wrap" gap={2}>
          {MEMBER_LIST.map((member, i) => (
            <Checkbox
              key={member.id}
              label={member.name}
              checked={form.members[member.id]}
              focused={currentField === "members" && memberFocusIndex === i}
            />
          ))}
        </Box>
      </Box>

      <Box marginTop={1} flexDirection="column">
        <Text>Options:</Text>
        <Box flexDirection="row" gap={2}>
          <Checkbox
            label="Strict mode (-s)"
            checked={form.strict}
            focused={currentField === "strict"}
          />
          <Checkbox
            label="Super strict (-S)"
            checked={form.superStrict}
            focused={currentField === "superStrict"}
          />
        </Box>
        <Box flexDirection="row" gap={2}>
          <Checkbox
            label="Scan all files"
            checked={form.scanAll}
            focused={currentField === "scanAll"}
          />
          <Checkbox
            label="Dry run"
            checked={form.dryRun}
            focused={currentField === "dryRun"}
          />
        </Box>
      </Box>

      <Box marginTop={1}>
        <NumberField
          label="Parallelism"
          value={form.parallelism}
          focused={currentField === "parallelism"}
        />
      </Box>

      <Box marginTop={2} justifyContent="center">
        <Text bold={currentField === "submit"} inverse={currentField === "submit"}>
          {"  "}⚔️ Begin Scan{"  "}
        </Text>
      </Box>
    </Box>
  );
}
