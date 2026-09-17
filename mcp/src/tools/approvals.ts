import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { cli, defineTool, fail, okJson, trackTool } from "../lib";
import { approvalShape } from "../schemas";

export function registerApprovalTools(server: McpServer): void {
  defineTool(server, {
    name: "approval_request",
    description:
      "Ask the human for approval via an ntfy push with [Approve] [Deny] buttons; returns a token to poll " +
      "with approval_check. Use before doing anything consequential you were not explicitly asked to do " +
      "(sending, buying, deleting). Requires ntfy in ~/.config/apple-tasks/notify.json.",
    input: {
      question: z.string().describe("What is being asked, e.g. 'Send the reply draft to Sarah?'"),
      task: z.string().optional().describe("Task id this approval belongs to (audit trail)."),
      expires_minutes: z.number().int().optional().describe("Pending requests expire after this long (default 240)."),
      force: z.boolean().optional().describe("Priority: push even during quiet hours."),
    },
    output: approvalShape,
    annotations: { title: "Request approval", openWorldHint: true },
    timeoutMs: 30_000,
    argv: ({ question, task, expires_minutes, force }) => {
      const args = ["approve", "request", question];
      if (task) args.push("--task", task);
      if (expires_minutes !== undefined) args.push("--expires-minutes", String(expires_minutes));
      if (force) args.push("--force");
      return args;
    },
  });

  const approvalCheckDescription =
    "Check an approval request's status, polling ntfy for a button answer. wait_seconds blocks until " +
    "answered/expired or the wait elapses (poll every 3s). Act only on status 'approved'; treat 'denied' " +
    "and 'expired' as no. There is deliberately no MCP tool to ANSWER an approval — answering your own " +
    "request defeats the protocol.";
  const approvalCheckAnnotations = { title: "Check approval", readOnlyHint: true } as const;
  trackTool("approval_check", approvalCheckDescription, approvalCheckAnnotations);
  server.registerTool(
    "approval_check",
    {
      description: approvalCheckDescription,
      inputSchema: {
        token: z.string().describe("Token from approval_request."),
        wait_seconds: z.number().int().optional().describe("Keep polling this long (default: one poll, no wait)."),
      },
      outputSchema: approvalShape,
      annotations: approvalCheckAnnotations,
    },
    async ({ token, wait_seconds }) => {
      const args = ["approve", "check", token];
      if (wait_seconds !== undefined) args.push("--wait-seconds", String(wait_seconds));
      try {
        return okJson(await cli(args, { timeoutMs: (wait_seconds ?? 0) * 1000 + 30_000 }));
      } catch (err) {
        return fail(err);
      }
    }
  );

  defineTool(server, {
    name: "approval_list",
    description: "List approval requests, newest first. Filter by status to see what's pending.",
    input: {
      status: z.enum(["pending", "approved", "denied", "expired"]).optional(),
      limit: z.number().int().optional().describe("Max rows (default 50)."),
    },
    output: { approvals: z.array(z.object(approvalShape)) },
    annotations: { title: "List approvals", readOnlyHint: true },
    argv: ({ status, limit }) => {
      const args = ["approve", "list"];
      if (status) args.push("--status", status);
      if (limit !== undefined) args.push("--limit", String(limit));
      return args;
    },
    wrap: (parsed) => ({ approvals: parsed }),
  });
}
