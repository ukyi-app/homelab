#!/usr/bin/env node
// 외부 앱 레포의 .homelab.yaml(dispatch payload)을 검증하고 apps/<app>/deploy/prod/를 스캐폴드한다.
// onboard.yaml 워크플로가 호출. --dry-run이면 파일을 쓰지 않고 계획(JSON)만 출력 — 테스트도 이 모드를 쓴다.
//
// 입력 payload(JSON 파일): { app, repo: "owner/app", tag: "sha-<sha>", config_b64: base64(.homelab.yaml) }
// 검증 1단계: tools/homelab-app-schema.json (타입/enum/패턴 — 스키마 파일이 계약의 SSOT)
// 검증 2단계: 비즈니스 규칙(worker-no-route, host 유도/suffix, env 시크릿 패턴, 원장 예산, 중복)
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { parse as parseYaml, stringify as toYaml } from "yaml";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const DRY = process.argv.includes("--dry-run");
const payloadPath = arg("--payload");
const DOMAIN = arg("--domain");
const ROOT = arg("--repo-root", ".");
if (!payloadPath || !DOMAIN) { console.error("usage: onboard-app --payload <json> --domain <apex> [--dry-run]"); process.exit(2); }

const fail = (msg) => { console.error(`::error::onboard: ${msg}`); process.exit(1); };

// ---------- 1) payload ----------
const payload = JSON.parse(readFileSync(payloadPath, "utf8"));
const { app, repo, tag } = payload;
if (!/^[a-z][a-z0-9-]{1,29}$/.test(app ?? "")) fail(`app 이름 불량: '${app}' (^[a-z][a-z0-9-]{1,29}$)`);
if (!/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) fail(`tag 형식 불량: '${tag}' (sha-<gitsha>)`);
if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(repo ?? "")) fail(`repo 형식 불량: '${repo}'`);
const [owner, repoName] = repo.split("/");
if (repoName !== app) fail(`레포 이름(${repoName})과 app(${app})이 달라야 할 이유가 없다 — 컨벤션: app=repo명`);
let config;
try { config = parseYaml(Buffer.from(payload.config_b64, "base64").toString("utf8")) ?? {}; }
catch (e) { fail(`.homelab.yaml 파싱 실패: ${e.message}`); }

// ---------- 2) 스키마 검증 (homelab-app-schema.json이 계약) ----------
const schema = JSON.parse(readFileSync(new URL("./homelab-app-schema.json", import.meta.url), "utf8"));
const deref = (s) => (s?.$ref ? schema.definitions[s.$ref.split("/").pop()] : s);
function check(val, sch, path) {
  sch = deref(sch);
  const t = sch.type;
  const is = { object: (v) => v && typeof v === "object" && !Array.isArray(v), array: Array.isArray,
    string: (v) => typeof v === "string", integer: Number.isInteger, boolean: (v) => typeof v === "boolean" };
  if (sch.enum) { if (!sch.enum.includes(val)) fail(`${path}: '${val}'은 ${JSON.stringify(sch.enum)} 중 하나여야 함`); return; }
  if (t && !is[t]?.(val)) fail(`${path}: ${t} 타입이어야 함`);
  if (t === "string" && sch.pattern && !new RegExp(sch.pattern).test(val)) fail(`${path}: 패턴 ${sch.pattern} 불일치 ('${val}')`);
  if (t === "integer") { if (sch.minimum != null && val < sch.minimum) fail(`${path}: ≥${sch.minimum}`);
    if (sch.maximum != null && val > sch.maximum) fail(`${path}: ≤${sch.maximum}`); }
  if (t === "array") { if (sch.minItems && val.length < sch.minItems) fail(`${path}: 최소 ${sch.minItems}개`);
    val.forEach((v, i) => check(v, sch.items, `${path}[${i}]`)); }
  if (t === "object") {
    for (const r of sch.required ?? []) if (!(r in val)) fail(`${path}.${r}: 필수`);
    for (const [k, v] of Object.entries(val)) {
      if (sch.properties?.[k]) check(v, sch.properties[k], `${path}.${k}`);
      else if (sch.additionalProperties === false) fail(`${path}.${k}: 알 수 없는 필드`);
    }
  }
}
check(config, schema, ".homelab.yaml");

// ---------- 3) 비즈니스 규칙 ----------
const kind = config.kind;
const served = ["api", "ssr", "spa"].includes(kind);
if (!served && config.route) fail("kind=worker는 route를 가질 수 없다");
if (kind !== "spa" && config.spa) fail("spa 블록은 kind=spa 전용");
if (kind === "spa" && config.db?.enabled) fail("kind=spa는 db를 가질 수 없다(정적 서빙)");

const pub = config.route?.public ?? false;
let host = config.route?.host;
if (served) {
  const derived = pub ? `${app}.${DOMAIN}` : `${app}.home.${DOMAIN}`;
  if (!host) host = derived;
  else if (pub) { if (!host.endsWith(`.${DOMAIN}`) || host.endsWith(`.home.${DOMAIN}`)) fail(`public host는 *.${DOMAIN}(단, *.home.* 제외): '${host}'`); }
  else if (!host.endsWith(`.home.${DOMAIN}`)) fail(`internal host는 *.home.${DOMAIN}: '${host}'`);
}

const SECRETISH = /(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE|(^|_)KEY(_|$))/;
const allow = new Set(config.allowPlaintext ?? []);
for (const e of config.env ?? [])
  if (SECRETISH.test(e.name) && !allow.has(e.name))
    fail(`env '${e.name}'은 시크릿으로 보인다 — secrets:로 선언(KSOPS)하거나 의도적 평문이면 allowPlaintext에 명시`);

const toMi = (m) => m.endsWith("Gi") ? parseInt(m) * 1024 : parseInt(m);
const toMilli = (c) => c.endsWith("m") ? parseInt(c) : parseInt(c) * 1000;
const { requests: rq, limits: lm } = config.resources;
if (toMi(lm.memory) < toMi(rq.memory)) fail("limits.memory < requests.memory");
if (toMilli(lm.cpu) < toMilli(rq.cpu)) fail("limits.cpu < requests.cpu");
const replicas = config.replicas ?? 1;
const reqMi = toMi(rq.memory) * replicas, limitMi = toMi(lm.memory) * replicas;

// 중복: 디렉토리 + 원장 행 이름
const appDir = `${ROOT}/apps/${app}`;
if (existsSync(appDir)) fail(`apps/${app} 이미 존재`);
const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
const ledger = readFileSync(ledgerPath, "utf8");
const rowRe = /<!-- ledger:row --> *([a-z0-9+-]+) *\|[^|]*\| *(\d+) *\| *(\d+) *\|/g;
let m, sumReq = 0, sumLimit = 0, names = [];
while ((m = rowRe.exec(ledger))) { names.push(m[1]); sumReq += +m[2]; sumLimit += +m[3]; }
if (names.includes(app)) fail(`원장에 '${app}' 행이 이미 있다`);
const budget = +(ledger.match(/LIMIT_BUDGET_MIB=(\d+)/)?.[1] ?? 0);
if (!budget) fail("원장 메타(LIMIT_BUDGET_MIB)를 찾지 못함");
if (sumLimit + limitMi > budget)
  fail(`원장 예산 초과: 현재 ${sumLimit}Mi + ${app} ${limitMi}Mi > ${budget}Mi — resources/replicas를 줄여라`);

// ---------- 4) values.yaml 구성 ----------
const values = {
  image: { repo: `ghcr.io/${owner}/${app}`, tag },
  kind, replicas,
  resources: { requests: { cpu: rq.cpu, memory: rq.memory }, limits: { cpu: lm.cpu, memory: lm.memory } },
};
if ((config.env ?? []).length) values.env = config.env;
const secrets = config.secrets ?? [];
if (secrets.length) values.envFrom = secrets.map((s) => ({ secretRef: { name: s } }));
if (served) values.route = { host, paths: config.route?.paths ?? ["/"], public: pub };
values.db = config.db?.enabled
  ? { enabled: true, migrateCmd: config.db.migrateCmd ?? ["migrate"] }
  : { enabled: false };
if (config.probes) values.probes = config.probes;
if (kind === "spa") values.spa = { server: config.spa?.server ?? "sws" };

// ---------- 5) 산출물 ----------
const plan = {
  app, repo, tag, kind, host: served ? host : null, replicas,
  reqMi, limitMi, ledger: { before: sumLimit, after: sumLimit + limitMi, budget },
  secrets,
  autoDeploy: config.deploy?.autoDeploy ?? true,
  checklist: [
    `GHCR 패키지 public 전환 필요: https://github.com/orgs/${owner}/packages/container/${app}/settings — org 패키지는 첫 push 시 private이라 클러스터 pull이 401(ErrImagePull)로 실패한다(가시성 변경은 UI 전용)`,
    ...secrets.map((s) =>
      `apps/${app}/deploy/prod/${s}.enc.yaml 작성 필요 (sops로 namespace=prod Secret '${s}' 봉인 후 이 PR 브랜치에 커밋 — 없으면 ArgoCD sync 실패)`),
  ],
};

if (!DRY) {
  mkdirSync(`${appDir}/deploy/prod`, { recursive: true });
  writeFileSync(`${appDir}/deploy/prod/values.yaml`, toYaml(values));
  writeFileSync(`${appDir}/deploy/prod/source-repo`, `${repo}\n`); // bump의 발신자 바인딩 검증용
  // kustomization.yaml은 secrets 유무와 무관하게 항상 필요하다 — appset source #3가 이 디렉토리를
  // kustomize로 렌더하는데, 없으면 ArgoCD가 values.yaml/source-repo를 매니페스트로 파싱해
  // "groupVersion shouldn't be empty"로 죽는다.
  writeFileSync(`${appDir}/deploy/prod/kustomization.yaml`, toYaml({
    apiVersion: "kustomize.config.k8s.io/v1beta1", kind: "Kustomization",
    namespace: "prod",
    ...(secrets.length ? { generators: ["secret-generator.yaml"] } : {}),
  }));
  // [deprecated] v1 KSOPS 앱-시크릿 경로. 앱 시크릿 표준은 create-app(v2) + SealedSecret이다
  // (tools/create-app.mjs, --sealed <app>-secrets.sealed.yaml). 신규 앱은 KSOPS를 쓰지 말 것.
  // 이 분기는 기존 v1 온보딩 호환용으로만 남긴다 — 동작 변경 금지(비목표).
  if (secrets.length) {
    writeFileSync(`${appDir}/deploy/prod/secret-generator.yaml`,
`apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ${app}-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
${secrets.map((s) => `  - ${s}.enc.yaml # -> Secret '${s}' (ns prod) — 사람이 sops로 작성`).join("\n")}
`);
  }
  // 원장: 마지막 row 다음에 행 추가 + Totals 프로즈 갱신
  const lines = ledger.split("\n");
  const lastRow = lines.map((l, i) => (l.includes("<!-- ledger:row -->") ? i : -1)).filter((i) => i >= 0).pop();
  lines.splice(lastRow + 1, 0, `| <!-- ledger:row --> ${app.padEnd(14)} | prod           | ${String(reqMi).padStart(6)} | ${String(limitMi).padStart(8)} |`);
  let out = lines.join("\n");
  out = out.replace(/req ≈ \d+ Mi · limit ≈ \d+ Mi/, `req ≈ ${sumReq + reqMi} Mi · limit ≈ ${sumLimit + limitMi} Mi`);
  writeFileSync(ledgerPath, out);
}
console.log(JSON.stringify(plan, null, 2));
