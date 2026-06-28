// create-app 생성기 — 외부 앱 레포의 .app-config.yml(v2 계약)을 검증하고
// apps/<app>/deploy/prod/ + apps.json + 메모리 원장을 한 번에 갱신한다.
// 연결(DB/Redis)은 앱 SealedSecret(DATABASE_URL/REDIS_URL)으로 주입 — create-app은
// SealedSecret 시크릿·digest 핀 이미지·권위 바인딩 레지스트리(.bindings.json=autoDeploy)를 다룬다.
// _create-app.yaml(homelab-initiated workflow_dispatch)이 호출 — 결과물은 PR(사람 머지 = 승인).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { parse as parseYaml, stringify as toYaml } from "yaml";
import { APP_NAME_RE } from "./lib/identity.ts";
import { replaceTotals, addRow, parseLedgerRows } from "./lib/ledger-totals.ts";
import { parseFlags } from "./lib/cli.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed(arg()가 미지정 플래그를 조용히 무시하던 것 차단). 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--config", "--app", "--repo", "--domain", "--repo-root", "--tag", "--digest", "--sealed"], bool: ["--dry-run"] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --dry-run --config --app --repo --domain --repo-root --tag --digest --sealed`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const configPath = arg("--config");
const app = arg("--app");
const repo = arg("--repo");
const DOMAIN = arg("--domain");
const ROOT = arg("--repo-root", ".");
const tag = arg("--tag");
const digest = arg("--digest");
const sealedPath = arg("--sealed");
if (!configPath || !app || !repo || !DOMAIN || !tag || !digest) {
  console.error("usage: create-app --config <.app-config.yml> --app <name> --repo <owner/app> --domain <apex> --tag sha-<gitsha> --digest sha256:<hex> [--sealed <file>] [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}
function fail(msg: string): never { console.error(`::error::create-app: ${msg}`); process.exit(1); }

// ---------- 1) 식별자/이미지 핀 검증 ----------
if (!APP_NAME_RE.test(app)) fail(`app 이름 불량: '${app}'`);
if (!/^ukyi-app\/[A-Za-z0-9._-]+$/.test(repo)) fail(`repo는 ukyi-app org여야 한다: '${repo}'`);
const [owner, repoName] = repo.split("/");
if (repoName !== app) fail(`레포 이름(${repoName})과 app(${app}) 불일치 — 컨벤션: app=repo명`);
if (!/^sha-[0-9a-f]{7,40}$/.test(tag)) fail(`tag 형식 불량: '${tag}'`);
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) fail(`digest 형식 불량(불변 핀 필수): '${digest}'`);

let config;
try { config = parseYaml(readFileSync(configPath, "utf8")) ?? {}; }
catch (e: any) { fail(`.app-config.yml 파싱 실패: ${e.message}`); }

// ---------- 2) 스키마 검증 (app-config-schema.json이 계약 SSOT) ----------
const schema = JSON.parse(readFileSync(new URL("./app-config-schema.json", import.meta.url), "utf8"));
const deref = (s: any) => (s?.$ref ? schema.definitions[s.$ref.split("/").pop()] : s);
function check(val: any, sch: any, path: string) {
  sch = deref(sch);
  const t = sch.type;
  const is: Record<string, (v: any) => boolean> = { object: (v) => v && typeof v === "object" && !Array.isArray(v), array: Array.isArray,
    string: (v) => typeof v === "string", integer: Number.isInteger, boolean: (v) => typeof v === "boolean" };
  if (sch.enum) { if (!sch.enum.includes(val)) fail(`${path}: '${val}'은 ${JSON.stringify(sch.enum)} 중 하나여야 함`); return; }
  if (t && !is[t]?.(val)) fail(`${path}: ${t} 타입이어야 함`);
  if (t === "string" && sch.pattern && !new RegExp(sch.pattern).test(val)) fail(`${path}: 패턴 ${sch.pattern} 불일치 ('${val}')`);
  if (t === "integer") { if (sch.minimum != null && val < sch.minimum) fail(`${path}: ≥${sch.minimum}`);
    if (sch.maximum != null && val > sch.maximum) fail(`${path}: ≤${sch.maximum}`); }
  if (t === "array") { if (sch.minItems && val.length < sch.minItems) fail(`${path}: 최소 ${sch.minItems}개`);
    if (sch.uniqueItems && new Set(val.map(String)).size !== val.length) fail(`${path}: 중복 항목`);
    val.forEach((v: any, i: number) => check(v, sch.items, `${path}[${i}]`)); }
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
const served = kind !== "worker";
if (!served && config.route) fail("kind=worker는 route를 가질 수 없다");

const pub = config.route?.public ?? false;
let host = config.route?.host;
if (served) {
  const derived = pub ? `${app}.${DOMAIN}` : `${app}.home.${DOMAIN}`;
  if (!host) host = derived;
  else if (pub) { if (!host.endsWith(`.${DOMAIN}`) || host.endsWith(`.home.${DOMAIN}`)) fail(`public host는 *.${DOMAIN}(단, *.home.* 제외): '${host}'`); }
  else if (!host.endsWith(`.home.${DOMAIN}`)) fail(`internal host는 *.home.${DOMAIN}: '${host}'`);
}

const toMi = (m: string) => m.endsWith("Gi") ? parseInt(m) * 1024 : parseInt(m);
const toMilli = (c: string) => c.endsWith("m") ? parseInt(c) : parseInt(c) * 1000;
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
const rows = parseLedgerRows(ledger); // F7: 명명 필드(raw 인덱스 금지)
const names = rows.map((r) => r.name);
const sumReq = rows.reduce((a, r) => a + r.reqMi, 0);
const sumLimit = rows.reduce((a, r) => a + r.limitMi, 0);
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
  if (registry.some((r: any) => r.name === app)) fail(`apps.json에 name '${app}' 이미 존재`);
  if (registry.some((r: any) => r.host === host)) fail(`apps.json에 host '${host}' 이미 존재(오라우팅 차단)`);
}

// SealedSecret 시크릿: 봉인본이 있으면 encryptedData 키 목록을 권위로 삼아 배선한다.
let sealedDoc = null;
let secretKeys: string[] = [];
if (sealedPath) {
  sealedDoc = parseYaml(readFileSync(sealedPath, "utf8"));
  if (sealedDoc?.kind !== "SealedSecret") fail("sealed 파일이 kind: SealedSecret이 아니다");
  if (sealedDoc?.metadata?.namespace !== "prod") fail(`sealed namespace는 prod여야 한다(strict-scope): ${sealedDoc?.metadata?.namespace}`);
  if (sealedDoc?.metadata?.name !== `${app}-secrets`) fail(`sealed name은 ${app}-secrets여야 한다: ${sealedDoc?.metadata?.name}`);
  secretKeys = Object.keys(sealedDoc?.spec?.encryptedData ?? {}).sort();
  if (secretKeys.length === 0) fail("sealed encryptedData가 비어 있다");
  const badKeys = secretKeys.filter((key) => !/^[A-Z][A-Z0-9_]*$/.test(key));
  if (badKeys.length) fail(`sealed encryptedData 키는 UPPER_SNAKE여야 한다: ${badKeys.join(", ")}`);
}

// ---------- 4) values.yaml 구성 ----------
const values: Record<string, any> = {
  image: { repo: `ghcr.io/${owner}/${app}`, tag, digest }, // digest가 권위(불변), tag는 source SHA 추적
  kind, replicas,
  resources: { requests: { cpu: rq.cpu, memory: rq.memory }, limits: { cpu: lm.cpu, memory: lm.memory } },
};
const envFrom = sealedDoc ? [{ secretRef: { name: `${app}-secrets` } }] : [];
if (envFrom.length) values.envFrom = envFrom;
if (served) values.route = { host, paths: config.route?.paths ?? ["/"], public: pub };
if (config.probes) values.probes = config.probes;
// 외부 app-config는 kind만 선언한다. static 서버 구현체(SWS)는 chart 내부 계약으로 숨긴다.
if (kind === "static") values.static = { server: "sws" };
values.metrics = { enabled: config.metrics?.enabled ?? false };
// 선언적 회전: 봉인 콘텐츠 해시를 pod template annotation으로 둔다 → update-secrets가 봉인본을
// 갱신하면 이 해시가 바뀌어 ArgoCD가 Deployment를 롤링한다(envFrom 변경은 재시작 필요 —
// 명령형 rollout restart는 취소/실패 시 옛 값 유지라 선언적으로). 해시는 기록될 봉인본 바이트 기준.
if (sealedDoc) {
  const sealedYaml = toYaml(sealedDoc);
  values.podAnnotations = { "checksum/secrets": createHash("sha256").update(sealedYaml).digest("hex").slice(0, 16) };
}

// 권위 정책 레지스트리 — 폴러(poll-ghcr) autoDeploy 승인 게이트의 유일 소스
const bindings = { autoDeploy: config.deploy?.autoDeploy ?? true };

// ---------- 5) 산출물 ----------
const plan = {
  app, repo, tag, digest, kind, host: served ? host : null, replicas,
  reqMi, limitMi, ledger: { before: sumLimit, after: sumLimit + limitMi, budget },
  bindings, secretKeys,
  checklist: [
    `이미지 pull: ghcr-pull imagePullSecret(prod NS)로 private 패키지 pull — 패키지 가시성 public 전환 불필요`,
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
    ...(sealedDoc ? { resources: [`${app}-secrets.sealed.yaml`] } : {}),
  }));
  if (sealedDoc) writeFileSync(`${appDir}/deploy/prod/${app}-secrets.sealed.yaml`, toYaml(sealedDoc));
  if (served && pub) {
    // create-app PR 머지가 첫 공개 승인이다. 머지 후 iac.yaml이 이 active:true 행을 DNS/tunnel에 적용한다.
    registry.push({ name: app, host, public: true, active: true });
    writeFileSync(appsJsonPath, JSON.stringify(registry, null, 2) + "\n");
  }
  // 원장: 마지막 row 다음에 행 추가 + Totals 프로즈 갱신
  let out = addRow(ledger, { name: app, env: "prod", reqMi, limitMi });
  out = replaceTotals(out, sumReq + reqMi, sumLimit + limitMi);
  writeFileSync(ledgerPath, out);
}
console.log(JSON.stringify(plan, null, 2));
