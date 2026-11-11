/** An agent that cannot reach its service says so on its own screen and tries again — Claude Code's
 *  `⎿ API Error (Connection error.) · Retrying in 5 seconds… (attempt 4/10)`, Codex's `■ stream disconnected before
 *  completion…; retrying 2/5 in 400ms`, `Reconnecting... 2/5`. Its record holds nothing of it until the turn ends one
 *  way or the other, so a screen that shows the record showed a turn at work and nothing else (docs/simple-view-v0.md
 *  §5.19; 2026-11-11, user: 有的时候网络不好agent连不上，显示重连的时候 简略模式没有信息). The line is read off the
 *  screen's last rows and told to the record's screens as a notice for as long as it stands there.
 *
 *  Only a line that says it is trying again, with when or which attempt: an answer that merely has the word in it is
 *  not one, and neither is a line further up the screen (what was said before). */

const RETRY = [
  /\bretrying in \d+(?:\.\d+)?\s*(?:ms|s|sec|secs|seconds?)\b/i,
  /\b(?:retrying|reconnecting)\b.{0,40}?\d+\s*\/\s*\d+/i,
  /\battempt \d+\s*(?:\/|of)\s*\d+/i,
];
/** How many of the screen's last rows that say something are looked at: the agent's status sits just above its input. */
const ROWS = 12;
const MAX = 200;

/** The line on the screen's last rows that says the agent is trying to reach its service again; null when none does.
 *  `lines`: the screen's rows top to bottom. */
export function troubleOnScreen(lines: readonly string[]): string | null {
  const said = lines.map((l) => l.trim()).filter(Boolean).slice(-ROWS);
  for (let i = said.length - 1; i >= 0; i--) {
    const text = said[i]!.replace(/^[\s⎿└•■●⏺✻✢✳✶✽·│|>›❯*-]+/u, "").replace(/[\s│|]+$/u, "").replace(/\s+/g, " ");
    if (RETRY.some((r) => r.test(text))) return text.slice(0, MAX);
  }
  return null;
}
