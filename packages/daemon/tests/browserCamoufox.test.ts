import { describe, expect, it } from "vitest";
import { camoufoxEnv, camoufoxSteps, releaseAll } from "../src/browser/camoufoxInput.js";
import { PictureRun, shotScale, SHOT_EVERY_MS, SHOT_STILL_MS, type Shown } from "../src/browser/camoufoxPictures.js";
import { inputCalls, NOTHING_PRESSED } from "../src/browser/input.js";
import type { Modifier } from "../src/browser/input.js";

const none: ReadonlySet<Modifier> = new Set();

describe("the host's input calls as Playwright's mouse and keyboard (docs/browser-v0.md §7.3)", () => {
  it("a mouse call is a move, then the button; its modifiers are keys pressed around it", () => {
    const pressed = camoufoxSteps("Input.dispatchMouseEvent", { type: "mousePressed", x: 10, y: 20, button: "left", clickCount: 2, modifiers: 8 }, none);
    expect(pressed.steps).toEqual([{ do: "modifier", key: "Shift", down: true }, { do: "move", x: 10, y: 20 }, { do: "press", button: "left", clickCount: 2 }]);
    expect([...pressed.held]).toEqual(["Shift"]);
    // The same modifiers again: nothing pressed twice.
    const released = camoufoxSteps("Input.dispatchMouseEvent", { type: "mouseReleased", x: 10, y: 20, button: "left", clickCount: 2, modifiers: 8 }, pressed.held);
    expect(released.steps).toEqual([{ do: "move", x: 10, y: 20 }, { do: "release", button: "left", clickCount: 2 }]);
    // None next: the key is let go before the move.
    expect(camoufoxSteps("Input.dispatchMouseEvent", { type: "mouseMoved", x: 1, y: 2, modifiers: 0, button: "none" }, released.held).steps)
      .toEqual([{ do: "modifier", key: "Shift", down: false }, { do: "move", x: 1, y: 2 }]);
  });

  it("the wheel turns where the pointer was put", () => {
    expect(camoufoxSteps("Input.dispatchMouseEvent", { type: "mouseWheel", x: 5, y: 6, modifiers: 0, deltaX: 0, deltaY: 120 }, none).steps)
      .toEqual([{ do: "move", x: 5, y: 6 }, { do: "wheel", dx: 0, dy: 120 }]);
  });

  it("a key goes down and up by its name, with its modifiers held; text goes in as text", () => {
    const down = camoufoxSteps("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "a", code: "KeyA", modifiers: 4, commands: ["selectAll"] }, none);
    expect(down.steps).toEqual([{ do: "modifier", key: "Meta", down: true }, { do: "key", key: "a", down: true }]);
    expect(camoufoxSteps("Input.dispatchKeyEvent", { type: "keyUp", key: "a", code: "KeyA", modifiers: 4 }, down.held).steps).toEqual([{ do: "key", key: "a", down: false }]);
    expect(camoufoxSteps("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", text: "\r", modifiers: 0 }, none).steps).toEqual([{ do: "key", key: "Enter", down: true }]);
    expect(camoufoxSteps("Input.insertText", { text: "你好 abc" }, down.held)).toEqual({ steps: [{ do: "text", text: "你好 abc" }], held: down.held });
    expect(releaseAll(down.held)).toEqual([{ do: "modifier", key: "Meta", down: false }]);
    expect(releaseAll(none)).toEqual([]);
  });

  it("takes every call the host makes for a screen's events", () => {
    const geometry = { width: 1280, height: 800, scale: 1, view: 1 } as never;
    const events = [
      { type: "mouse", action: "click", x: 30, y: 40, button: "left", clickCount: 1, modifiers: ["Shift"] },
      { type: "wheel", x: 30, y: 40, deltaX: 0, deltaY: 50, modifiers: [] },
      { type: "key", key: "Backspace", modifiers: [] },
      { type: "text", text: "x" },
    ] as never[];
    let held: ReadonlySet<Modifier> = none;
    let pressed = NOTHING_PRESSED;
    const kinds: string[] = [];
    for (const event of events) {
      const made = inputCalls(event, geometry, pressed, true);
      pressed = made.pressed;
      for (const call of made.calls) {
        const r = camoufoxSteps(call.method, call.params, held);
        held = r.held;
        kinds.push(...r.steps.map((s) => s.do));
      }
    }
    expect(kinds).toEqual(["modifier", "move", "move", "press", "move", "release", "modifier", "move", "wheel", "key", "key", "text"]);
  });
});

describe("what Camoufox is started with", () => {
  it("a fingerprint goes in environment variables, cut where one may end", () => {
    expect(camoufoxEnv({ "navigator.hardwareConcurrency": 8 })).toEqual({ CAMOU_CONFIG_1: '{"navigator.hardwareConcurrency":8}' });
    const big = camoufoxEnv({ fonts: Array.from({ length: 6000 }, (_, i) => `Font Number ${i}`) }, "darwin");
    expect(Object.keys(big)).toEqual(["CAMOU_CONFIG_1", "CAMOU_CONFIG_2", "CAMOU_CONFIG_3", "CAMOU_CONFIG_4"]);
    expect(big.CAMOU_CONFIG_1).toHaveLength(32767);
    expect(JSON.parse(Object.values(big).join("")).fonts).toHaveLength(6000);
    expect(camoufoxEnv({})).toEqual({ CAMOU_CONFIG_1: "{}" });
  });

  it("pictures are taken at the page's own pixels when the watchers take that many, else at one per CSS pixel", () => {
    expect(shotScale({ width: 1280, height: 800 }, 2, {})).toBe("device");
    expect(shotScale({ width: 1280, height: 800 }, 2, { maxWidth: 2560, maxHeight: 1600 })).toBe("device");
    expect(shotScale({ width: 1280, height: 800 }, 2, { maxWidth: 1920 })).toBe("css");
    expect(shotScale({ width: 1280, height: 800 }, 2, { maxWidth: 3456, maxHeight: 1200 })).toBe("css");
    expect(shotScale({ width: 402, height: 700 }, 2, { maxWidth: 1206, maxHeight: 2622 })).toBe("device");
    expect(shotScale({ width: 391, height: 845 }, 1, { maxWidth: 200 })).toBe("css");
  });
});

describe("the pictures of a Camoufox page (camoufoxPictures.ts; 2026-11-10: what is in view, not the document's top)", () => {
  /** A page whose picture is `face`, shown at `at`; every look and every wait is written down. */
  function page() {
    const state = { face: "a", at: { width: 1280, height: 800, x: 0, y: 0 } as Shown, closed: false, failing: false };
    const sent: { face: string; shown: Shown }[] = [];
    const shots: string[] = [];
    const waits: number[] = [];
    let ack: (() => void) | null = null;
    let clock = 0;
    let turn: (() => void) | null = null;
    const source = {
      shown: async () => state.at,
      shot: async (scale: "device" | "css") => { shots.push(scale); if (state.failing) throw new Error("navigating"); return Buffer.from(state.face); },
      send: (data: string, shown: Shown) => new Promise<void>((resolve) => { sent.push({ face: Buffer.from(data, "base64").toString(), shown }); ack = resolve; }),
      ratio: () => 2,
      closed: () => state.closed,
      now: () => clock,
      // Each wait is held until the test lets it go (or a nudge wakes it).
      sleep: (ms: number, woken: Promise<void>) => { waits.push(ms); return Promise.race([new Promise<void>((resolve) => { turn = () => { clock += ms; resolve(); }; }), woken]); },
    };
    const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
    return { state, sent, shots, waits, source, settle, ack: async () => { ack?.(); ack = null; await settle(); }, next: async () => { turn?.(); turn = null; await settle(); } };
  }

  it("sends what the page shows with where it is scrolled to, the next one only after the acknowledgement", async () => {
    const p = page();
    const run = new PictureRun(p.source, { quality: 60, maxWidth: 2560, maxHeight: 1600 });
    await p.settle();
    expect(p.sent).toEqual([{ face: "a", shown: { width: 1280, height: 800, x: 0, y: 0 } }]);
    expect(p.shots).toEqual(["device"]);
    // Not acknowledged: nothing more is looked at, whatever the page does.
    p.state.face = "b";
    await p.settle();
    expect(p.shots).toHaveLength(1);
    await p.ack();
    await p.next();
    expect(p.sent.map((s) => s.face)).toEqual(["a", "b"]);
    // Scrolled: the picture carries where to.
    p.state.at = { width: 1280, height: 800, x: 0, y: 1600 };
    p.state.face = "c";
    await p.ack();
    await p.next();
    expect(p.sent[2]).toEqual({ face: "c", shown: { width: 1280, height: 800, x: 0, y: 1600 } });
    await p.ack();
    await run.stop();
  });

  it("sends nothing while the page stands still, and looks less and less often — at once again when something is done to it", async () => {
    const p = page();
    const run = new PictureRun(p.source, { quality: 60 });
    await p.settle();
    await p.ack();
    for (let i = 0; i < 5; i++) await p.next();
    expect(p.sent).toHaveLength(1);
    expect(p.shots.length).toBeGreaterThanOrEqual(5);
    expect(p.waits.slice(0, 5)).toEqual([SHOT_EVERY_MS, 2 * SHOT_EVERY_MS, 4 * SHOT_EVERY_MS, SHOT_STILL_MS, SHOT_STILL_MS]);
    // The same picture somewhere else is another picture.
    p.state.at = { width: 1280, height: 800, x: 0, y: 40 };
    await p.next();
    expect(p.sent).toHaveLength(2);
    await p.ack();
    await p.next();
    await p.next();
    // Input: the wait under way ends, and the page is looked at often again.
    const looked = p.shots.length;
    p.state.face = "typed";
    run.nudge();
    await p.settle();
    expect(p.shots.length).toBe(looked + 1);
    expect(p.sent.map((s) => s.face).pop()).toBe("typed");
    await p.ack();
    expect(p.waits.at(-1)).toBe(SHOT_EVERY_MS);
    await run.stop();
  });

  it("goes on past a look that fails (between two documents), and ends when stopped or when the page is gone", async () => {
    const p = page();
    p.state.failing = true;
    const run = new PictureRun(p.source, { quality: 60, maxWidth: 1280 });
    await p.settle();
    expect(p.sent).toEqual([]);
    p.state.failing = false;
    await p.next();
    expect(p.sent.map((s) => s.face)).toEqual(["a"]);
    expect(p.shots).toEqual(["css", "css"]);
    await p.ack();
    await run.stop();
    const looked = p.shots.length;
    await p.next();
    expect(p.shots.length).toBe(looked);
    // A page that closed: its run ends by itself.
    const q = page();
    const gone = new PictureRun(q.source, { quality: 60 });
    await q.settle();
    q.state.closed = true;
    await q.ack();
    await q.next();
    const before = q.shots.length;
    await q.next();
    expect(q.shots.length).toBe(before);
    await gone.stop();
  });
});


// ---- which browser the host starts ----
import { launchFailure } from "../src/browser/host.js";
import { CAMOUFOX_PROFILE_SUFFIX, camoufoxLaunchFailure, engineDriver } from "../src/browser/setup.js";
import { camoufoxLaunchOptions } from "../src/browser/camoufoxDriver.js";
import { Forwarder } from "../src/browser/forwarder.js";
import { bundledPlaywright } from "../src/browser/engine/loader.js";
import type { EngineKit } from "../src/browser/engine/kit.js";
import type { BrowserDriver, LaunchOptions } from "../src/browser/driver.js";

describe("which browser the host starts (docs/browser-v0.md §7.2 第 2 条)", () => {
  const launch: LaunchOptions = { profileDir: "/p/main", guard: async () => ({ action: "continue" }) };

  it("Chrome while no Camoufox is installed, on Chrome's own profile, the forwarder not started", async () => {
    const started: LaunchOptions[] = [];
    const chrome: BrowserDriver = { launch: async (o) => { started.push(o); return { marker: "chrome" } as never; } };
    const forwarder = new Forwarder({ ownPorts: () => [] });
    const none = engineDriver({ chrome, forwarder, headless: true });
    expect(none.engine()).toBe("chrome");
    expect(await none.launch(launch)).toEqual({ marker: "chrome" });
    // The engine is asked first at every start: that is where one is fetched when there is none (kit.ts `ensure`).
    let asked = 0;
    await engineDriver({ kit: { executable: () => null, playwright: bundledPlaywright, ensure: async () => { asked += 1; } } as unknown as EngineKit, chrome: { launch: async () => ({}) as never }, forwarder: new Forwarder({ ownPorts: () => [] }), headless: true }).launch({ profileDir: "/tmp/x" } as never);
    expect(asked).toBe(1);
    const notYet = engineDriver({ kit: { executable: () => null, playwright: bundledPlaywright, ensure: async () => undefined } as unknown as EngineKit, chrome, forwarder, headless: true });
    expect(notYet.engine()).toBe("chrome");
    await notYet.launch(launch);
    expect(started).toEqual([launch, launch]);
    expect(forwarder.stats().requests).toBe(0);
  });

  it("Camoufox once it is installed (asked at every start), on a profile of its own", () => {
    let program: string | null = null;
    const d = engineDriver({ kit: { executable: () => program, playwright: bundledPlaywright, ensure: async () => undefined } as unknown as EngineKit, chrome: { launch: async () => ({}) as never }, forwarder: new Forwarder({ ownPorts: () => [] }), headless: true });
    expect(d.engine()).toBe("chrome");
    program = "/engine/camoufox";
    expect(d.engine()).toBe("camoufox");
    expect(CAMOUFOX_PROFILE_SUFFIX).toBe("-camoufox");
  });

  it("a Camoufox that will not start is reported as Camoufox, with where to put it right — not as a missing Chrome", async () => {
    const where = "可在 Browser 页状态栏右端的引擎一栏重新下载。";
    expect(camoufoxLaunchFailure(new Error("browserType.launchPersistentContext: Failed to launch: Error: spawn /engine/camoufox ENOENT"))).toBe(`未找到 Camoufox 的程序。${where}`);
    expect(camoufoxLaunchFailure(new Error("browserType.launchPersistentContext: Protocol error (Browser.setDefaultViewport): ERROR: method not found\nCall log:\n  - <launching>")))
      .toBe(`Camoufox 未能启动：browserType.launchPersistentContext: Protocol error (Browser.setDefaultViewport): ERROR: method not found。${where}`);
    // The program named is not there: the host is told in those words (a plain ENOENT would read as a missing Chrome).
    const forwarder = new Forwarder({ ownPorts: () => [] });
    const d = engineDriver({ kit: { executable: () => "/nowhere/camoufox", playwright: bundledPlaywright, ensure: async () => undefined } as unknown as EngineKit, chrome: { launch: async () => ({}) as never }, forwarder, headless: true });
    try {
      const err = await d.launch(launch).then(() => null, (e: unknown) => e);
      expect(launchFailure(err)).toBe(`未找到 Camoufox 的程序。${where}`);
    } finally {
      await forwarder.stop();
    }
  });

  it("starts Camoufox with its sign-in memory off, the page left to see the Mac's own settings, and everything through the forwarder", () => {
    const o = camoufoxLaunchOptions({ executable: "/engine/camoufox", playwright: bundledPlaywright(), headless: true, config: { "navigator.hardwareConcurrency": 8 },
      proxy: { server: "http://127.0.0.1:5555", username: "agentswitch", password: "pw" } }, { PATH: "/usr/bin" });
    expect(o).toMatchObject({ executablePath: "/engine/camoufox", headless: true, viewport: null, acceptDownloads: false, colorScheme: "no-override", reducedMotion: "no-override",
      proxy: { server: "http://127.0.0.1:5555", username: "agentswitch", password: "pw" } });
    expect(o.env).toEqual({ PATH: "/usr/bin", CAMOU_CONFIG_1: '{"navigator.hardwareConcurrency":8}' });
    expect(o.firefoxUserPrefs).toMatchObject({ "signon.rememberSignons": false, "signon.autofillForms": false, "network.proxy.allow_hijacking_localhost": true });
    const plain = camoufoxLaunchOptions({ executable: "/engine/camoufox", playwright: bundledPlaywright(), headless: false }, {});
    expect(plain.proxy).toBeUndefined();
    expect(plain.headless).toBe(false);
    expect((plain.firefoxUserPrefs as Record<string, unknown>)["network.proxy.allow_hijacking_localhost"]).toBeUndefined();
  });
});
