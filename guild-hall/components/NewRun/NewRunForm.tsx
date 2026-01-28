// guild-hall/components/NewRun/NewRunForm.tsx
import React, { useState, useEffect } from "react";
import { Box, Text } from "ink";
import { TextField, Checkbox, RadioGroup, NumberField } from "./FormField";
import { useKeys } from "../../hooks/useKeys";

export interface FormState {
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
  form: FormState;
  onFormChange: (form: FormState) => void;
  onSubmit: (state: FormState) => void;
  active: boolean;
  onEditingChange?: (editing: boolean) => void;
}

export const MEMBER_LIST = [
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
  | "options"
  | "parallelism"
  | "submit";

const FIELD_ORDER: FieldId[] = [
  "org",
  "repoMode",
  "members",
  "options",
  "parallelism",
  "submit",
];

// Options are navigated horizontally as a group
const OPTIONS_LIST = [
  { id: "strict", label: "Strict (-s)" },
  { id: "superStrict", label: "Super strict (-S)" },
  { id: "scanAll", label: "Scan all" },
  { id: "dryRun", label: "Dry run" },
] as const;

export function NewRunForm({ form, onFormChange, onSubmit, active, onEditingChange }: NewRunFormProps) {
  const [focusIndex, setFocusIndex] = useState(0);
  const [memberFocusIndex, setMemberFocusIndex] = useState(0);
  const [optionFocusIndex, setOptionFocusIndex] = useState(0);
  const [repoModeIndex, setRepoModeIndex] = useState(0);
  const [editingOrg, setEditingOrg] = useState(false);

  // Use callback to update parent state
  const setForm = (updater: FormState | ((prev: FormState) => FormState)) => {
    if (typeof updater === "function") {
      onFormChange(updater(form));
    } else {
      onFormChange(updater);
    }
  };

  const currentField = FIELD_ORDER[focusIndex];

  // Notify parent when editing state changes
  useEffect(() => {
    onEditingChange?.(editingOrg);
  }, [editingOrg, onEditingChange]);

  useKeys(
    (key) => {
      // Vertical navigation (j/k or up/down)
      if (key === "down") {
        setFocusIndex((i) => Math.min(i + 1, FIELD_ORDER.length - 1));
        // Reset sub-indices when moving to new field
        setMemberFocusIndex(0);
        setOptionFocusIndex(0);
        setRepoModeIndex(0);
      } else if (key === "up") {
        setFocusIndex((i) => Math.max(i - 1, 0));
        setMemberFocusIndex(0);
        setOptionFocusIndex(0);
        setRepoModeIndex(0);
      }
      // Horizontal navigation (h/l or left/right) for horizontal groups
      else if (key === "left") {
        if (currentField === "members") {
          setMemberFocusIndex((i) => Math.max(i - 1, 0));
        } else if (currentField === "options") {
          setOptionFocusIndex((i) => Math.max(i - 1, 0));
        } else if (currentField === "parallelism") {
          setForm((f) => ({ ...f, parallelism: Math.max(1, f.parallelism - 1) }));
        }
      } else if (key === "right") {
        if (currentField === "members") {
          setMemberFocusIndex((i) => Math.min(i + 1, MEMBER_LIST.length - 1));
        } else if (currentField === "options") {
          setOptionFocusIndex((i) => Math.min(i + 1, OPTIONS_LIST.length - 1));
        } else if (currentField === "parallelism") {
          setForm((f) => ({ ...f, parallelism: Math.min(100, f.parallelism + 1) }));
        }
      }
      // Space to toggle checkboxes/radios
      else if (key === " ") {
        if (currentField === "members") {
          const memberId = MEMBER_LIST[memberFocusIndex].id;
          setForm((f) => ({
            ...f,
            members: { ...f.members, [memberId]: !f.members[memberId] },
          }));
        } else if (currentField === "options") {
          const optionId = OPTIONS_LIST[optionFocusIndex].id;
          setForm((f) => ({ ...f, [optionId]: !f[optionId] }));
        } else if (currentField === "repoMode") {
          // Toggle between the two repo modes
          const newMode = form.repoMode === "all" ? "select" : "all";
          setForm((f) => ({ ...f, repoMode: newMode }));
          setRepoModeIndex(newMode === "all" ? 0 : 1);
        }
      }
      // Enter to submit or edit text field
      else if (key === "return") {
        if (currentField === "submit") {
          onSubmit(form);
        } else if (currentField === "org") {
          setEditingOrg(true);
        } else if (currentField === "repoMode") {
          // Select the focused repo mode option
          const newMode = repoModeIndex === 0 ? "all" : "select";
          setForm((f) => ({ ...f, repoMode: newMode }));
        }
      }
      // 'i' to enter edit mode (vim-style insert)
      else if (key === "i") {
        if (currentField === "org") {
          setEditingOrg(true);
        }
      }
    },
    active && !editingOrg
  );

  return (
    <Box flexDirection="column" padding={1}>
      <TextField
        label="Organization"
        value={form.org}
        focused={currentField === "org"}
        editing={editingOrg}
        onChange={(v) => setForm((f) => ({ ...f, org: v }))}
        onEditComplete={() => setEditingOrg(false)}
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
          focusedIndex={repoModeIndex}
        />
        {currentField === "repoMode" && <Text dimColor> (Space to toggle)</Text>}
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
          {OPTIONS_LIST.map((opt, i) => (
            <Checkbox
              key={opt.id}
              label={opt.label}
              checked={form[opt.id]}
              focused={currentField === "options" && optionFocusIndex === i}
            />
          ))}
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
