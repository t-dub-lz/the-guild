// guild-hall/hooks/useKeys.ts
import { useInput } from "ink";

type Direction = "left" | "right" | "up" | "down";
type NormalizedKey = Direction | string;

const VIM_MAP: Record<string, Direction> = {
  h: "left",
  j: "down",
  k: "up",
  l: "right",
};

const ARROW_MAP: Record<string, Direction> = {
  leftArrow: "left",
  rightArrow: "right",
  upArrow: "up",
  downArrow: "down",
};

export function normalizeKey(key: string): NormalizedKey {
  if (key in VIM_MAP) return VIM_MAP[key];
  if (key in ARROW_MAP) return ARROW_MAP[key];
  return key;
}

type KeyHandler = (key: NormalizedKey, raw: string) => void;

export function useKeys(handler: KeyHandler, active: boolean = true) {
  useInput(
    (input, key) => {
      // Determine the raw key name
      let rawKey = input;
      if (key.leftArrow) rawKey = "leftArrow";
      else if (key.rightArrow) rawKey = "rightArrow";
      else if (key.upArrow) rawKey = "upArrow";
      else if (key.downArrow) rawKey = "downArrow";
      else if (key.return) rawKey = "return";
      else if (key.escape) rawKey = "escape";
      else if (key.tab && key.shift) rawKey = "backtab"; // Shift+Tab
      else if (key.tab) rawKey = "tab";
      else if (key.backspace) rawKey = "backspace";

      const normalized = normalizeKey(rawKey);
      handler(normalized, rawKey);
    },
    { isActive: active }
  );
}
