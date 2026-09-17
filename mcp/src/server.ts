import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerApprovalTools } from "./tools/approvals";
import { registerCalendarTools } from "./tools/calendar";
import { registerCaptureTools } from "./tools/capture";
import { registerContactTools } from "./tools/contacts";
import { registerDispatchTools } from "./tools/dispatch";
import { registerMailTools } from "./tools/mail";
import { registerMiscTools } from "./tools/misc";
import { registerNotesTools } from "./tools/notes";
import { registerTaskTools } from "./tools/tasks";
import { registerPrompts } from "./prompts";
import { registerResources } from "./resources";

export function createServer(): McpServer {
  const server = new McpServer({ name: "apple-tasks", version: "0.1.0" });
  registerResources(server);
  registerPrompts(server);
  registerTaskTools(server);
  registerCalendarTools(server);
  registerNotesTools(server);
  registerMailTools(server);
  registerContactTools(server);
  registerCaptureTools(server);
  registerDispatchTools(server);
  registerApprovalTools(server);
  registerMiscTools(server);
  return server;
}

if (import.meta.main) {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
