#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { parseDocument } from "yaml";

const argv = process.argv.slice(2);
const ri = argv.indexOf("--repo-root");
const repoRoot = ri > -1 ? argv[ri + 1] : "."; // 테스트는 fixture root를 넘긴다 (라이브 CI는 기본 ".")
const pos = argv.filter((a, i) => a !== "--repo-root" && argv[i - 1] !== "--repo-root");
const [app, tag] = pos;
// 엄격한 앱 이름 allowlist: 공격자가 준 이름이 apps/를 벗어나지 못하게 한다 (path traversal 방지).
if (!app || !/^[a-z][a-z0-9-]{0,40}$/.test(app)) {
  console.error(`bad app name: ${app ?? "<none>"}`); process.exit(2);
}
if (!/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha> [--repo-root <dir>]"); process.exit(2);
}
const path = `${repoRoot}/apps/${app}/deploy/prod/values.yaml`;
// 심층 방어: regex가 나중에 느슨해지더라도 apps/ 밖 쓰기는 거부한다.
const root = resolve(repoRoot, "apps");
if (!resolve(path).startsWith(root + sep)) {
  console.error(`refusing to write outside apps/: ${path}`); process.exit(2);
}
const doc = parseDocument(readFileSync(path, "utf8"));
const cur = doc.getIn(["image", "tag"]);
if (cur === tag) { console.log(`bump: ${path} already ${tag} (no-op)`); process.exit(0); }
doc.setIn(["image", "tag"], tag);
writeFileSync(path, doc.toString());
console.log(`bump: ${path} image.tag ${cur} -> ${tag}`);
