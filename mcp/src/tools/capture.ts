import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { defineTool } from "../lib";
import { watchItemShape } from "../schemas";

export function registerCaptureTools(server: McpServer): void {
  defineTool(server, {
    name: "screenshots_scan",
    description:
      "OCR screenshots/images modified since the last scan (watermark auto-advances; first run looks back 24h). " +
      "On-device Vision, read-only. Returns {file, modified, text} per image. Use to turn 'screenshot it to deal " +
      "with later' captures into tasks/events (task_create/event_create); keep the file path as provenance.",
    input: {
      dir: z.string().optional().describe("Folder to scan (default: ~/Desktop)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each image's text (default 4000)."),
    },
    // ScreenshotOut (Sources/AppleTasks/Screenshots.swift)
    output: {
      screenshots: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        text: z.string().describe("Recognized text; empty when the image has none."),
      })),
    },
    annotations: { title: "Scan screenshots", readOnlyHint: true },
    timeoutMs: 120_000, // OCR of many images can be slow
    argv: ({ dir, since, max_chars }) => {
      const args = ["screenshots", "scan"];
      if (dir) args.push("--dir", dir);
      if (since) args.push("--since", since);
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
    wrap: (parsed) => ({ screenshots: parsed }),
  });

  defineTool(server, {
    name: "files_scan",
    description:
      "Read .txt/.md files dropped in the iCloud inbox folder since the last scan (watermark auto-advances; " +
      "first run looks back 24h). The universal capture escape hatch — any device drops a file, this emits " +
      "{file, modified, content}. Set archive:true to move processed files into a done/ subfolder.",
    input: {
      dir: z.string().optional().describe("Folder to scan (default: iCloud Drive/AgentInbox)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each file's content (default 8000)."),
      archive: z.boolean().optional().describe("Move processed files into a done/ subfolder."),
    },
    // FileDropOut (Sources/AppleTasks/Files.swift)
    output: {
      files: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        content: z.string(),
        archivedTo: z.string().optional().describe("Destination path when archive: true."),
      })),
    },
    // Not readOnly: archive: true moves the scanned files.
    annotations: { title: "Scan files", readOnlyHint: false, destructiveHint: false },
    argv: ({ dir, since, max_chars, archive }) => {
      const args = ["files", "scan"];
      if (dir) args.push("--dir", dir);
      if (since) args.push("--since", since);
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      if (archive) args.push("--archive");
      return args;
    },
    wrap: (parsed) => ({ files: parsed }),
  });

  defineTool(server, {
    name: "audio_scan",
    description:
      "Transcribe audio notes dropped in the iCloud inbox folder since the last scan (watermark " +
      "auto-advances; first run looks back 24h). On-device Speech recognition; emits {file, modified, " +
      "transcript, error?}. Failed files are retried next scan. Set archive:true to move transcribed " +
      "files into a done/ subfolder.",
    input: {
      dir: z.string().optional().describe("Folder to scan (default: iCloud Drive/AgentInbox)."),
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_chars: z.number().int().optional().describe("Truncate each transcript (default 4000)."),
      archive: z.boolean().optional().describe("Move transcribed files into a done/ subfolder."),
    },
    // AudioOut (Sources/AppleTasks/Audio.swift)
    output: {
      recordings: z.array(z.object({
        file: z.string(),
        modified: z.string(),
        transcript: z.string().optional().describe("Absent when transcription failed (see error)."),
        archivedTo: z.string().optional().describe("Destination path when archive: true."),
        error: z.string().optional(),
      })),
    },
    // Not readOnly: archive: true moves the scanned files.
    annotations: { title: "Scan audio", readOnlyHint: false, destructiveHint: false },
    timeoutMs: 300_000, // transcription of many memos can be slow
    argv: ({ dir, since, max_chars, archive }) => {
      const args = ["audio", "scan"];
      if (dir) args.push("--dir", dir);
      if (since) args.push("--since", since);
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      if (archive) args.push("--archive");
      return args;
    },
    wrap: (parsed) => ({ recordings: parsed }),
  });

  defineTool(server, {
    name: "readinglist_scan",
    description:
      "Read Safari Reading List items added since the last scan (watermark auto-advances; first run looks " +
      "back 24h). Emits {title, url, dateAdded, previewText}, oldest first. Requires Full Disk Access for " +
      "the host process; the doctor command reports FDA status. Read-only.",
    input: {
      since: z.string().optional().describe(
        "Override watermark (yyyy-MM-dd, 'yyyy-MM-dd HH:mm', or ISO8601). Stateless: does not advance the stored watermark."
      ),
      max_items: z.number().int().optional().describe("Limit output to this many items (default 50)."),
    },
    // ReadingListItemOut (Sources/AppleTasks/ReadingList.swift)
    output: {
      items: z.array(z.object({
        title: z.string(),
        url: z.string(),
        dateAdded: z.string(),
        previewText: z.string().optional(),
      })),
    },
    annotations: { title: "Scan Reading List", readOnlyHint: true },
    argv: ({ since, max_items }) => {
      const args = ["reading-list", "scan"];
      if (since) args.push("--since", since);
      if (max_items !== undefined) args.push("--max-items", String(max_items));
      return args;
    },
    wrap: (parsed) => ({ items: parsed }),
  });

  defineTool(server, {
    name: "clipboard_scan",
    description:
      "Emit the clipboard's text if it changed since the last scan (changeCount watermark). At most one " +
      "clipping per call — the pasteboard has no history. Password-manager/transient clippings are never " +
      "surfaced, and the first call only records a baseline. Feed hits to triage like any capture channel.",
    input: {
      max_chars: z.number().int().optional().describe("Truncate the clipping (default 4000)."),
    },
    // ClippingOut (Sources/AppleTasks/Clipboard.swift)
    output: {
      clippings: z.array(z.object({
        ts: z.string(),
        content: z.string(),
        truncated: z.boolean(),
      })),
    },
    annotations: { title: "Scan clipboard", readOnlyHint: true },
    argv: ({ max_chars }) => {
      const args = ["clipboard", "scan"];
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
    wrap: (parsed) => ({ clippings: parsed }),
  });

  defineTool(server, {
    name: "watch_scan",
    description:
      "Fetch each due topic watch (RSS feeds / web pages from ~/.config/apple-tasks/watches.json) and emit " +
      "items new since the last scan. Per-watch cadence and seen-state; first run records a baseline. " +
      "Failed watches are reported per-watch, never fatal.",
    input: {
      watch: z.string().optional().describe("Only scan this watch (by name)."),
      force: z.boolean().optional().describe("Fetch every watch now, ignoring cadence."),
      max_items: z.number().int().optional().describe("Per-watch cap on emitted items (default 20)."),
    },
    output: {
      scannedAt: z.string(),
      items: z.array(z.object(watchItemShape)),
      watches: z.array(z.object({
        name: z.string(),
        status: z.string().describe("'ok', 'skipped: not due', 'baseline recorded', or 'error: ...'."),
        newItems: z.number().int(),
      })),
    },
    annotations: { title: "Scan watches", readOnlyHint: true, openWorldHint: true },
    timeoutMs: 120_000, // N sequential fetches
    argv: ({ watch, force, max_items }) => {
      const args = ["watch", "scan"];
      if (watch) args.push("--watch", watch);
      if (force) args.push("--force");
      if (max_items !== undefined) args.push("--max-items", String(max_items));
      return args;
    },
  });

  defineTool(server, {
    name: "watch_list",
    description: "Show configured topic watches and their scan state (last fetch, due now?).",
    input: {},
    output: {
      watches: z.array(z.object({
        name: z.string(),
        kind: z.enum(["rss", "url"]),
        url: z.string(),
        cadenceMinutes: z.number().int(),
        lastFetch: z.string().optional(),
        due: z.boolean(),
      })),
    },
    annotations: { title: "List watches", readOnlyHint: true },
    argv: () => ["watch", "list"],
    wrap: (parsed) => ({ watches: parsed }),
  });

  defineTool(server, {
    name: "web_fetch",
    description:
      "Fetch a URL and return {url, status, title, text} with HTML reduced to readable text. Minimal web " +
      "primitive for agents without their own web access; prefer your native web tools if you have them.",
    input: {
      url: z.string().describe("http(s) URL to fetch."),
      max_chars: z.number().int().optional().describe("Truncate extracted text (default 4000)."),
    },
    output: {
      url: z.string(),
      status: z.number().int(),
      contentType: z.string().optional(),
      title: z.string().optional(),
      text: z.string(),
      truncated: z.boolean(),
    },
    annotations: { title: "Fetch web page", readOnlyHint: true, openWorldHint: true },
    timeoutMs: 60_000,
    argv: ({ url, max_chars }) => {
      const args = ["web", "fetch", url];
      if (max_chars !== undefined) args.push("--max-chars", String(max_chars));
      return args;
    },
  });
}
