// vmalert 룰 instance-라벨 안정성 가드 — 재부팅 IP churn 오탐(PR #327) 재발 방지.
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
// 한계(의도적): 정적 패턴 검사라 remediation의 **정확성**은 보장하지 않는다. 특히 집계자는 `max`여야
// 한다 — 순진한 `sum without(instance)`는 staleness 중첩 구간에서 값이 배가된다. denylist는 큐레이트
// 목록이라 미래의 상태-파생 `increase(kube_*_total)`은 목록 확장이 필요하다(false-negative 가능).
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

const denyMetrics = readList(DENYLIST).map((l) => l.split("#", 1)[0].trim()).filter(Boolean);

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
if (viol.length) {
  console.log("FAIL: instance 라벨 불안정 안티패턴(재부팅 IP churn 오탐) — 수정하거나 " + ALLOWLIST + "에 사유와 함께 등재:");
  for (const v of viol) console.log("  " + v);
  process.exit(1);
}
console.log(`check-alert-rules OK (${ruleCount} 룰 스캔, 모드 A/B 위반 0)`);
