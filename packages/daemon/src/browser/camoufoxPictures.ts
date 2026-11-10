/** The pictures of a Camoufox page for the screens that watch it (docs/browser-v0.md §7.3 驱动, §8): screenshots of
 *  what the page shows now, one after another, each sent on once the host acknowledged the one before.
 *
 *  Until 2026-11-10 they were `page.screencast`'s frames. In a Camoufox with windows that is drawn by its own Juggler
 *  (`_startSnapshotScreencast`) from the document's top-left corner — `drawSnapshot(new DOMRect(0, 0, width, height))`,
 *  a rectangle of the document, not of what is in view — so a page scrolled anywhere was shown at its top: another
 *  node or a phone saw the first screenful whatever the window showed, bars fixed to the window's edge were missing,
 *  and the frame around what an agent had just clicked (measured in the window) stood on something else. The Mac that
 *  holds the browser shows its real window and never saw it (user: 浏览器在另一个机器上看的时候经常显示不全，然后
 *  标注agent点击操作的框很多时候也会错位). A screenshot is of what is in view: Playwright adds the scroll itself.
 *
 *  A screenshot comes at the page's own pixels or at one per CSS pixel, nothing between: the page's own when the
 *  watchers take that many (`shotScale`), else one per CSS pixel. */

import type { ScreencastParams } from "./driver.js";

/** What a page shows now: its view's size and how far it is scrolled, in CSS pixels. */
export type Shown = { readonly width: number; readonly height: number; readonly x: number; readonly y: number };

/** At the page's own pixels when the watchers take that many, else at one per CSS pixel. */
export function shotScale(view: { readonly width: number; readonly height: number }, ratio: number, max: { readonly maxWidth?: number | undefined; readonly maxHeight?: number | undefined }): "device" | "css" {
  const r = Math.max(1, ratio || 1);
  if (max.maxWidth && view.width * r > max.maxWidth + 1) return "css";
  if (max.maxHeight && view.height * r > max.maxHeight + 1) return "css";
  return "device";
}

/** A page that moves is looked at this often at most (the host's acknowledgements pace it below that: a stream that
 *  asks 15 a second gets 15). 50 until 2026-11-11, which held every stream to 20 a second; a screen on the Mac that
 *  runs the browser asks 30 (user: 本地的想办法弄的更加高效)… */
export const SHOT_EVERY_MS = 33;
/** …and one that stands still less and less often, down to this: what begins to move is seen within it. */
export const SHOT_STILL_MS = 400;

export type PictureSource = {
  /** What the page shows now. */
  readonly shown: () => Promise<Shown>;
  readonly shot: (scale: "device" | "css", quality: number) => Promise<Buffer>;
  /** A picture for the host; resolves once it acknowledged it. */
  readonly send: (data: string, shown: Shown) => Promise<void>;
  readonly ratio: () => number;
  readonly closed: () => boolean;
  readonly sleep?: (ms: number, woken: Promise<void>) => Promise<void>;
  readonly now?: () => number;
};

const defaultSleep = (ms: number, woken: Promise<void>): Promise<void> => {
  let timer: NodeJS.Timeout;
  return Promise.race([new Promise<void>((resolve) => { timer = setTimeout(resolve, ms); timer.unref(); }), woken]).finally(() => clearTimeout(timer));
};

/** One run of pictures: from `start` until `stop`. A picture the same as the one before, of the same place, is not
 *  sent again — a page that stands still sends nothing, as with Chrome. */
export class PictureRun {
  private stopped = false;
  private wake: (() => void) | null = null;
  private readonly done: Promise<void>;

  constructor(private readonly source: PictureSource, private readonly params: ScreencastParams) {
    this.done = this.run().catch(() => undefined);
  }

  /** Something was just done to the page: it is looked at now, not when its turn comes. */
  nudge(): void {
    this.still = SHOT_EVERY_MS;
    this.wake?.();
  }

  stop(): Promise<void> {
    this.stopped = true;
    this.wake?.();
    return this.done;
  }

  private still = SHOT_EVERY_MS;

  private live(): boolean { return !this.stopped && !this.source.closed(); }

  private async run(): Promise<void> {
    const { source, params } = this;
    const now = source.now ?? Date.now;
    const sleep = source.sleep ?? defaultSleep;
    let last = "", place = "";
    while (this.live()) {
      const began = now();
      let sent = false;
      try {
        const shown = await source.shown();
        if (!this.live()) return;
        const shot = await source.shot(shotScale(shown, source.ratio(), params), params.quality);
        if (!this.live()) return;
        const data = shot.toString("base64");
        const at = `${shown.width}x${shown.height}@${shown.x},${shown.y}`;
        if (data !== last || at !== place) {
          last = data;
          place = at;
          sent = true;
          await source.send(data, shown);
        }
      } catch { /* between two documents, or closing: the next look */ }
      if (!this.live()) return;
      this.still = sent ? SHOT_EVERY_MS : Math.min(SHOT_STILL_MS, this.still * 2);
      const woken = new Promise<void>((resolve) => { this.wake = resolve; });
      await sleep(Math.max(0, this.still - (now() - began)), woken);
      this.wake = null;
    }
  }
}
