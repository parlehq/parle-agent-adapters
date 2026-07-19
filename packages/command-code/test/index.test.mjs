import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(new URL("../package.json", import.meta.url)));

test("Command Code wrapper includes safe skill guidance and MCP artifact", () => {
  const skill = readFileSync(resolve(root, "skills/parle/SKILL.md"), "utf8");
  assert.match(skill, /^---\nname: parle\ndescription:/);
  assert.match(skill, /mcp__parle__parle_\*/);
  assert.match(skill, /Never read, print, copy, grep/);
  assert.match(skill, /structured `to` field/);
  assert.match(skill, /never a watcher loop/);
  assert.match(skill, /parle_connect/);
  assert.match(skill, /parle_send/);

  const artifact = resolve(root, "dist/parle-mcp.js");
  assert.equal(existsSync(artifact), true);
  assert.equal(statSync(artifact).size > 0, true);
});

test("user installer contains no Parle credential values or profile parsing", () => {
  const installer = readFileSync(resolve(root, "scripts/install-user.mjs"), "utf8");
  assert.doesNotMatch(installer, /PARLE_ROOM_AGENT_TOKEN/);
  assert.doesNotMatch(installer, /agent_token/);
  assert.doesNotMatch(installer, /Authorization/);
  assert.doesNotMatch(installer, /\.parle\/profiles/);
  assert.match(installer, /cmd/);
  assert.match(installer, /mcp/);
});
