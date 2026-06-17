// create-app 생성기 — 외부 앱 레포의 .app-config.yml(v2 계약)을 검증하고
// apps/<app>/deploy/prod/ + apps.json + 메모리 원장을 한 번에 갱신한다.
// onboard-app.mjs(v1, .homelab.yaml)의 후속: db/redis 리소스 참조, SealedSecret 시크릿,
// digest 핀 이미지, 권위 바인딩 레지스트리(.bindings.json)가 추가됐다.
// _create-app.yaml(homelab-initiated workflow_dispatch)이 호출 — 결과물은 PR(사람 머지 = 승인).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { parse as parseYaml, stringify as toYaml } from "yaml";
import { APP_NAME_RE } from "./lib/identity.mjs";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const DRY = process.argv.includes("--dry-run");
const configPath = arg("--config");
const app = arg("--app");
const repo = arg("--repo");
const DOMAIN = arg("--domain");
const ROOT = arg("--repo-root", ".");
const tag = arg("--tag");
const digest = arg("--digest");
const sealedPath = arg("--sealed");
// 오타 옵션 침묵-무시 차단 — arg() 헬퍼는 미지정 플래그를 조용히 무시하고 디폴트를 적용한다.
const ALLOWED_FLAGS = new Set(["--dry-run", "--config", "--app", "--repo", "--domain", "--repo-root", "--tag", "--digest", "--sealed"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !ALLOWED_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...ALLOWED_FLAGS].join(" ")}`); process.exit(2); }
}
if (!configPath || !app || !repo || !DOMAIN || !tag || !digest) {
  console.error("usage: create-app --config <.app-config.yml> --app <name> --repo <owner/app> --domain <apex> --tag sha-<gitsha> --digest sha256:<hex> [--sealed <file>] [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}
const fail = (msg) => { console.error(`::error::create-app: ${msg}`); process.exit(1); };

// ---------- 1) 식별자/이미지 핀 검증 ----------
if (!APP_NAME_RE.test(app)) fail(`app 이름 불량: '${app}'`);
if (!/^ukyi-app\/[A-Za-z0-9._-]+$/.test(repo)) fail(`repo는 ukyi-app org여야 한다: '${repo}'`);
const [owner, repoName] = repo.split("/");
if (repoName !== app) fail(`레포 이름(${repoName})과 app(${app}) 불일치 — 컨벤션: app=repo명`);
if (!/^sha-[0-9a-f]{7,40}$/.test(tag)) fail(`tag 형식 불량: '${tag}'`);
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) fail(`digest 형식 불량(불변 핀 필수): '${digest}'`);

let config;
try { config = parseYaml(readFileSync(configPath, "utf8")) ?? {}; }
catch (e) { fail(`.app-config.yml 파싱 실패: ${e.message}`); }

// ---------- 2) 스키마 검증 (app-config-schema.json이 계약 SSOT) ----------
const schema = JSON.parse(readFileSync(new URL("./app-config-schema.json", import.meta.url), "utf8"));
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
    if (sch.uniqueItems && new Set(val.map(String)).size !== val.length) fail(`${path}: 중복 항목`);
    val.forEach((v, i) => check(v, sch.items, `${path}[${i}]`)); }
  if (t === "object") {
    for (const r of sch.required ?? []) if (!(r in val)) fail(`${path}.${r}: 필수`);
    for (const [k, v] of Object.entries(val)) {
      if (sch.properties?.[k]) check(v, sch.properties[k], `${path}.${k}`);
      else if (sch.additionalProperties === false) fail(`${path}.${k}: 알 수 없는 필드`);
    }
  }
}
check(config, schema, ".app-config.yml");

// ---------- 3) 비즈니스 규칙 (onboard v1과 동일 + v2 리소스 가드) ----------
const kind = config.kind;
const served = ["api", "ssr", "spa"].includes(kind);
if (!served && config.route) fail("kind=worker는 route를 가질 수 없다");
if (kind !== "spa" && config.spa) fail("spa 블록은 kind=spa 전용");
if (kind === "spa" && (config.db?.length || config.migrate)) fail("kind=spa는 db/migrate를 가질 수 없다(정적 서빙)");

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
    fail(`env '${e.name}'은 시크릿으로 보인다 — secrets:로 선언(SealedSecret)하거나 의도적 평문이면 allowPlaintext에 명시`);

// 미생성 리소스 가드: db/redis 참조는 create-database/create-cache 산출물이 선재해야 한다
const dbs = config.db ?? [];
const caches = config.redis ?? [];
// tombstone 가드: teardown이 표시한 리소스는 신규 참조 금지(철거와 열린 create-app PR의 경쟁 차단)
const tombPath = `${ROOT}/platform/data-conn/prod/.tombstones.json`;
const tombs = existsSync(tombPath) ? JSON.parse(readFileSync(tombPath, "utf8")) : {};
for (const n of dbs) if (tombs[`db:${n}`]) fail(`db '${n}'은 tombstone 상태(${tombs[`db:${n}`].state}) — 신규 참조 불가`);
for (const n of caches) if (tombs[`cache:${n}`]) fail(`cache '${n}'은 tombstone 상태(${tombs[`cache:${n}`].state}) — 신규 참조 불가`);
for (const n of dbs) {
  if (!existsSync(`${ROOT}/platform/cnpg/prod/databases/${n}.yaml`) ||
      !existsSync(`${ROOT}/platform/data-conn/prod/db-${n}-conn.sealed.yaml`))
    fail(`db '${n}' 미생성 — create-database 먼저 (dispatch-mutation action=create-database)`);
}
for (const n of caches) {
  if (!existsSync(`${ROOT}/platform/data-conn/prod/cache-${n}-conn.sealed.yaml`))
    fail(`cache '${n}' 미생성 — create-cache 먼저 (dispatch-mutation action=create-cache)`);
}

const toMi = (m) => m.endsWith("Gi") ? parseInt(m) * 1024 : parseInt(m);
const toMilli = (c) => c.endsWith("m") ? parseInt(c) : parseInt(c) * 1000;
const { requests: rq, limits: lm } = config.resources;
if (toMi(lm.memory) < toMi(rq.memory)) fail("limits.memory < requests.memory");
if (toMilli(lm.cpu) < toMilli(rq.cpu)) fail("limits.cpu < requests.cpu");
const replicas = config.replicas ?? 1;
const reqMi = toMi(rq.memory) * replicas, limitMi = toMi(lm.memory) * replicas;

// 중복: 디렉토리 + 원장 행
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

// apps.json 전역 유일성 + 예약어 (중복 host는 toset에서 조용히 사라져 오라우팅 — 등록 단계에서 거부)
const appsJsonPath = `${ROOT}/infra/cloudflare/apps.json`;
const registry = JSON.parse(readFileSync(appsJsonPath, "utf8"));
if (served && pub) {
  if ([DOMAIN, `www.${DOMAIN}`].includes(host) || host.endsWith(`.home.${DOMAIN}`)) fail(`예약 host: ${host}`);
  if (registry.some((r) => r.name === app)) fail(`apps.json에 name '${app}' 이미 존재`);
  if (registry.some((r) => r.host === host)) fail(`apps.json에 host '${host}' 이미 존재(오라우팅 차단)`);
}

// SealedSecret 시크릿: secrets 선언 시 봉인본 필수 + 메타데이터 검증(봉인본이라 전송/커밋 안전)
const secrets = config.secrets ?? [];
let sealedDoc = null;
if (secrets.length) {
  if (!sealedPath) fail("secrets 선언인데 --sealed <app-secrets.sealed.yaml> 누락 — 앱 레포 deploy/ 경로에서 read");
  sealedDoc = parseYaml(readFileSync(sealedPath, "utf8"));
  if (sealedDoc?.kind !== "SealedSecret") fail("sealed 파일이 kind: SealedSecret이 아니다");
  if (sealedDoc?.metadata?.namespace !== "prod") fail(`sealed namespace는 prod여야 한다(strict-scope): ${sealedDoc?.metadata?.namespace}`);
  if (sealedDoc?.metadata?.name !== `${app}-secrets`) fail(`sealed name은 ${app}-secrets여야 한다: ${sealedDoc?.metadata?.name}`);
}

// ---------- 4) values.yaml 구성 ----------
const values = {
  image: { repo: `ghcr.io/${owner}/${app}`, tag, digest }, // digest가 권위(불변), tag는 source SHA 추적
  kind, replicas,
  resources: { requests: { cpu: rq.cpu, memory: rq.memory }, limits: { cpu: lm.cpu, memory: lm.memory } },
};
if ((config.env ?? []).length) values.env = config.env;
const envFrom = [
  ...dbs.map((n) => ({ secretRef: { name: `db-${n}-conn` } })),
  ...caches.map((n) => ({ secretRef: { name: `cache-${n}-conn` } })),
  ...(secrets.length ? [{ secretRef: { name: `${app}-secrets` } }] : []),
];
if (envFrom.length) values.envFrom = envFrom;
if (served) values.route = { host, paths: config.route?.paths ?? ["/"], public: pub };
values.db = config.migrate
  ? { enabled: true, migrateCmd: config.migrate.cmd }
  : { enabled: false };
if (config.probes) values.probes = config.probes;
if (kind === "spa") values.spa = { server: config.spa?.server ?? "sws" };
// 선언적 회전: 봉인 콘텐츠 해시를 pod template annotation으로 둔다 → update-secrets가 봉인본을
// 갱신하면 이 해시가 바뀌어 ArgoCD가 Deployment를 롤링한다(envFrom 변경은 재시작 필요 —
// 명령형 rollout restart는 취소/실패 시 옛 값 유지라 선언적으로). 해시는 기록될 봉인본 바이트 기준.
if (sealedDoc) {
  const sealedYaml = toYaml(sealedDoc);
  values.podAnnotations = { "checksum/secrets": createHash("sha256").update(sealedYaml).digest("hex").slice(0, 16) };
}

// 권위 바인딩/정책 레지스트리 — teardown 참조 수 집계와 폴러 autoDeploy의 유일 소스
const bindings = { db: dbs, redis: caches, autoDeploy: config.deploy?.autoDeploy ?? true };

// ---------- 5) 산출물 ----------
const plan = {
  app, repo, tag, digest, kind, host: served ? host : null, replicas,
  reqMi, limitMi, ledger: { before: sumLimit, after: sumLimit + limitMi, budget },
  bindings, secrets,
  checklist: [
    `GHCR 패키지 public 전환 필요: https://github.com/orgs/${owner}/packages/container/${app}/settings — org 패키지는 첫 push 시 private이라 클러스터 pull이 401(ErrImagePull)로 실패한다(가시성 변경은 UI 전용)`,
  ],
};

if (!DRY) {
  mkdirSync(`${appDir}/deploy/prod`, { recursive: true });
  writeFileSync(`${appDir}/deploy/prod/values.yaml`, toYaml(values));
  writeFileSync(`${appDir}/deploy/prod/source-repo`, `${repo}\n`); // bump-poll의 발신 레포 바인딩
  writeFileSync(`${appDir}/deploy/prod/.bindings.json`, JSON.stringify(bindings, null, 2) + "\n");
  // kustomization은 secrets 유무와 무관하게 항상 필요(appset source #3가 kustomize 렌더 —
  // 없으면 values.yaml을 매니페스트로 파싱해 "groupVersion shouldn't be empty"로 죽는다)
  writeFileSync(`${appDir}/deploy/prod/kustomization.yaml`, toYaml({
    apiVersion: "kustomize.config.k8s.io/v1beta1", kind: "Kustomization",
    namespace: "prod",
    ...(secrets.length ? { resources: [`${app}-secrets.sealed.yaml`] } : {}),
  }));
  if (sealedDoc) writeFileSync(`${appDir}/deploy/prod/${app}-secrets.sealed.yaml`, toYaml(sealedDoc));
  if (served && pub) {
    registry.push({ name: app, host, public: true, active: false }); // active는 activate-app만 켠다
    writeFileSync(appsJsonPath, JSON.stringify(registry, null, 2) + "\n");
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
