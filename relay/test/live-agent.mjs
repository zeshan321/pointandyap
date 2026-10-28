// An agent on the MCP during a live review: wait_for_items, change the code it points at, mark_done, then read the
// review summary. Usage: node live-agent.mjs <PointAndYap binary> <app dir>
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
const [bin, app] = process.argv.slice(2);
const mcp = spawn(bin, ["--mcp"], { stdio: ["pipe", "pipe", "inherit"], env: process.env });
let buf = "", next = 1;
const waiting = new Map();
mcp.stdout.on("data", (d) => {
  buf += d;
  for (let i; (i = buf.indexOf("\n")) >= 0; ) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    const msg = JSON.parse(line); waiting.get(msg.id)?.(msg); waiting.delete(msg.id);
  }
});
const call = (method, params) => new Promise((ok) => { const id = next++; waiting.set(id, ok); mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); });
const tool = async (name, args) => (await call("tools/call", { name, arguments: args })).result;

await call("initialize", { protocolVersion: "2025-06-18", clientInfo: { name: "test-agent" }, capabilities: {} });
console.log("agent: waiting for items…");
const got = await tool("wait_for_items", { seconds: 120, images: false });
const text = got.content.map((c) => c.text || "").join("\n");
const id = text.match(/### Item (\S+)/)?.[1];
const src = text.match(/drawn at `([^`]+)`/)?.[1];
console.log("agent: got", id, "pointing at", src);
if (!id || !src) { console.log(text); process.exit(1); }
// The fix: the button the guest pointed at turns green.
const file = `${app}/${src.split(":")[0]}`;
const code = readFileSync(file, "utf8");
writeFileSync(file, code.replace("<button onClick", '<button style={{ background: "#1f8a4c", color: "#fff" }} onClick'));
console.log("agent: edited", file);
const done = await tool("mark_done", { ids: [id], note: "The counter button is green now (App.tsx)" });
console.log("agent:", done.content[0].text);
// The guest confirms on their page; the summary says so.
for (let i = 0; i < 60; i++) {
  const s = (await tool("get_review_summary", {})).content[0].text;
  if (s.includes("confirmed")) { console.log("agent: summary\n" + s); mcp.kill(); process.exit(0); }
  await new Promise((r) => setTimeout(r, 1000));
}
console.log("agent: never confirmed");
mcp.kill();
process.exit(1);
