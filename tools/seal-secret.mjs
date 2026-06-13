#!/usr/bin/env node
// .env → SealedSecret 봉인 CLI (`pnpm secret:seal`).
// .app-config.yml의 `secrets:[...]`만 allowlist로 봉인한다 — 선언 안 된 .env 키는 절대 봉인하지
// 않고, 선언됐는데 .env에 없으면 키 이름만 출력하며 실패한다(값은 어떤 경로로도 출력 금지).
// 평문 Secret manifest는 디스크에 쓰지 않고 kubeseal stdin으로만 흐른다.
// 이 사본은 homelab 마이그레이션/테스트용 — 동일 스크립트가 app-starter 템플릿에도 동봉된다.
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { parse } from "yaml";

function die(msg) {
  console.error(`seal-secret: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = { namespace: "prod", cert: "tools/sealed-secrets-cert.pem", dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dry-run") args.dryRun = true;
    else if (a === "--config") args.config = argv[++i];
    else if (a === "--env") args.env = argv[++i];
    else if (a === "--cert") args.cert = argv[++i];
    else if (a === "--app") args.app = argv[++i];
    else if (a === "--namespace") args.namespace = argv[++i];
    else if (a === "--out") args.out = argv[++i];
    else die(`알 수 없는 인자: ${a}`);
  }
  if (!args.config || !args.env) die("--config <.app-config.yml> --env <.env> 필수");
  return args;
}

// kebab-case(api-key) → UPPER_SNAKE(API_KEY) — secrets 선언과 .env 키의 정규화 규약
const toEnvKey = (name) => name.replaceAll("-", "_").toUpperCase();

function parseDotEnv(path) {
  const out = new Map();
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    out.set(line.slice(0, eq).trim(), line.slice(eq + 1).trim());
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const config = parse(readFileSync(args.config, "utf8")) ?? {};
const declared = Array.isArray(config.secrets) ? config.secrets : [];
if (declared.length === 0) die("config에 secrets 선언이 없다 — 봉인할 대상 0");

for (const name of declared) {
  if (!/^[a-z][a-z0-9-]*$/.test(String(name))) die(`secrets 항목 형식 불량(kebab-case 아님): ${name}`);
}

const envMap = parseDotEnv(args.env);
const targets = declared.map((n) => ({ name: n, envKey: toEnvKey(n) }));
const missing = targets.filter((t) => !envMap.has(t.envKey)).map((t) => t.envKey);
if (missing.length > 0) die(`missing in .env: ${missing.join(", ")}`); // 키 이름만 — 값 비출력

if (args.dryRun) {
  // 봉인 없이 대상 키 목록만 (값 절대 미포함)
  console.log(JSON.stringify({ seal: targets.map((t) => t.envKey) }, null, 2));
  process.exit(0);
}

if (!args.app) die("--app <name> 필수 (Secret 이름 규약: <app>-secrets)");
if (!args.out) die("--out <파일> 필수");

// 평문 Secret manifest는 메모리에서만 조립해 kubeseal stdin으로 직행
const stringData = Object.fromEntries(targets.map((t) => [t.envKey, envMap.get(t.envKey)]));
const manifest = {
  apiVersion: "v1",
  kind: "Secret",
  metadata: { name: `${args.app}-secrets`, namespace: args.namespace },
  type: "Opaque",
  stringData,
};

const res = spawnSync("kubeseal", ["--cert", args.cert, "--format", "yaml"], {
  input: JSON.stringify(manifest), // kubeseal은 JSON manifest도 받는다(YAML 슈퍼셋)
  encoding: "utf8",
});
if (res.error) die(`kubeseal 실행 실패: ${res.error.message}`);
if (res.status !== 0) die(`kubeseal 종료 코드 ${res.status} — cert/컨트롤러 점검 (stderr는 값 미포함 시에만 확인)`);
writeFileSync(args.out, res.stdout);
console.log(`sealed: ${args.out} (keys: ${targets.map((t) => t.envKey).join(", ")})`);
