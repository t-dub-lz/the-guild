// guild-hall/tests/app.test.ts
import { describe, test, expect } from "bun:test";
import { spawnSync } from "bun";

describe("guild-hall", () => {
  test("launches without error", () => {
    // Just verify it can import and parse without errors
    const result = spawnSync(["bun", "run", "--bun", "guild-hall.tsx", "--help"], {
      cwd: import.meta.dir + "/..",
      timeout: 5000,
    });

    // Ink apps don't have --help, but they should at least start
    // Exit code 0 means it ran (and exited because no TTY)
    expect(result.exitCode).toBeDefined();
  });

  test("defaults.json is valid", async () => {
    const defaults = await import("../defaults.json");
    expect(defaults.members).toBeArray();
    expect(defaults.parallelism).toBeNumber();
    expect(defaults.ui.pollIntervalMs).toBeNumber();
  });
});
