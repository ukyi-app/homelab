#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { parseDocument } from "yaml";

const [app, tag] = process.argv.slice(2);
// Strict app-name allowlist: never let an attacker-supplied name escape apps/ (path traversal).
if (!app || !/^[a-z][a-z0-9-]{0,40}$/.test(app)) {
  console.error(`bad app name: ${app ?? "<none>"}`); process.exit(2);
}
if (!/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha>"); process.exit(2);
}
const path = `apps/${app}/deploy/prod/values.yaml`;
// Defence-in-depth: refuse to write outside apps/ even if the regex is ever loosened.
const root = resolve("apps");
if (!resolve(path).startsWith(root + sep)) {
  console.error(`refusing to write outside apps/: ${path}`); process.exit(2);
}
const doc = parseDocument(readFileSync(path, "utf8"));
const cur = doc.getIn(["image", "tag"]);
if (cur === tag) { console.log(`bump: ${path} already ${tag} (no-op)`); process.exit(0); }
doc.setIn(["image", "tag"], tag);
writeFileSync(path, doc.toString());
console.log(`bump: ${path} image.tag ${cur} -> ${tag}`);
