#!/usr/bin/env node
import { execSync } from "node:child_process";
import { parse } from "yaml";
import { readFileSync } from "node:fs";

const app = process.argv[2];
const dry = process.argv.includes("--dry-run");
if (!app) { console.error("usage: verify:app <name> [--dry-run]"); process.exit(2); }

const v = parse(readFileSync(`apps/${app}/deploy/prod/values.yaml`, "utf8"));
const host = v.route?.host;

const links = [
  ["build", () => execSync(`docker buildx build --platform linux/arm64 -t local/${app}:verify apps/${app}`, { stdio: "ignore" })],
  ["push", () => execSync(`docker manifest inspect ${v.image.repo}:${v.image.tag}`, { stdio: "ignore" })],
  ["tag", () => { if (v.image.tag === "sha-0000000") throw new Error("values.yaml still on placeholder tag (CI write-back never landed)"); }],
  ["sync", () => execSync(`kubectl -n argocd get application ${app} -o jsonpath='{.status.sync.status}' | grep -qx Synced`)],
  ["probe", () => execSync(`kubectl -n prod get deploy ${app} -o jsonpath='{.status.readyReplicas}' | grep -qx 1`)],
  ["route", () => { if (host) execSync(`kubectl -n prod get httproute ${app} -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -qx True`); }],
  ["secret", () => { for (const f of v.envFrom ?? []) execSync(`kubectl -n prod get secret ${f.secretRef.name}`, { stdio: "ignore" }); }],
];

let firstRed = null;
for (const [label, fn] of links) {
  if (dry) { console.log(`  • ${label}: (dry-run)`); continue; }
  try { fn(); console.log(`  ✓ ${label}`); }
  catch (e) { console.log(`  ✗ ${label}  <-- RED: ${String(e.message || e).split("\n")[0]}`); firstRed = label; break; }
}
if (!dry && firstRed) { console.error(`\nverify:app ${app} FAILED at: ${firstRed}`); process.exit(1); }
if (!dry) console.log(`\nverify:app ${app}: all links green ✅`);
