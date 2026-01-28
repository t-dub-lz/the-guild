// guild-hall/hooks/useKeys.test.ts
import { describe, test, expect } from "bun:test";
import { normalizeKey } from "./useKeys";

describe("normalizeKey", () => {
  test("maps vim keys to directions", () => {
    expect(normalizeKey("h")).toBe("left");
    expect(normalizeKey("j")).toBe("down");
    expect(normalizeKey("k")).toBe("up");
    expect(normalizeKey("l")).toBe("right");
  });

  test("maps arrow keys to directions", () => {
    expect(normalizeKey("leftArrow")).toBe("left");
    expect(normalizeKey("downArrow")).toBe("down");
    expect(normalizeKey("upArrow")).toBe("up");
    expect(normalizeKey("rightArrow")).toBe("right");
  });

  test("passes through other keys unchanged", () => {
    expect(normalizeKey("return")).toBe("return");
    expect(normalizeKey("escape")).toBe("escape");
    expect(normalizeKey("q")).toBe("q");
  });
});
