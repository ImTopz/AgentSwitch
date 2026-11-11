/** The line an agent's screen shows while it tries to reach its service again (terminals/screenTrouble.ts,
 *  docs/simple-view-v0.md §5.19). */

import { describe, expect, it } from "vitest";
import { troubleOnScreen } from "../src/terminals/screenTrouble.js";

describe("an agent that tries to reach its service again", () => {
  it("reads Claude Code's and Codex's lines, without their marks", () => {
    expect(troubleOnScreen(["⏺ Reading the file", "", "✻ Working… (12s)", "  ⎿  API Error (Connection error.) · Retrying in 5 seconds… (attempt 4/10)", "", "─────", "❯ ", "─────"]))
      .toBe("API Error (Connection error.) · Retrying in 5 seconds… (attempt 4/10)");
    expect(troubleOnScreen(["■ stream disconnected before completion: error sending request; retrying 2/5 in 400ms…"]))
      .toBe("stream disconnected before completion: error sending request; retrying 2/5 in 400ms…");
    expect(troubleOnScreen(["• Reconnecting... 2/5", "", "› "])).toBe("Reconnecting... 2/5");
  });

  it("takes neither an answer that has the word in it nor a line far up the screen", () => {
    expect(troubleOnScreen(["⏺ I am retrying the build now and reconnecting the socket.", "❯ "])).toBeNull();
    expect(troubleOnScreen(["  ⎿  API Error · Retrying in 5 seconds… (attempt 4/10)", ...Array.from({ length: 12 }, (_, i) => `line ${i}`)])).toBeNull();
    expect(troubleOnScreen([])).toBeNull();
  });
});
