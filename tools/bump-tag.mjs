#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { parseDocument } from "yaml";

const [app, tag] = process.argv.slice(2);
if (!app || !/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha>"); process.exit(2);
}
const path = `apps/${app}/deploy/prod/values.yaml`;
const doc = parseDocument(readFileSync(path, "utf8"));
const cur = doc.getIn(["image", "tag"]);
if (cur === tag) { console.log(`bump: ${path} already ${tag} (no-op)`); process.exit(0); }
doc.setIn(["image", "tag"], tag);
writeFileSync(path, doc.toString());
console.log(`bump: ${path} image.tag ${cur} -> ${tag}`);
