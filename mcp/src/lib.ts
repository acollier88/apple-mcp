import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolAnnotations } from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { z, type ZodRawShape, type ZodTypeAny } from "zod";

const execFileAsync = promisify(execFile);

export const BIN =
  process.env.APPLE_TASKS_BIN ??
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../cli/.build/release/apple-tasks");

export const DEFAULT_TIMEOUT_MS = 30_000;
export const STDIN_TIMEOUT_MS = 60_000;

export type CliOpts = { timeoutMs?: number };

export type ToolRecord = {
  name: string;
  description: string;
  annotations: ToolAnnotations;
};

export const toolRegistry: ToolRecord[] = [];

export type InferArgs<I extends ZodRawShape> = z.objectOutputType<I, ZodTypeAny>;

type ExecFileFailure = {
  message?: string;
  code?: unknown;
  stderr?: unknown;
  killed?: unknown;
  signal?: unknown;
};

function stderrOf(err: ExecFileFailure): string {
  if (typeof err.stderr === "string") return err.stderr.trim();
  if (Buffer.isBuffer(err.stderr)) return err.stderr.toString().trim();
  return "";
}

/** Attach execFile `code` / `stderr`; timeouts become `timeout after N ms`. */
function asCliError(err: unknown, timeoutMs: number): Error & { code?: number; stderr?: string } {
  const e = err as ExecFileFailure;
  const stderr = stderrOf(e);
  const timedOut = e.killed === true;
  const message = timedOut ? `timeout after ${timeoutMs} ms` : stderr || e.message || String(err);
  const wrapped = new Error(message) as Error & { code?: number; stderr?: string };
  if (typeof e.code === "number") wrapped.code = e.code;
  if (stderr) wrapped.stderr = stderr;
  return wrapped;
}

export async function cli(args: string[], opts: CliOpts = {}): Promise<string> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  try {
    const { stdout } = await execFileAsync(BIN, args, {
      timeout: timeoutMs,
      env: { ...process.env, APPLE_TASKS_CALLER: "mcp" },
    });
    return stdout.trim();
  } catch (err) {
    throw asCliError(err, timeoutMs);
  }
}

/** Like cli(), but feeds `input` to the child's stdin (used by add-batch). */
export async function cliInput(args: string[], input: string, opts: CliOpts = {}): Promise<string> {
  const timeoutMs = opts.timeoutMs ?? STDIN_TIMEOUT_MS;
  try {
    const pending = execFileAsync(BIN, args, {
      timeout: timeoutMs,
      env: { ...process.env, APPLE_TASKS_CALLER: "mcp" },
    });
    pending.child.stdin?.end(input);
    const { stdout } = await pending;
    return stdout.trim();
  } catch (err) {
    throw asCliError(err, timeoutMs);
  }
}

export function ok(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

/**
 * ok() plus structuredContent parsed from the CLI's JSON stdout. The MCP spec
 * requires structuredContent to be an object, so tools whose CLI output is a
 * top-level JSON array pass `wrap` to fold it into a single named key;
 * content[0].text always carries the raw CLI JSON unchanged.
 */
export function okJson(text: string, wrap?: (parsed: unknown) => unknown) {
  const parsed = JSON.parse(text) as unknown;
  return {
    content: [{ type: "text" as const, text }],
    structuredContent: (wrap ? wrap(parsed) : parsed) as Record<string, unknown>,
  };
}

export function fail(err: unknown) {
  const text = String(err instanceof Error ? err.message : err);
  const structured: { error: string; exitCode?: number; stderr?: string } = { error: text };
  if (err && typeof err === "object") {
    const e = err as { code?: unknown; stderr?: unknown };
    if (typeof e.code === "number") structured.exitCode = e.code;
    if (typeof e.stderr === "string" && e.stderr.length > 0) structured.stderr = e.stderr;
  }
  return {
    content: [{ type: "text" as const, text }],
    isError: true as const,
    structuredContent: structured,
  };
}

export function trackTool(name: string, description: string, annotations: ToolAnnotations): void {
  toolRegistry.push({ name, description, annotations });
}

export function defineTool<I extends ZodRawShape, O extends ZodRawShape>(
  server: McpServer,
  spec: {
    name: string;
    description: string;
    input: I;
    output?: O;
    annotations: ToolAnnotations;
    timeoutMs?: number;
    argv: (args: InferArgs<I>) => string[];
    stdin?: (args: InferArgs<I>) => string;
    wrap?: (parsed: unknown) => unknown;
  }
): void {
  const { name, description, input, output, annotations, timeoutMs, argv, stdin, wrap } = spec;
  trackTool(name, description, annotations);
  server.registerTool(
    name,
    {
      description,
      inputSchema: input,
      ...(output !== undefined ? { outputSchema: output } : {}),
      annotations,
    },
    (async (raw: InferArgs<I>) => {
      try {
        const args = raw as InferArgs<I>;
        const argvList = argv(args);
        const text = stdin
          ? await cliInput(argvList, stdin(args), { timeoutMs })
          : await cli(argvList, { timeoutMs });
        return okJson(text, wrap);
      } catch (e) {
        return fail(e);
      }
    }) as Parameters<McpServer["registerTool"]>[2]
  );
}
