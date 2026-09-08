import { createServer } from "../src/server";
import { toolRegistry } from "../src/lib";

createServer();

const rows = [...toolRegistry].sort((a, b) => a.name.localeCompare(b.name));
console.log(`| Tool | Title | Description |`);
console.log(`| --- | --- | --- |`);
for (const tool of rows) {
  const title = tool.annotations.title ?? "";
  const description = tool.description.replace(/\|/g, "\\|").replace(/\s+/g, " ").trim();
  console.log(`| \`${tool.name}\` | ${title} | ${description} |`);
}
