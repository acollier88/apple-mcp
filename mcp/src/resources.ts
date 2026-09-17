import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import fs from "node:fs/promises";
import path from "node:path";
import { CONFIG_DIR, cli, readRunLogTail } from "./lib";

/**
 * Read-only MCP resources over the CLI's state dir. Tools remain the write
 * path; resources exist so hosts can attach a run log, the agent config, or a
 * recipe to context without a tool round-trip.
 */

const SECRET_KEY = /(key|token|secret|password|credential)/i;

/**
 * Redact agents.json for display: every value under an `env` object (agent
 * environments carry API keys wholesale) and any string whose key name looks
 * like a credential (`llm.apiKey`, `ntfy.token`, …).
 */
export function redactAgentsConfig(value: unknown, keyName = ""): unknown {
  if (Array.isArray(value)) return value.map((v) => redactAgentsConfig(v));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (k === "env" && v && typeof v === "object" && !Array.isArray(v)) {
        out[k] = Object.fromEntries(Object.keys(v as object).map((name) => [name, "[redacted]"]));
      } else {
        out[k] = redactAgentsConfig(v, k);
      }
    }
    return out;
  }
  if (typeof value === "string" && SECRET_KEY.test(keyName) && value.length > 0) return "[redacted]";
  return value;
}

const RECIPE_ID = /^[a-z0-9_-]+$/;

async function recipeIds(): Promise<string[]> {
  try {
    const names = await fs.readdir(path.join(CONFIG_DIR, "recipes"));
    return names
      .filter((n) => n.endsWith(".json"))
      .map((n) => n.slice(0, -".json".length))
      .filter((id) => RECIPE_ID.test(id))
      .sort();
  } catch {
    return [];
  }
}

async function runIds(limit = 50): Promise<string[]> {
  try {
    const names = await fs.readdir(path.join(CONFIG_DIR, "runs"));
    return names
      .filter((n) => /^\d+\.log$/.test(n))
      .map((n) => n.slice(0, -".log".length))
      .sort((a, b) => Number(b) - Number(a))
      .slice(0, limit);
  } catch {
    return [];
  }
}

function single(v: string | string[]): string {
  return Array.isArray(v) ? v[0] ?? "" : v;
}

export function registerResources(server: McpServer): void {
  server.registerResource(
    "run-log",
    new ResourceTemplate("apple-tasks://runs/{id}", {
      list: async () => ({
        resources: (await runIds()).map((id) => ({
          uri: `apple-tasks://runs/${id}`,
          name: `run ${id}`,
          mimeType: "text/plain",
        })),
      }),
    }),
    {
      title: "Dispatch run log",
      description:
        "Captured agent output for a ledger row (last 200 lines, ≤256 KB). Same file `run_log` reads; " +
        "the header records provider/model.",
      mimeType: "text/plain",
    },
    async (uri, { id }) => {
      const ledgerId = single(id);
      if (!/^\d+$/.test(ledgerId)) throw new Error(`not a ledger id: ${ledgerId}`);
      return {
        contents: [{ uri: uri.href, mimeType: "text/plain", text: await readRunLogTail(ledgerId, 200) }],
      };
    }
  );

  server.registerResource(
    "agents-config",
    "apple-tasks://config/agents",
    {
      title: "Agent configuration",
      description:
        "agents.json (~/.config/apple-tasks) with `env` values and any key/token/secret/password fields redacted. " +
        "Shows lanes, workdirs, modelPrefs, claimGuard, maxConcurrent.",
      mimeType: "application/json",
    },
    async (uri) => {
      const raw = await fs.readFile(path.join(CONFIG_DIR, "agents.json"), "utf8");
      const redacted = redactAgentsConfig(JSON.parse(raw) as unknown);
      return {
        contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify(redacted, null, 2) }],
      };
    }
  );

  server.registerResource(
    "doctor",
    "apple-tasks://doctor",
    {
      title: "Doctor report",
      description:
        "Live `apple-tasks doctor` JSON: permissions, helper, launchd agents, deployment drift, issues. " +
        "Read-only (never enqueues heals).",
      mimeType: "application/json",
    },
    async (uri) => ({
      contents: [{ uri: uri.href, mimeType: "application/json", text: await cli(["doctor"], { timeoutMs: 60_000 }) }],
    })
  );

  server.registerResource(
    "recipe",
    new ResourceTemplate("apple-tasks://recipes/{id}", {
      list: async () => ({
        resources: (await recipeIds()).map((id) => ({
          uri: `apple-tasks://recipes/${id}`,
          name: id,
          mimeType: "application/json",
        })),
      }),
    }),
    {
      title: "Task recipe",
      description:
        "A task template from ~/.config/apple-tasks/recipes/<id>.json (title, notes, list, agent, workdir, " +
        "tags, priority, dueTime, recurrence). Instantiate with task_create.",
      mimeType: "application/json",
    },
    async (uri, { id }) => {
      const recipeId = single(id);
      if (!RECIPE_ID.test(recipeId)) throw new Error(`not a recipe id: ${recipeId}`);
      const text = await fs.readFile(path.join(CONFIG_DIR, "recipes", `${recipeId}.json`), "utf8");
      return { contents: [{ uri: uri.href, mimeType: "application/json", text }] };
    }
  );
}
