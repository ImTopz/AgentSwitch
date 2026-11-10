/** Where the frame around what an agent just acted on stands as the page moves (docs/browser-v0.md §8). The box is
 *  measured once, in the page's CSS pixels from the corner of what was then in view; the screens draw it over the
 *  picture they have. A page scrolled since shows the element somewhere else, or not at all — and the frame stayed
 *  where it was, on whatever had come under it (2026-11-10, user: 标注agent点击操作的框很多时候也会错位). */

import type { Box } from "./types.js";

/** How far a page is scrolled, in CSS pixels. */
export type Scroll = { readonly x: number; readonly y: number };

/** A box with how far its page was scrolled when it was measured. */
export type MeasuredBox = Box & { readonly scroll?: Scroll };

/** `box`, measured with the page scrolled to `measured`, as it stands with the page at `now`; null when no part of it
 *  is in a view of `view` (nothing to put a frame around). */
export function boxNow(box: Box, measured: Scroll, now: Scroll, view: { readonly width: number; readonly height: number }): Box | null {
  const x = box.x + measured.x - now.x, y = box.y + measured.y - now.y;
  if (x >= view.width || y >= view.height || x + box.width <= 0 || y + box.height <= 0) return null;
  return { x, y, width: box.width, height: box.height };
}

export const sameBox = (a: Box | undefined | null, b: Box | undefined | null): boolean =>
  (!a && !b) || (!!a && !!b && a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height);
