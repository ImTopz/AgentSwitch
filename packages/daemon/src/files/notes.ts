/** The attachments paragraph appended to what the router and the executor read. */

import { isAbsolute } from "node:path";
import { formatBytes } from "./names.js";
import type { Attachment } from "./uploads.js";

export function attachmentsNote(attachments: readonly Attachment[]): string {
  if (!attachments.length) return "";
  const lines = attachments.map((a) => `- ${a.path} (${formatBytes(a.size)}, ${a.type})`);
  const where = attachments.every((a) => isAbsolute(a.path)) ? "absolute paths, outside the working directory" : "paths relative to the working directory";
  return `\n\nAttached files (${where}; read them, they are part of the task):\n${lines.join("\n")}`;
}

/** Where this task's files for the user go: said in every executor's prompt, the path being the task's own. */
export function handOverNote(outDir: string): string {
  return `Files for the user: anything the user should get back as a file (images, documents, exports), a file that already exists included, is written or copied into this folder, which is outside the working directory:\n${outDir}\nThat is the only way a file reaches the user. Do not create an out/ or in/ folder in the working directory. Name the files you put there in your reply.`;
}
