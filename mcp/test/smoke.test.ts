import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { getDefaultEnvironment, StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const mcpRoot = path.resolve(here, "..");
const serverEntry = path.join(mcpRoot, "src/server.ts");
const fakeBin = path.join(here, "fixtures/fake-apple-tasks.sh");

type Session = {
  client: Client;
  transport: StdioClientTransport;
};

const sessions: Session[] = [];
let tmpDir = "";
let argvLog = "";

function childEnv(overrides: Record<string, string>): Record<string, string> {
  return {
    ...getDefaultEnvironment(),
    APPLE_TASKS_BIN: fakeBin,
    FAKE_ARGV_LOG: argvLog,
    ...overrides,
  };
}

async function startServer(overrides: Record<string, string> = {}): Promise<Session> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    env: childEnv(overrides),
    cwd: mcpRoot,
    stderr: "pipe",
  });
  const client = new Client({ name: "apple-tasks-smoke", version: "0.0.0" });
  await client.connect(transport);
  const session = { client, transport };
  sessions.push(session);
  return session;
}

async function closeSession(session: Session): Promise<void> {
  try {
    await session.client.close();
  } catch {
    // already closed
  }
  try {
    await session.transport.close();
  } catch {
    // already closed
  }
  const pid = session.transport.pid;
  if (pid != null) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // already dead
    }
  }
}

async function argvSince(before: string): Promise<string[]> {
  const after = await readFile(argvLog, "utf8");
  return after.slice(before.length).split("\n").filter(Boolean);
}

function textOf(result: unknown): string {
  if (!result || typeof result !== "object" || !("content" in result)) return "";
  const content = (result as { content?: unknown }).content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } =>
      Boolean(part && typeof part === "object" && (part as { type?: unknown }).type === "text")
    )
    .map((part) => part.text ?? "")
    .join("\n");
}

describe("apple-tasks MCP smoke", () => {
  let client: Client;

  beforeAll(async () => {
    tmpDir = await mkdtemp(path.join(tmpdir(), "apple-mcp-smoke-"));
    argvLog = path.join(tmpDir, "argv.log");
    await writeFile(argvLog, "");
    const session = await startServer();
    client = session.client;
  });

  afterAll(async () => {
    await Promise.all(sessions.map(closeSession));
    sessions.length = 0;
    if (tmpDir) {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  test("tools/list returns ≥ 51 described tools with input schemas", async () => {
    const { tools } = await client.listTools();
    expect(tools.length).toBeGreaterThanOrEqual(51);
    for (const tool of tools) {
      expect(tool.description, tool.name).toBeTruthy();
      expect(tool.inputSchema, tool.name).toBeDefined();
    }
  });

  test("every tool has annotations with a title and at least one hint", async () => {
    const { tools } = await client.listTools();
    for (const tool of tools) {
      expect(tool.annotations, tool.name).toBeDefined();
      expect(tool.annotations?.title, tool.name).toBeTruthy();
      const hints = [
        tool.annotations?.readOnlyHint,
        tool.annotations?.destructiveHint,
        tool.annotations?.idempotentHint,
        tool.annotations?.openWorldHint,
      ];
      expect(hints.some((h) => h !== undefined), tool.name).toBe(true);
    }
  });

  test("task_list is read-only; dispatch_run and task_delete are destructive", async () => {
    const { tools } = await client.listTools();
    const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
    expect(byName.task_list?.annotations?.readOnlyHint).toBe(true);
    expect(byName.dispatch_run?.annotations?.destructiveHint).toBe(true);
    expect(byName.task_delete?.annotations?.destructiveHint).toBe(true);
  });

  test("tools/list matches golden except for annotations", async () => {
    const { tools } = await client.listTools();
    const stripped = [...tools]
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((tool) => {
        const { annotations: _annotations, ...rest } = tool;
        return rest;
      });
    const goldenPath = path.join(here, "fixtures/tools-list.golden.json");
    if (process.env.UPDATE_GOLDEN) {
      // Intentional tool additions/changes: `bun run test:update-golden`.
      await writeFile(goldenPath, JSON.stringify(stripped, null, 2) + "\n");
      return;
    }
    const golden = JSON.parse(await readFile(goldenPath, "utf8")) as typeof stripped;
    expect(stripped).toEqual(golden);
  });

  test("task_list returns one Inbox task and logs list --list Inbox", async () => {
    const before = await readFile(argvLog, "utf8");
    const result = await client.callTool({
      name: "task_list",
      arguments: { list: "Inbox" },
    });
    expect("structuredContent" in result).toBe(true);
    const structured =
      result && typeof result === "object" && "structuredContent" in result
        ? (result.structuredContent as Record<string, unknown> | undefined)
        : undefined;
    const tasks = structured?.tasks;
    expect(Array.isArray(tasks)).toBe(true);
    expect((tasks as unknown[]).length).toBe(1);
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("list --list Inbox"))).toBe(true);
  });

  test("dispatch_run {} defaults to --dry-run", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({ name: "dispatch_run", arguments: {} });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("dispatch") && line.includes("--dry-run"))).toBe(true);
  });

  test("dispatch_run {dry_run:false} omits --dry-run", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({ name: "dispatch_run", arguments: { dry_run: false } });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("dispatch"))).toBe(true);
    expect(lines.some((line) => line.includes("--dry-run"))).toBe(false);
  });

  test("dispatch_run refuses agent-spawned sessions", async () => {
    const session = await startServer({ APPLE_TASKS_CALLER: "agent:test" });
    const result = await session.client.callTool({ name: "dispatch_run", arguments: {} });
    expect("isError" in result && result.isError).toBe(true);
  });

  test("task_create_batch shells out to add-batch", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({
      name: "task_create_batch",
      arguments: { items: [{ list: "Inbox", title: "x" }] },
    });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("add-batch"))).toBe(true);
  });

  test("doctor surfaces CLI stderr and isError on non-zero exit", async () => {
    const session = await startServer({ FAKE_EXIT: "3" });
    const result = await session.client.callTool({ name: "doctor", arguments: {} });
    expect("isError" in result && result.isError).toBe(true);
    expect(textOf(result)).toContain("fake failure");
    const structured =
      result && typeof result === "object" && "structuredContent" in result
        ? (result.structuredContent as { exitCode?: unknown } | undefined)
        : undefined;
    expect(structured?.exitCode).toBe(3);
  });
});
