#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { parse } from "yaml";

const app = process.argv[2];
const mode = process.argv.includes("--check") ? "check"
  : process.argv.includes("--stdout") ? "stdout" : "write";

if (!app) { console.error("usage: gen:env <app> [--check|--stdout]"); process.exit(2); }

const valuesPath = `apps/${app}/deploy/prod/values.yaml`;
const v = parse(readFileSync(valuesPath, "utf8"));

const lines = [
  `# GENERATED from ${valuesPath} by pnpm gen:env — DO NOT EDIT BY HAND`,
  `# Local inner-loop env. Real values come from SOPS secrets in-cluster.`,
  "",
];
for (const e of v.env ?? []) lines.push(`${e.name}=${e.value ?? ""}`);
// DB inner-loop default (local containerized Postgres, Task 6.12)
if (v.db?.enabled) lines.push("DATABASE_URL=postgres://dev:dev@localhost:5432/app_dev?sslmode=disable");
for (const f of v.envFrom ?? []) {
  if (f.secretRef?.name) lines.push(`# from secret: ${f.secretRef.name}  (fill locally; never commit)`);
}
const out = lines.join("\n") + "\n";

const target = `apps/${app}/.env.example`;
if (mode === "stdout") { process.stdout.write(out); }
else if (mode === "check") {
  const cur = existsSync(target) ? readFileSync(target, "utf8") : "";
  if (cur !== out) {
    console.error(`DRIFT: ${target} is out of sync with ${valuesPath}. Run: pnpm gen:env ${app}`);
    process.exit(1);
  }
  console.log(`${target} OK`);
} else { writeFileSync(target, out); console.log(`wrote ${target}`); }
