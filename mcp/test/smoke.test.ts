import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { getDefaultEnvironment, StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { README_PATH, renderToolsBlock, spliceReadme } from "../scripts/tools-table";
import { redactAgentsConfig } from "../src/resources";
import { toolRegistry } from "../src/lib";
import { createServer } from "../src/server";

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
let configDir = "";

function childEnv(overrides: Record<string, string>): Record<string, string> {
  return {
    ...getDefaultEnvironment(),
    APPLE_TASKS_BIN: fakeBin,
    APPLE_TASKS_CONFIG_DIR: configDir,
    FAKE_ARGV_LOG: argvLog,
    ...overrides,
  };
}

/** A scratch ~/.config/apple-tasks with one run log, one recipe, and an agents.json carrying secrets. */
async function seedConfigDir(dir: string): Promise<void> {
  await mkdir(path.join(dir, "runs"), { recursive: true });
  await mkdir(path.join(dir, "recipes"), { recursive: true });
  const lines = Array.from({ length: 300 }, (_, i) => `line ${i + 1}`);
  await writeFile(path.join(dir, "runs/7.log"), lines.join("\n") + "\n");
  await writeFile(
    path.join(dir, "recipes/demo.json"),
    JSON.stringify({ id: "demo", name: "Demo", title: "Do the demo", agent: "auto" }) + "\n"
  );
  await writeFile(
    path.join(dir, "agents.json"),
    JSON.stringify({
      agents: { claude: { command: ["claude"], env: { ANTHROPIC_API_KEY: "sk-live-123" } } },
      llm: { provider: "openai", apiKey: "sk-openai-456" },
      ntfy: { topic: "public-topic", token: "tk-789" },
      claimGuard: "modified",
    })
  );
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

function promptText(result: { messages: Array<{ content: { type: string; text?: string } }> }): string {
  return result.messages
    .map((m) => (m.content.type === "text" ? (m.content.text ?? "") : ""))
    .join("\n");
}

describe("apple-tasks MCP smoke", () => {
  let client: Client;

  beforeAll(async () => {
    tmpDir = await mkdtemp(path.join(tmpdir(), "apple-mcp-smoke-"));
    argvLog = path.join(tmpDir, "argv.log");
    configDir = path.join(tmpDir, "config");
    await writeFile(argvLog, "");
    await seedConfigDir(configDir);
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

  test("tools/list returns ≥ 57 described tools with input schemas", async () => {
    const { tools } = await client.listTools();
    expect(tools.length).toBeGreaterThanOrEqual(57);
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
    expect(byName.dispatch_discard?.annotations?.destructiveHint).toBe(true);
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

  test("dispatch_run passes reap_hours and no_gc", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({ name: "dispatch_run", arguments: { reap_hours: 3, no_gc: true } });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("--reap-hours 3") && line.includes("--no-gc"))).toBe(true);
  });

  test("dispatch_pause/resume/status map to the flat CLI verbs", async () => {
    const before = await readFile(argvLog, "utf8");
    const paused = await client.callTool({
      name: "dispatch_pause",
      arguments: { for_duration: "2h", reason: "probe" },
    });
    await client.callTool({ name: "dispatch_status", arguments: {} });
    await client.callTool({ name: "dispatch_resume", arguments: {} });
    const lines = await argvSince(before);
    expect(lines).toContain("dispatch-pause --for 2h --reason probe");
    expect(lines).toContain("dispatch-status");
    expect(lines).toContain("dispatch-resume");
    const structured =
      paused && typeof paused === "object" && "structuredContent" in paused
        ? (paused.structuredContent as { paused?: unknown; until?: unknown } | undefined)
        : undefined;
    expect(structured?.paused).toBe(true);
    expect(structured?.until).toBe("2026-09-08T12:00:00Z");
  });

  test("task_create native_tags:false adds --no-native-tags", async () => {
    const beforeOff = await readFile(argvLog, "utf8");
    await client.callTool({
      name: "task_create",
      arguments: { list: "Inbox", title: "x", native_tags: false },
    });
    const offLines = await argvSince(beforeOff);
    expect(offLines.some((line) => line.includes("--no-native-tags"))).toBe(true);

    const beforeDefault = await readFile(argvLog, "utf8");
    await client.callTool({ name: "task_create", arguments: { list: "Inbox", title: "x" } });
    const defaultLines = await argvSince(beforeDefault);
    expect(defaultLines.some((line) => line.includes("--no-native-tags"))).toBe(false);
  });

  test("task_create_batch native_tags:false adds --no-native-tags", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({
      name: "task_create_batch",
      arguments: { items: [{ list: "Inbox", title: "x" }], native_tags: false },
    });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("add-batch --no-native-tags"))).toBe(true);
  });

  test("task_update passes --mirror-tags and --no-native-tags", async () => {
    const before = await readFile(argvLog, "utf8");
    await client.callTool({
      name: "task_update",
      arguments: { id: "T1", mirror_tags: true, native_tags: false },
    });
    const lines = await argvSince(before);
    expect(lines.some((line) => line.includes("--mirror-tags") && line.includes("--no-native-tags"))).toBe(
      true
    );
  });

  test("task_remirror_tags dry-run wraps reports", async () => {
    const before = await readFile(argvLog, "utf8");
    const result = await client.callTool({
      name: "task_remirror_tags",
      arguments: { dry_run: true, list: "Inbox", tags: ["claude"], status: "all", id: "T1" },
    });
    const lines = await argvSince(before);
    expect(lines).toContain("remirror-tags --dry-run --list Inbox --tag claude --status all --id T1");
    const structured =
      result && typeof result === "object" && "structuredContent" in result
        ? (result.structuredContent as { reports?: Array<{ duplicatesRemoved?: unknown }> } | undefined)
        : undefined;
    expect(structured?.reports?.length).toBe(1);
    expect(structured?.reports?.[0]?.duplicatesRemoved).toBe(1);
  });

  test("resources/list includes static URIs and templates", async () => {
    const { resources } = await client.listResources();
    const uris = resources.map((r) => r.uri);
    expect(uris).toContain("apple-tasks://config/agents");
    expect(uris).toContain("apple-tasks://doctor");
    // SDK folds ResourceTemplate list-callback results into resources/list.
    expect(uris).toContain("apple-tasks://runs/7");
    expect(uris).toContain("apple-tasks://recipes/demo");

    const { resourceTemplates } = await client.listResourceTemplates();
    const templates = resourceTemplates.map((t) => t.uriTemplate);
    expect(templates).toContain("apple-tasks://runs/{id}");
    expect(templates).toContain("apple-tasks://recipes/{id}");
  });

  test("readResource run log returns the last 200 lines", async () => {
    const { contents } = await client.readResource({ uri: "apple-tasks://runs/7" });
    const text = contents.map((c) => ("text" in c ? c.text : "")).join("");
    expect(text.endsWith("line 300")).toBe(true);
    expect(text).toContain("line 101");
    expect(text).not.toContain("line 100\n");
  });

  test("readResource recipe validates ids", async () => {
    const { contents } = await client.readResource({ uri: "apple-tasks://recipes/demo" });
    const text = contents.map((c) => ("text" in c ? c.text : "")).join("");
    expect(JSON.parse(text).id).toBe("demo");
    await expect(client.readResource({ uri: "apple-tasks://recipes/Bad%20Id" })).rejects.toThrow();
    await expect(client.readResource({ uri: "apple-tasks://recipes/.." })).rejects.toThrow();
  });

  test("readResource agents.json redacts secrets", async () => {
    const { contents } = await client.readResource({ uri: "apple-tasks://config/agents" });
    const text = contents.map((c) => ("text" in c ? c.text : "")).join("");
    const parsed = JSON.parse(text) as {
      agents: { claude: { env: { ANTHROPIC_API_KEY: string } } };
      llm: { apiKey: string };
      ntfy: { token: string; topic: string };
      claimGuard: string;
    };
    expect(parsed.agents.claude.env.ANTHROPIC_API_KEY).toBe("[redacted]");
    expect(parsed.llm.apiKey).toBe("[redacted]");
    expect(parsed.ntfy.token).toBe("[redacted]");
    expect(parsed.ntfy.topic).toBe("public-topic");
    expect(parsed.claimGuard).toBe("modified");
    expect(text).not.toContain("sk-live-123");
    expect(text).not.toContain("sk-openai-456");
    expect(text).not.toContain("tk-789");
  });

  test("readResource doctor runs the CLI", async () => {
    const before = await readFile(argvLog, "utf8");
    const { contents } = await client.readResource({ uri: "apple-tasks://doctor" });
    const text = contents.map((c) => ("text" in c ? c.text : "")).join("");
    expect(text).toBe('{"ok":true}');
    const lines = await argvSince(before);
    expect(lines.some((line) => line === "doctor" || line.startsWith("doctor "))).toBe(true);
  });

  test("prompts/list and getPrompt cover the four operator prompts", async () => {
    const { prompts } = await client.listPrompts();
    expect(prompts.map((p) => p.name).sort()).toEqual(
      ["morning_digest", "supervisor_loop", "task_writer", "triage_inbox"].sort()
    );

    const writer = await client.getPrompt({ name: "task_writer", arguments: { goal: "fix login" } });
    expect(writer.messages.length).toBe(1);
    expect(writer.messages[0]?.role).toBe("user");
    const writerText = promptText(writer);
    expect(writerText).toContain("fix login");
    expect(writerText).toContain("task_create");

    const apply = await client.getPrompt({
      name: "triage_inbox",
      arguments: { inbox: "Inbox", apply: "true" },
    });
    expect(promptText(apply)).toContain('triage_inbox(inbox: "Inbox", dry_run: false)');

    const dry = await client.getPrompt({ name: "triage_inbox", arguments: {} });
    expect(promptText(dry)).toContain("dry_run: true");
  });

  test("README tools table matches the registry", async () => {
    if (toolRegistry.length === 0) createServer();
    const readme = await readFile(README_PATH, "utf8");
    expect(spliceReadme(readme, renderToolsBlock()), "stale README — run `bun run tools:table`").toBe(
      readme
    );
  });
});

describe("redactAgentsConfig", () => {
  test("preserves arrays, non-secrets, empty secrets, and numbers; redacts nested env", () => {
    const input = {
      keep: "visible",
      count: 7,
      token: "",
      items: [
        { title: "ok", env: { FOO: "bar", NESTED: "secret" } },
        { apiKey: "sk-should-hide", note: "fine" },
      ],
    };
    const out = redactAgentsConfig(input) as {
      keep: string;
      count: number;
      token: string;
      items: Array<{ title?: string; env?: Record<string, string>; apiKey?: string; note?: string }>;
    };
    expect(Array.isArray(out.items)).toBe(true);
    expect(out.items).toHaveLength(2);
    expect(out.keep).toBe("visible");
    expect(out.token).toBe("");
    expect(out.count).toBe(7);
    expect(out.items[0]?.title).toBe("ok");
    expect(out.items[0]?.env).toEqual({ FOO: "[redacted]", NESTED: "[redacted]" });
    expect(out.items[1]?.apiKey).toBe("[redacted]");
    expect(out.items[1]?.note).toBe("fine");
  });
});
