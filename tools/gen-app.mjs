#!/usr/bin/env node
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { parse, stringify } from "yaml";

const name = process.argv[2];
const kindIdx = process.argv.indexOf("--kind");
const kind = kindIdx > -1 ? process.argv[kindIdx + 1] : "api";
if (!name || !["api", "worker", "ssr", "spa"].includes(kind)) {
  console.error("usage: gen:app <name> --kind api|worker|ssr|spa"); process.exit(2);
}

// 런타임별 메모리 게이트 기본값 (설계 §9)
const mem = { api: ["64Mi", "64Mi"], worker: ["64Mi", "64Mi"], ssr: ["128Mi", "256Mi"], spa: ["16Mi", "32Mi"] }[kind];
const served = ["api", "ssr", "spa"].includes(kind);
const route = served
  ? `route:\n  host: ${name}.ukyi.app\n  paths: ["/"]\n  public: false`
  : "# kind=worker: no route";
const db = (kind === "api" || kind === "worker")
  ? `db:\n  enabled: true\n  migrateCmd: ["/app/${name}", "migrate"]`
  : "db:\n  enabled: false";

let tmpl = readFileSync("tools/templates/values.yaml.tmpl", "utf8");
tmpl = tmpl.replaceAll("__NAME__", name).replaceAll("__KIND__", kind)
  .replace("__REQMEM__", mem[0]).replace("__LIMMEM__", mem[1])
  .replace("__ROUTE__", route).replace("__DB__", db);

const base = `apps/${name}`;
if (existsSync(base)) { console.error(`apps/${name} already exists`); process.exit(1); }
mkdirSync(`${base}/src`, { recursive: true });
mkdirSync(`${base}/deploy/prod`, { recursive: true });
writeFileSync(`${base}/deploy/prod/values.yaml`, tmpl);
writeFileSync(`${base}/Dockerfile`,
`# syntax=docker/dockerfile:1
# TODO(${name}): build a distroless, non-root, arm64 image exposing :8080 /healthz /readyz, :9090 /metrics, and a 'migrate' cmd.
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532
`);
writeFileSync(`${base}/src/.gitkeep`, "");

// CI matrix 항목 추가
const wfPath = ".github/workflows/build.yaml";
const wf = parse(readFileSync(wfPath, "utf8"));
const apps = wf.jobs.build.strategy.matrix.app;
if (!apps.includes(name)) apps.push(name);
writeFileSync(wfPath, stringify(wf));

console.log(`scaffolded apps/${name} (kind=${kind}) and added '${name}' to CI matrix.`);
console.log(`next: pnpm gen:env ${name} && pnpm verify:app ${name}`);
