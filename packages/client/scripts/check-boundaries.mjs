#!/usr/bin/env node
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const forbiddenPrefixes = [
  "pi",
  "@earendil-works",
  "@modelcontextprotocol",
  "claude",
  "mcp",
  "galexc",
  "@parlehq/mcp-server",
  "@parlehq/pi-extension",
  "@parlehq/claude-plugin",
];

const specifierPattern = /(?:^|\n)\s*(?:import\s+(?:type\s+)?(?:[^"'\n]+\s+from\s+)?|export\s+(?:type\s+)?[^"'\n]+\s+from\s+|(?:const|let|var)\s+[^=\n]+?=\s*require\s*\()(["'])([^"']+)\1/g;

export function findForbiddenImports(rootDir) {
  const findings = [];
  for (const file of walk(rootDir)) {
    if (!/\.[cm]?tsx?$|\.[cm]?jsx?$/.test(file)) continue;
    const text = readFileSync(file, "utf8");
    for (const match of text.matchAll(specifierPattern)) {
      const specifier = match[2];
      const forbidden = forbiddenPrefixes.find((prefix) => specifier === prefix || specifier.startsWith(`${prefix}/`));
      if (forbidden) findings.push({ file, specifier, forbidden });
    }
  }
  return findings;
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(path));
    else if (entry.isFile()) out.push(path);
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = process.argv[2] || fileURLToPath(new URL("../src", import.meta.url));
  const findings = findForbiddenImports(root);
  if (findings.length > 0) {
    for (const finding of findings) console.error(`${finding.file}: forbidden client import ${finding.specifier}`);
    process.exit(1);
  }
}
