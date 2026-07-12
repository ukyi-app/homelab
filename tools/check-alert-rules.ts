// vmalert 룰 expr 정적 lint — "문법은 유효한데 eval-time에 죽는" 결함 3종(모드 A/B/C) 재발 방지.
// 모드 A/B = instance-라벨 불안정(재부팅 IP churn 오탐, PR #327) · 모드 C = push 주기 > instant 룩백
// (죽은 알림, PR #339/#341).
//
// 배경: 호스트 재부팅이면 파드 오브젝트가 그대로여도 CNI가 파드 IP를 재할당해 스크레이프 타깃의
// `instance` 라벨이 바뀐다. 시계열 정체성이 갈리면서 두 파괴 모드가 나온다(둘 다 문법은 유효해서
// required 게이트인 `vmalert -dryRun`을 통과한다 — 그래서 4회 재발했다).
//
//   모드 A — rollup(increase/rate/…)이 **상태-파생 카운터**(exporter 재시작에도 값이 0으로 리셋되지
//            않는 것, 예: KSM의 kube_pod_container_status_restarts_total)에 걸려 있으면, 새 instance
//            시계열의 첫 샘플(=누적값)을 VM이 "0에서 증가"로 읽어 누적값을 통째로 증가분으로 오독한다.
//            → rollup **이전에** 집계로 instance를 벗겨야 한다(서브쿼리 필수).
//            프로세스-로컬 카운터(alertmanager_*/vmagent_*/vmalert_*)는 재시작 시 0 리셋이라 무해 —
//            그래서 판정 기준은 "rollup을 썼는가"가 아니라 "denylist 메트릭인가"다.
//
//   모드 B — 산술 이항 연산이 on()/ignoring()으로 instance를 매칭키에서 빼는데 피연산자가 raw 셀렉터면,
//            구/신 instance 시계열이 staleness(~5분) 동안 공존해 그룹당 2 시계열 → many-to-many →
//            "duplicate time series on the … side of" HTTP 422 → 룰 평가 실패.
//            → 양변을 max by(...)로 사전 집계해 1:1 매칭을 강제해야 한다.
//            (and/or/unless는 집합 연산자라 중복에 422를 내지 않는다 — 대상 아님.)
//
//   모드 C — **push(스크레이프 아닌) 메트릭을 rollup 없이 맨 참조**하면 그 룰은 어떤 조건에서도 발화하지
//            못한다. vmalert의 instant 질의 룩백은 `-datasource.queryStep`(미지정 시 기본 **5m**)인데 push
//            주기가 그보다 길면 매 주기 후반에 시리즈가 vmalert 눈에서 사라진다 → 룰 시리즈에 구멍 →
//            `for:` pending이 매 주기 리셋 → 임계 시간을 영원히 누적 못한다(`ImageDigestDrift` 라이브 60일
//            발화 0 · `FilesBulkSSDLow` 동일). 시리즈가 "없다"는 게 증상이라 **아무 신호도 나지 않는다**.
//            → 읽는 쪽에서 `last_over_time(m[W])`로 감싸야 한다(**W ≥ push 주기**).
//
// 한계(의도적):
//  - 정적 패턴 검사라 remediation의 **정확성**은 보장하지 않는다. 특히 모드 A의 집계자는 `max`여야 한다 —
//    순진한 `sum without(instance)`는 staleness 중첩 구간에서 값이 배가된다. denylist는 큐레이트 목록이라
//    미래의 상태-파생 `increase(kube_*_total)`은 목록 확장이 필요하다(false-negative 가능).
//  - 모드 C가 강제하는 것은 **하한(W ≥ 주기)뿐**이다. 이것만이 보편적으로 참이다. 강화판 두 개는 룰마다
//    값이 갈려 린터가 판정할 수 없다 → 각 e2e 게이트의 preflight 산술 단언 소관이다:
//      · 누락 내성 **W ≥ 2×주기**를 여기서 강제하면 안 된다 — 배포된 `ImageDigestDrift` 픽스(W=15m,
//        주기 10m)가 FAIL한다. W=15m은 `for: 20m` **상한 때문에 강제된 선택**이다.
//      · **상한 W < `for:`** (라벨-값 상태 게이지 한정 — rollup 윈도가 구 상태를 되살리는 래치라서).
//        타임스탬프-값 하트비트(r4의 `time() - last_over_time(...)`)엔 상한이 없다 → 이 비대칭은
//        린터가 구분할 수 없다. cf. `docs/traps-detail.md` 「rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭」.
//  - 모드 C의 record 체인: 기록룰이 rollup을 착용하면 그 **record명**은 연속 시리즈라 이를 참조하는 alert는
//    검사 대상이 아니다(이중 계산 금지 — push 메트릭명만 매칭하므로 구조적으로 성립). 기록룰이 맨 참조면
//    결함은 **기록룰 1건**으로만 보고된다(소비 alert에서 중복 보고하지 않는다).
//
// check-resource-limits.ts를 미러한다(--repo-root · scan-floor · allowlist · 한국어 메시지).
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { parse, parseAllDocuments } from "yaml";
import { parseFlags } from "./lib/cli.ts";

let f: Record<string, string | boolean>;
try { f = parseFlags(process.argv.slice(2), { value: ["--repo-root"], bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";

const RULES_DIR = "platform/victoria-stack/prod/rules";
const DENYLIST = "policy/alert-instance-stability-denylist.txt";
const ALLOWLIST = "policy/alert-instance-stability-allowlist.txt";
const MIN_SCAN = 30;   // 실 룰 41건(40 alert + 1 record) — 셀렉터 붕괴 false-green 차단

// rollup(range) 함수 — 이들만 시계열 첫 샘플을 "0에서 증가"로 취급할 수 있다.
const ROLLUP = "increase|increase_pure|increase_prometheus|rate|rate_prometheus|irate|delta|idelta|deriv|resets|changes";
// 라벨을 벗길 수 있는 집계 연산자.
const AGG = "max|min|sum|avg|count|group|topk|bottomk|quantile|stddev|stdvar";
const OPERAND_AGG_RE = new RegExp(`^[\\s(]*(?:${AGG})\\s+(?:by|without)\\s*\\(`);
// 집합 연산자 — on()을 써도 422가 불가능하다.
const SET_OP_RE = /(?:^|[^\w])(and|or|unless)\s*$/;
// 산술·비교 이항 연산자(on() 직전에 올 수 있는 것).
const BIN_OP_RE = /(?:==|!=|>=|<=|[+\-*/%^]|>|<)\s*$/;

// ── 모드 C 상수 ──
// vmalert instant 질의 룩백. `-datasource.queryStep` 미지정 시의 기본값(문서화되지 않은 상수).
// 이보다 push 주기가 길면 rollup 없이는 시리즈에 구멍이 난다.
const LOOKBACK = 300;
// VictoriaMetrics push 엔드포인트 — 생산자의 지문(완전성 가드가 이걸로 스캔한다).
const IMPORT_NEEDLE = "api/v1/import";
// 자기 참조 제외: 이 파일이 needle을 문자열 리터럴로 들고 있다.
const SELF = "tools/check-alert-rules.ts";
// 생산자가 살 수 있는 표면(큐레이트) — 레포 전체 walk는 금물(루트에 scratch/워크트리 잔재가 있다).
const PRODUCER_ROOTS = ["platform", "scripts", "infra", "tools", "apps", "ops", ".github"];
const PRODUCER_EXT = [".yaml", ".yml", ".sh", ".ts", ".mts", ".js", ".mjs", ".py"];
// 스캔 제외 디렉토리: 벤더 helm 캐시(charts) · 하네스(tests) · 의존성.
const SKIP_DIRS = new Set([".git", "node_modules", "charts", "tests", ".terraform", "dist"]);
// rollup(range) 함수 — push 구멍을 메우는 것은 `*_over_time` 계열이다.
const OVER_TIME_RE = /\b(\w+_over_time)\s*\(/g;

// push 메트릭 레지스트리 (큐레이트 — 모드 A denylist와 같은 성격이나, 항목이 구조체라 코드에 둔다).
//   metric   = 룰 expr에서 매칭할 시계열 이름
//   producer = `api/v1/import`를 호출하는 파일(= 완전성 가드가 스캔에서 만나는 파일). 레지스트리에
//              없는 생산자가 나타나면 FAIL — "새 push exporter를 추가하고 메트릭 등록을 잊는" 경로 차단.
//   schedule = 크론이 사는 매니페스트(생산자 파일과 다를 수 있다). **주기는 여기서 파생**하고 periodSec는
//              폴백/문서값이다 — 불일치하면 FAIL(크론만 바꾸고 레지스트리를 안 고치는 드리프트 차단).
//   periodSec= 레포 밖 스케줄(launchd 등)이거나 schedule 파일이 없을 때의 상수 + 근거 주석.
type PushEntry = { metric: string; producer: string; schedule?: string; periodSec: number };
const PUSH_METRICS: PushEntry[] = [
  // digest-exporter CronJob `*/10 * * * *`.
  { metric: "ghcr_latest_digest", producer: "platform/victoria-stack/prod/digest-exporter.yaml",
    schedule: "platform/victoria-stack/prod/digest-exporter.yaml", periodSec: 600 },
  // pvc-du-exporter CronJob `0 5 * * *`(일 1회 05:00 KST).
  ...["pvc_dir_size_bytes", "storage_tier_size_bytes", "storage_tier_avail_bytes", "pvc_du_last_success_timestamp"]
    .map((metric) => ({ metric, producer: "platform/victoria-stack/prod/pvc-du-exporter.yaml",
      schedule: "platform/victoria-stack/prod/pvc-du-exporter.yaml", periodSec: 86400 })),
  // adguard rewrite-reconciler CronJob `*/10 * * * *`.
  ...["adguard_rewrite_reconcile_timestamp", "adguard_rewrite_last_fix_timestamp"]
    .map((metric) => ({ metric, producer: "platform/adguard/prod/rewrite-reconciler.yaml",
      schedule: "platform/adguard/prod/rewrite-reconciler.yaml", periodSec: 600 })),
  // restore-drill: push는 스크립트가, 크론(`0 5 * * 0` 주 1회)은 별도 CronJob 매니페스트가 들고 있다.
  { metric: "restore_drill_last_success_timestamp", producer: "platform/cnpg/prod/restore-drill-script.sh",
    schedule: "platform/cnpg/prod/restore-drill-cronjob.yaml", periodSec: 604800 },
  // files 백업: 스케줄이 **레포 밖**(호스트 launchd, 일 1회 — RPO 24h · 런북 external-ssd.md)이라
  // 파생 불가 → 상수. launchd plist를 바꾸면 이 값도 함께 고쳐야 한다(파생 가드 없음 — 알려진 한계).
  ...["files_backup_last_success_timestamp", "files_data_bulk_avail_bytes", "files_data_bulk_size_bytes"]
    .map((metric) => ({ metric, producer: "scripts/backup-files-data.sh", periodSec: 86400 })),
];

function readList(rel: string): string[] {
  const p = `${ROOT}/${rel}`;
  return existsSync(p) ? readFileSync(p, "utf8").split("\n") : [];
}

// 문자열 리터럴 내부를 같은 길이의 채움문자로 마스킹 — 괄호/연산자 구조 스캔이 라벨 값에 속지 않게.
function maskStrings(s: string): string {
  const out = s.split("");
  let q: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === "\\") { out[i] = "_"; if (i + 1 < s.length) out[++i] = "_"; continue; }
      if (c === q) { q = null; continue; }
      out[i] = "_";
    } else if (c === '"' || c === "'" || c === "`") { q = c; }
  }
  return out.join("");
}

// pos의 '(' 에 대응하는 ')' 인덱스. 못 찾으면 -1.
function matchParen(s: string, open: number): number {
  let d = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "(") d++;
    else if (s[i] === ")") { d--; if (d === 0) return i; }
  }
  return -1;
}

// end(배타) 직전의 피연산자 시작 인덱스 — 괄호 균형을 역방향 추적, 감싸는 '('를 만나면 멈춘다.
function operandStart(s: string, end: number): number {
  let d = 0;
  for (let i = end - 1; i >= 0; i--) {
    const c = s[i];
    if (c === ")") d++;
    else if (c === "(") { d--; if (d < 0) return i + 1; }
  }
  return 0;
}

// start(포함) 이후의 피연산자 끝 인덱스(배타) — 감싸는 ')' 또는 최상위 이항 연산자에서 멈춘다.
function operandEnd(s: string, start: number): number {
  let d = 0;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (c === "(") d++;
    else if (c === ")") { d--; if (d < 0) return i; }
    else if (d === 0 && /[+\-*/%^<>=!]/.test(c) && i > start) return i;
  }
  return s.length;
}

function fatal(msg: string): never { console.error(`FAIL: ${msg}`); process.exit(1); }

// MetricsQL 기간 리터럴 → 초. 복합(`1h30m`) 허용. 파싱 실패는 null(호출부에서 fail-loud).
function durationSec(d: string): number | null {
  const t = d.trim();
  if (!/^(?:\d+[smhdw])+$/.test(t)) return null;
  const U: Record<string, number> = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 };
  let sec = 0;
  for (const mt of t.matchAll(/(\d+)([smhdw])/g)) sec += parseInt(mt[1], 10) * U[mt[2]];
  return sec;
}

function fmtSec(s: number): string {
  if (s % 86400 === 0) return `${s / 86400}d`;
  if (s % 3600 === 0) return `${s / 3600}h`;
  if (s % 60 === 0) return `${s / 60}m`;
  return `${s}s`;
}

// cron → 연속 실행 간격(초). 이 레포가 실제로 쓰는 형태만 지원하고 나머지는 **fail-loud**(추측 금지).
function cronPeriodSec(sched: string, where: string): number {
  const f = sched.trim().split(/\s+/);
  const bad = (why: string): never => fatal(
    `${where}: cron "${sched}" 주기 파생 실패(${why}) — 지원 형태(*/N * * * * · M H * * * · M H * * D)가 아니다. ` +
    `PUSH_METRICS의 schedule을 떼고 periodSec 상수 + 근거 주석으로 고정하라.`);
  if (f.length !== 5) bad("필드 5개가 아님");
  const [mi, ho, dom, mon, dow] = f;
  if (mon !== "*" || dom !== "*") bad("월/일 필드 고정은 미지원");
  if (dow !== "*") {
    if (!/^\d$/.test(dow) || !/^\d+$/.test(mi) || !/^\d+$/.test(ho)) bad("요일 지정인데 분/시가 고정값이 아님");
    return 604800;   // 주 1회
  }
  const em = /^\*\/(\d+)$/.exec(mi);
  const eh = /^\*\/(\d+)$/.exec(ho);
  if (ho === "*") {
    if (mi === "*") return 60;
    if (em) return parseInt(em[1], 10) * 60;
    if (/^\d+$/.test(mi)) return 3600;   // 매시 정각 1회
    bad("분 필드 형태 미지원");
  }
  if (eh && /^\d+$/.test(mi)) return parseInt(eh[1], 10) * 3600;
  if (/^\d+$/.test(ho) && /^\d+$/.test(mi)) return 86400;   // 일 1회
  return bad("시 필드 형태 미지원");
}

// 매니페스트에서 CronJob 스케줄 1건을 뽑는다(다중 CronJob = 모호 → fail-loud).
function cronOf(rel: string): string {
  const found: string[] = [];
  for (const doc of parseAllDocuments(readFileSync(`${ROOT}/${rel}`, "utf8"))) {
    const o = doc.toJS() as any;
    if (o?.kind === "CronJob" && typeof o?.spec?.schedule === "string") found.push(o.spec.schedule);
  }
  if (found.length !== 1) fatal(`${rel}: CronJob 스케줄 ${found.length}건 — 1건이어야 한다(레지스트리 schedule 경로 확인)`);
  return found[0];
}

// 생산자 표면 walk — `api/v1/import` 호출부를 찾는다(하네스·벤더·자기 자신 제외).
function walkProducers(rel: string, out: string[]): void {
  let ents;
  try { ents = readdirSync(`${ROOT}/${rel}`, { withFileTypes: true }); } catch { return; }
  for (const e of ents.sort((a, b) => a.name.localeCompare(b.name))) {
    const r = `${rel}/${e.name}`;
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walkProducers(r, out); continue; }
    if (!e.isFile() || r === SELF) continue;
    if (e.name.startsWith("test_") || e.name.endsWith(".bats")) continue;   // 하네스/픽스처는 생산자가 아니다
    if (!PRODUCER_EXT.some((x) => e.name.endsWith(x))) continue;
    if (readFileSync(`${ROOT}/${r}`, "utf8").includes(IMPORT_NEEDLE)) out.push(r);
  }
}

// `#` 주석을 줄 끝까지 마스킹(문자열 마스킹 **후** 호출 — 라벨 값 안의 '#'에 속지 않게).
function maskComments(s: string): string {
  const out = s.split("");
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== "#") continue;
    while (i < s.length && s[i] !== "\n") out[i++] = " ";
  }
  return out.join("");
}

// from(메트릭명 직후) 위치에서 range 셀렉터 `[W]`/`[W:step]`를 읽는다. 라벨 매처 `{...}`는 건너뛴다.
function rangeAt(s: string, from: number): string | null {
  let j = from;
  const ws = () => { while (j < s.length && /\s/.test(s[j])) j++; };
  ws();
  if (s[j] === "{") { const c = s.indexOf("}", j); if (c < 0) return null; j = c + 1; ws(); }
  if (s[j] !== "[") return null;
  const c = s.indexOf("]", j);
  if (c < 0) return null;
  return s.slice(j + 1, c).split(":")[0].trim();   // 서브쿼리 [W:step]도 앞이 W
}

const denyMetrics = readList(DENYLIST).map((l) => l.split("#", 1)[0].trim()).filter(Boolean);

// ── 모드 C 전처리: 완전성 가드 + 주기 파생 ──
// (1) 레지스트리에 없는 push 생산자가 있으면 FAIL. (2) 주기는 가능한 한 매니페스트 cron에서 파생하고,
//     상수와 어긋나면 FAIL(크론만 바꾸고 레지스트리를 안 고치는 드리프트 차단).
const producerViol: string[] = [];
const foundProducers: string[] = [];
for (const root of PRODUCER_ROOTS) walkProducers(root, foundProducers);

const registered = new Set(PUSH_METRICS.map((e) => e.producer));
for (const p of foundProducers) {
  if (!registered.has(p)) {
    producerViol.push(`${p} — '${IMPORT_NEEDLE}'로 메트릭을 push하는데 PUSH_METRICS 레지스트리에 없음`);
  }
}

const pushPeriod = new Map<string, number>();   // 메트릭 → push 주기(초)
for (const e of PUSH_METRICS) {
  // 생산자가 실재하면 여전히 push하는지 확인(레지스트리 부패 차단). 임시 루트 스캔에선 부재 → 스킵.
  if (existsSync(`${ROOT}/${e.producer}`) && !readFileSync(`${ROOT}/${e.producer}`, "utf8").includes(IMPORT_NEEDLE)) {
    fatal(`${e.producer}: '${IMPORT_NEEDLE}' 호출이 사라졌다(${e.metric}) — PUSH_METRICS 레지스트리 항목이 낡았다`);
  }
  // 주기: 매니페스트 cron이 권위(있으면). 상수와 어긋나면 FAIL. cron이 레포 밖(launchd)이면 상수 폴백.
  let period = e.periodSec;
  if (e.schedule && existsSync(`${ROOT}/${e.schedule}`)) {
    period = cronPeriodSec(cronOf(e.schedule), e.schedule);
    if (period !== e.periodSec) {
      fatal(`${e.schedule}: cron 주기 ${period}s ≠ 레지스트리 periodSec ${e.periodSec}s(${e.metric}) — ` +
        `크론을 바꿨으면 PUSH_METRICS 상수와 이 메트릭을 읽는 룰의 rollup 윈도(W ≥ 주기)를 함께 갱신하라.`);
    }
  }
  pushPeriod.set(e.metric, period);
}
// 모드 C 대상 = 주기가 룩백보다 긴 메트릭만(≤300s는 룩백 안에 항상 샘플이 있어 구멍이 안 난다).
const modeCMetrics = PUSH_METRICS.filter((e) => (pushPeriod.get(e.metric) as number) > LOOKBACK).map((e) => e.metric);

// allowlist: `<alert>` 또는 `<file>:<alert>` + 사유 주석(`#`) 필수 — 무근거 면제 차단.
const allowed = new Set<string>();
const allowErrors: string[] = [];
readList(ALLOWLIST).forEach((line, i) => {
  const raw = line.trim();
  if (!raw || raw.startsWith("#")) return;
  const key = raw.split("#", 1)[0].trim();
  if (!raw.includes("#")) { allowErrors.push(`${ALLOWLIST}:${i + 1} '${key}' — 사유 주석(#) 없음`); return; }
  allowed.add(key);
});

const dir = `${ROOT}/${RULES_DIR}`;
const files = (existsSync(dir) ? readdirSync(dir) : []).filter((p) => p.endsWith(".yaml")).sort();

let ruleCount = 0;
const viol: string[] = [];

// expr 1건 검사. name = alert명(또는 record명), rel = 룰 ConfigMap 파일 경로.
function checkExpr(rel: string, name: string, expr: string): void {
  const m = maskStrings(expr);
  const isAllowed = allowed.has(name) || allowed.has(`${rel}:${name}`);

  // ── 모드 A: rollup 인자에 denylist(상태-파생) 메트릭이 있으면 instance 제거 증거를 요구 ──
  const rollupRe = new RegExp(`\\b(${ROLLUP})\\s*\\(`, "g");
  for (let mt = rollupRe.exec(m); mt; mt = rollupRe.exec(m)) {
    const open = mt.index + mt[0].length - 1;
    const close = matchParen(m, open);
    if (close < 0) { viol.push(`${rel} ${name} [모드 A: rollup 괄호 불균형 — 파싱 실패]`); return; }
    const arg = m.slice(open + 1, close);
    const hit = denyMetrics.find((d) => new RegExp(`\\b${d}\\b`).test(arg));
    if (!hit) continue;   // 프로세스-로컬 카운터 = 안전(재시작 시 0 리셋)
    const agg = new RegExp(`\\b(?:${AGG})\\s+(by|without)\\s*\\(([^)]*)\\)`).exec(arg);
    const sub = /\[[^\]]*:[^\]]*\]/.test(arg);   // 집계 위 rollup은 서브쿼리여야 한다
    let bad = "";
    if (!agg) bad = "rollup 이전에 instance를 벗기는 집계(max by/without)가 없음";
    else if (agg[1] === "by" && /\binstance\b/.test(agg[2])) bad = "by(...) 목록에 instance가 남아 있음";
    else if (agg[1] === "without" && !/\binstance\b/.test(agg[2])) bad = "without(...) 목록에 instance가 없음";
    else if (!sub) bad = "집계 위 rollup인데 서브쿼리 [기간:step]가 없음";
    if (bad) {
      if (isAllowed) continue;
      viol.push(`${rel} ${name} [모드 A: ${hit} — ${bad}]`);
    }
  }

  // ── 모드 B: 산술 이항 + on()/ignoring() 인데 피연산자가 raw 셀렉터면 422 위험 ──
  const onRe = /\b(on|ignoring)\s*\(/g;
  for (let mt = onRe.exec(m); mt; mt = onRe.exec(m)) {
    const before = m.slice(0, mt.index);
    if (SET_OP_RE.test(before)) continue;                 // and/or/unless = 422 불가
    const opMatch = BIN_OP_RE.exec(before);
    if (!opMatch) { viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 앞의 연산자를 못 찾음 — 파싱 실패]`); return; }
    if (isAllowed) continue;
    const opPos = before.length - opMatch[0].length;      // 연산자 시작 위치
    const lhs = m.slice(operandStart(m, opPos), opPos);
    const onOpen = mt.index + mt[0].length - 1;
    const onClose = matchParen(m, onOpen);
    if (onClose < 0) { viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 괄호 불균형 — 파싱 실패]`); return; }
    const rhs = m.slice(onClose + 1, operandEnd(m, onClose + 1));
    const bare: string[] = [];
    if (!OPERAND_AGG_RE.test(lhs)) bare.push("좌변");
    if (!OPERAND_AGG_RE.test(rhs)) bare.push("우변");
    if (bare.length) {
      viol.push(`${rel} ${name} [모드 B: ${mt[1]}() 산술 조인의 ${bare.join("·")}이 집계 미포함 raw 셀렉터 — max by(...)로 사전 집계 필요]`);
    }
  }

  // ── 모드 C: push 주기 > 룩백(300s)인 메트릭은 윈도 ≥ 주기인 rollup 안에서만 참조 가능 ──
  const mc = maskComments(m);   // 문자열 마스킹 후 주석까지 제거 — 라벨 값/주석 오탐 차단
  // 이 expr 안의 모든 `*_over_time(...)` 구간(서브쿼리 폴백용).
  const spans: Array<{ open: number; close: number }> = [];
  OVER_TIME_RE.lastIndex = 0;
  for (let mt = OVER_TIME_RE.exec(mc); mt; mt = OVER_TIME_RE.exec(mc)) {
    const open = mt.index + mt[0].length - 1;
    const close = matchParen(mc, open);
    if (close < 0) { viol.push(`${rel} ${name} [모드 C: ${mt[1]}() 괄호 불균형 — 파싱 실패]`); return; }
    spans.push({ open, close });
  }

  for (const metric of modeCMetrics) {
    const period = pushPeriod.get(metric) as number;
    const why = `push 주기 ${period}s > vmalert instant 룩백 ${LOOKBACK}s → 매 주기 시리즈에 구멍 → ` +
      `for: pending이 매 주기 리셋 → **어떤 조건에도 발화 불가**`;
    const fix = `last_over_time(${metric}[≥${fmtSec(period)}])로 감싸라 (전문: docs/traps-detail.md)`;
    const re = new RegExp(`\\b${metric}\\b`, "g");
    for (let mt = re.exec(mc); mt; mt = re.exec(mc)) {
      const at = mt.index + metric.length;
      // 1) 메트릭에 직접 붙은 range `[W]` — 정규 형태 `last_over_time(m{...}[W])`.
      // 2) 없으면 이 메트릭을 감싸는 최내곽 `*_over_time(...)`의 서브쿼리 `[W:step]`.
      let w = rangeAt(mc, at);
      if (w === null) {
        const encl = spans.filter((s) => s.open < mt!.index && mt!.index < s.close)
          .sort((a, b) => (b.open - a.open))[0];
        const sq = encl ? /\[\s*([^\]:\s]+)\s*:[^\]]*\]/.exec(mc.slice(encl.open + 1, encl.close)) : null;
        w = sq ? sq[1] : null;
      }
      if (isAllowed) continue;
      if (w === null) {
        viol.push(`${rel} ${name} [모드 C: ${metric}를 rollup 밖에서 맨 참조 — ${why}. ${fix}]`);
        continue;
      }
      const wsec = durationSec(w);
      if (wsec === null) {
        viol.push(`${rel} ${name} [모드 C: ${metric}의 rollup 윈도 '${w}' 파싱 실패 — 기간 리터럴(예: 15m·3d)이어야 한다]`);
        continue;
      }
      if (wsec < period) {
        viol.push(`${rel} ${name} [모드 C: ${metric}의 rollup 윈도 ${w}(${wsec}s) < push 주기 ${period}s — ` +
          `주기 사이 구멍이 남아 for: pending이 리셋된다. 윈도를 ≥ ${fmtSec(period)}로 넓혀라 (전문: docs/traps-detail.md)]`);
      }
    }
  }
}

for (const fn of files) {
  const rel = `${RULES_DIR}/${fn}`;
  const text = readFileSync(`${ROOT}/${rel}`, "utf8");
  for (const doc of parseAllDocuments(text)) {
    if (doc.errors.length) { console.error(`FAIL: YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`); process.exit(1); }
    const o = doc.toJS() as any;
    if (!o || o.kind !== "ConfigMap" || !o.data) continue;
    for (const [key, body] of Object.entries(o.data as Record<string, string>)) {
      if (!key.endsWith(".yaml") || typeof body !== "string") continue;
      let inner: any;
      try { inner = parse(body); }
      catch (e) { console.error(`FAIL: 룰 본문 파싱 실패: ${rel} .data["${key}"]: ${e instanceof Error ? e.message : e}`); process.exit(1); }
      for (const g of inner?.groups ?? []) {
        for (const r of g?.rules ?? []) {
          const name = r?.alert ?? r?.record;
          if (!name || typeof r?.expr !== "string") continue;
          ruleCount++;
          checkExpr(rel, name, r.expr);
        }
      }
    }
  }
}

if (allowErrors.length) {
  console.log(`FAIL: ${ALLOWLIST} 항목에 사유 주석이 없다 — 무근거 면제는 금지:`);
  for (const e of allowErrors) console.log("  " + e);
  process.exit(1);
}
// scan-floor: 룰 추출이 붕괴하면 아무것도 검사 안 하고 GREEN — fail-loud.
if (ruleCount < MIN_SCAN) {
  console.error(`FAIL: 스캔 룰 ${ruleCount}건 < ${MIN_SCAN} — 룰 추출 회귀 의심(${RULES_DIR} 재배치 또는 ConfigMap .data 키 변경?)`);
  process.exit(1);
}
// 완전성 가드: 새 push 생산자가 레지스트리에 없으면 모드 C가 그 메트릭을 **조용히 통과**시킨다(fail-open).
if (producerViol.length) {
  console.log("FAIL: push 메트릭 생산자가 PUSH_METRICS 레지스트리에 없다 — 미등록 메트릭은 모드 C 검사를 " +
    "빠져나가 죽은 알림으로 배포된다. tools/check-alert-rules.ts의 PUSH_METRICS에 메트릭·생산자·주기를 등재하라:");
  for (const p of producerViol) console.log("  " + p);
  process.exit(1);
}
if (viol.length) {
  console.log("FAIL: vmalert 룰 expr 안티패턴(모드 A/B=instance 라벨 불안정 · 모드 C=push 주기 > 룩백) — " +
    "수정하거나 " + ALLOWLIST + "에 사유와 함께 등재:");
  for (const v of viol) console.log("  " + v);
  process.exit(1);
}
console.log(`check-alert-rules OK (${ruleCount} 룰 스캔, push 생산자 ${foundProducers.length}건, 모드 A/B/C 위반 0)`);
