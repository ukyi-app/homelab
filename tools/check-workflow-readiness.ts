// G-09 — 워크플로 **준비상태 회계**. "자격/설정이 없어 job이 통째로 skip됐는데 run은 초록"을 닫는다.
//
// 병: GHA job conclusion 어휘는 success|failure|cancelled|skipped뿐이고, **스텝-레벨로 게이트된 job은
// 스텝을 전부 skip해도 job이 success로 끝난다**. 실패 알림 스텝도 같은 job 안에 있으면 함께 skip되므로
// owner에게 가는 신호가 정확히 0이다. 라이브 실측(2026-07-27): tf-reconcile의 drift-github·drift-tailscale은
// TF_GITHUB_TOKEN/TF_TAILSCALE_OAUTH_ID가 Actions 시크릿에 없어 **한 번도 실행된 적이 없는데** 매 30분
// run이 초록이었다 — 신뢰 앵커(branch protection·CI 시크릿·tailscale ACL) 드리프트 감시가 무음 정지 상태.
//
// ⚠️ 이 계층엔 exit 4(skip) 채널이 없다. skip된 job은 스텝을 0개 실행하므로 **그 안에서는 어떤 신호도
// 낼 수 없다**(`if: always()` 스텝조차 안 돈다 — 라이브 실측). 유일한 관측점은 게이트 **밖**의 별도
// accounting job이 `needs.*.result` / `needs.*.outputs.executed`를 읽는 것이다.
//
// **두 모드가 한 파일에 있는 이유**: 원장 파싱·게이트 탐지 규칙이 SSOT여야 하기 때문이다. 정적 가드가
// 탐지한 게이트 종류(job/step)와 런타임 회계가 판정에 쓰는 종류가 갈리면, 정적이 초록인데 런타임이
// 엉뚱한 필드를 보는 조합이 생긴다.
//   · 정적(ci.yaml gate)   — 원장 ↔ 실제 워크플로 양방향 대조. 미선언 게이트·죽은 선언·회계 job 부재를 막는다.
//   · 런타임(--workflow)   — 각 워크플로의 accounting job이 호출. 이번 run에서 무엇이 안 돌았는지 판정.
//
// **이 가드가 다루지 않는 것 — 도메인-크기 게이트.** "검사 대상이 0건이라 skip"은 자격 부재가 아니라
// 열거 붕괴 클래스(티켓 08)이고 처방이 다르다(바닥값 = scan-floor). 그래서 탐지기는 **자격 변수의 공백
// 검사**를 요구한다: `secrets.*`/`vars.*`에서 온 env 변수를 `[ -n "$X" ]`로 재고 그 결과로 플래그를
// 내리는 형태만 준비상태 게이트다. 이 선이 없으면 terraform `drift=false` 같은 **결과 플래그**가 전부
// 준비상태로 오탐된다(실측: tf-reconcile에 그런 자리가 3곳 있다).
//
// ⚠️ **탐지기는 프록시다.** 자격 게이트를 다른 모양으로 쓰면(예: 액션 출력으로 준비상태를 판정) 조용히
// 탐지에서 빠진다. 최소 방어로 gate 테스트에 **양성 대조**를 둔다(현재 알려진 사이트 전건이 탐지되는지) —
// 탐지기가 좁아지면 "미선언 0건"이 계속 참이라 통과하는 방향을 그 단언이 막는다.
//
// 종료코드: tools/lib/cli.ts 규약(0=통과 · 1=검증 실패 · 2=사용법). skip(4)은 내지 않는다 — 이 가드의
// 도메인(워크플로 + 원장)은 레포에 항상 있고, 없으면 그건 skip이 아니라 붕괴다.
import { appendFileSync, readFileSync } from "node:fs";
import { parse } from "yaml";
import { typedFlags } from "./lib/cli.ts";
import { walkManifests } from "./lib/repo-walk.ts";

const POLICY_PATH = "policy/workflow-readiness.json";
const WORKFLOW_DIR = ".github/workflows";

// **면제 불가** 항목 — 원장 편집만으로 강등할 수 없는 보안 경로. bump-poll의 인가 회수는 워크플로
// 주석 자신이 "회수는 가용성이 아니라 보안 속성"이라고 못박은 대상이라(R-27/R-31), 자격 회전 구간에
// 조용히 skip되면 무장된 PR의 낡은 머지 인가가 그대로 살아남는다. 원장에서 unconfigured/optional로
// 내리거나 severity를 warning으로 낮추면 이 상수가 red를 낸다(mutation으로 load-bearing 실측).
const SECURITY_CRITICAL: { workflow: string; job: string }[] = [
  { workflow: "bump-poll.yaml", job: "reconcile" },
];

const STATES = ["required", "unconfigured", "optional"];
const SEVERITIES = ["error", "warning"];
const SINCE_RE = /^\d{4}-\d{2}-\d{2}$/;

// 자격/설정 출처 — 이 표현식에서 온 env 변수만 준비상태 판정의 입력이 될 수 있다.
const CRED_EXPR = /\$\{\{\s*(?:secrets|vars)\./;

export type GateKind = "job" | "step";
type Step = { id?: unknown; run?: unknown; if?: unknown; env?: unknown };
type Job = { if?: unknown; needs?: unknown; steps?: unknown; outputs?: unknown; env?: unknown };
export type Workflow = { jobs?: Record<string, Job>; env?: unknown };

type JobDecl = {
  state?: unknown;
  severity?: unknown;
  why?: unknown;
  since?: unknown;
  owner_action?: unknown;
};
type WfDecl = { accounting_job?: unknown; expect_executed?: unknown; jobs?: Record<string, JobDecl> };
type Policy = { workflows?: Record<string, WfDecl> };

function steps(job: Job | undefined): Step[] {
  return Array.isArray(job?.steps) ? (job.steps as Step[]) : [];
}
function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function needsList(job: Job | undefined): string[] {
  const n = job?.needs;
  if (typeof n === "string") return [n];
  return Array.isArray(n) ? n.filter((x): x is string => typeof x === "string") : [];
}

// ── 탐지기 ────────────────────────────────────────────────────────────────────
// 준비상태 **플래그**를 먼저 찾고(생산), 그 플래그를 읽는 job을 게이트된 것으로 판정한다(소비).
// 생산자 job(preflight 자신)은 소비하지 않으므로 게이트 대상이 아니다 — 항상 돈다.
function envMap(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

// 자격 변수가 "비었는가"를 재는 형태. 레포 관용구는 `[ -n "$X" ]`지만 빈 문자열 비교도 같은 뜻이라
// 둘 다 받는다. ⚠️ 여전히 **프록시**다 — 다른 철자(`[ "${X:-}" = "" ]`의 변형·헬퍼 함수 경유)는 못 잡는다.
function testsEmptiness(run: string, v: string): boolean {
  return (
    new RegExp(`-[nz]\\s+"?\\$\\{?${v}\\b`).test(run) ||
    new RegExp(`\\$\\{?${v}(?![A-Za-z0-9_])\\}?"?\\s*(?:!=|==?)\\s*(?:""|'')`).test(run)
  );
}

export function readinessGates(doc: Workflow): Map<string, GateKind> {
  const jobs = doc?.jobs ?? {};
  const wfEnv = envMap(doc?.env);
  const flags = new Set<string>(); // `<job>.<step-id>.<key>`
  for (const [jobName, job] of Object.entries(jobs)) {
    // 자격 env는 **세 계층 어디에나** 선언될 수 있다(워크플로/job/스텝). 스텝만 보면 job-level env로
    // 같은 게이트를 쓴 워크플로가 조용히 탐지에서 빠진다(구조적 false negative — 실측으로 확인).
    const jobEnv = { ...wfEnv, ...envMap(job?.env) };
    for (const st of steps(job)) {
      const id = str(st?.id);
      const run = str(st?.run);
      if (!id || !run) continue;
      const env = { ...jobEnv, ...envMap(st?.env) };
      const cred = Object.entries(env).filter(([, v]) => CRED_EXPR.test(str(v))).map(([k]) => k);
      // 자격 변수의 공백 검사 — 결과 플래그와의 구분선(위 헤더 주석). 자격 env가 아예 없으면
      // `[].some(…)`이 false라 여기서 함께 걸린다(`if (!cred.length) continue`를 앞에 뒀었는데
      // mutation이 죽은 줄임을 드러냈다 — 지키는 것 없는 규칙은 남기지 않는다).
      if (!cred.some((v) => testsEmptiness(run, v))) continue;
      for (const m of run.matchAll(/["']?([A-Za-z0-9_-]+)=false["']?\s*>>\s*"?\$\{?GITHUB_OUTPUT/g)) {
        flags.add(`${jobName}.${id}.${m[1]}`);
      }
    }
  }
  // job-level 소비자는 **job 출력 이름**을 참조하는데(`needs.J.outputs.<job-output>`), 플래그는 **스텝
  // 출력 키**로 모였다. 둘은 job의 `outputs:` 블록이 자유롭게 매핑하는 **별개의 이름**이다. 예전엔
  // `<job>.<key>`로 축약해 두 이름이 같다고 가정했는데, 그러면 (a) `outputs: { ready: …outputs.configured }`
  // 처럼 이름만 바꾸면 게이트가 탐지에서 조용히 빠지고(원장 강제 탈출), (b) 같은 job의 서로 다른 두 스텝이
  // 같은 키를 쓰면 결과 플래그가 준비상태로 오탐된다. 그래서 매핑을 **실제로 해석한다**.
  const alias = new Map<string, Map<string, string | null>>(); // job → (job-output → `<step>.<key>` | null=해석불가)
  for (const [jobName, job] of Object.entries(jobs)) {
    const m = new Map<string, string | null>();
    for (const [name, expr] of Object.entries(envMap(job?.outputs))) {
      const hit = /^\s*\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}\s*$/.exec(str(expr));
      m.set(name, hit ? `${hit[1]}.${hit[2]}` : null);
    }
    alias.set(jobName, m);
  }

  const gates = new Map<string, GateKind>();
  for (const [jobName, job] of Object.entries(jobs)) {
    for (const m of str(job?.if).matchAll(/needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
      const target = alias.get(m[1])?.get(m[2]);
      if (target && flags.has(`${m[1]}.${target}`)) gates.set(jobName, "job");
    }
    // ⚠️ job-level 게이트가 있어도 스텝 게이트 스캔을 **멈추지 않는다**. 예전엔 여기서 `continue`했는데
    // 그 근거("job이 통째로 안 뜬다")는 바깥 게이트가 **실패할 때만** 참이다. 바깥이 통과하면 안쪽 자격
    // 부재가 바로 회계 대상인데, kind='job'으로 확정되면 정적은 `outputs.executed` 승격을 면제하고
    // 런타임은 result==='success'만 보고 '실행됨'으로 센다 — **G-09의 병이 이 가드 안에서 재현된다**
    // (적대 검토가 실측: 자격 A로 job-gate + 자격 B로 step-gate된 job이 스텝 0개 실행에도 초록).
    // 겹치면 **더 엄격한 step이 이긴다**(아래 set이 "job"을 덮어쓴다).
    for (const st of steps(job)) {
      for (const m of str(st?.if).matchAll(/steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
        if (flags.has(`${jobName}.${m[1]}.${m[2]}`)) gates.set(jobName, "step");
      }
    }
  }
  return gates;
}

// job의 `outputs:`에서 준비상태 게이트로 쓰이는데 출처를 정적으로 해석할 수 없는 매핑을 찾는다.
// ⚠️ **모든** 해석 불가 매핑을 red로 내면 안 된다 — `build.yaml`의 `sha: ${{ github.sha }}`처럼 준비상태와
// 무관한 승격까지 막아 무관한 이유로 gate가 빨개진다(적대 검토가 실측). 좁힌다: **자격 플래그를 내는
// job**의 출력이 다른 job의 게이트로 쓰이는데 그 출력의 출처를 못 읽을 때만.
export function unresolvedGateOutputs(doc: Workflow): string[] {
  const jobs = doc?.jobs ?? {};
  const producers = new Set<string>();
  for (const [jobName, job] of Object.entries(jobs)) {
    const wfEnv = envMap(doc?.env);
    const jobEnv = { ...wfEnv, ...envMap(job?.env) };
    for (const st of steps(job)) {
      const run = str(st?.run);
      if (!run) continue;
      const cred = Object.entries({ ...jobEnv, ...envMap(st?.env) })
        .filter(([, v]) => CRED_EXPR.test(str(v))).map(([k]) => k);
      if (cred.some((v) => testsEmptiness(run, v)) && /=false["']?\s*>>\s*"?\$\{?GITHUB_OUTPUT/.test(run)) {
        producers.add(jobName);
      }
    }
  }
  const bad: string[] = [];
  for (const [jobName, job] of Object.entries(jobs)) {
    for (const m of str(job?.if).matchAll(/needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
      if (!producers.has(m[1])) continue;
      const decl = envMap(jobs[m[1]]?.outputs);
      const expr = str(decl[m[2]]);
      if (!(m[2] in decl) || !/^\s*\$\{\{\s*steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+\s*\}\}\s*$/.test(expr)) {
        bad.push(`${jobName}.if → needs.${m[1]}.outputs.${m[2]}: 자격 플래그를 내는 job의 출력인데 출처를 정적으로 해석할 수 없다(단일 steps.<id>.outputs.<key> 표현식이 아니다)`);
      }
    }
  }
  return bad;
}

// job이 `outputs.executed`를 승격했는가 — 스텝-레벨 게이트의 유일한 관측 경로.
// ⚠️ **키 존재만 보면 안 된다.** 상수(`executed: "true"`)나 게이트 **밖** 스텝의 출력으로 승격하면
// 정적·런타임이 전부 초록인 채 회계가 아무것도 관측하지 못한다(적대 검토가 실측). 그래서
// (a) 단일 `${{ steps.<id>.outputs.<key> }}` 표현식이어야 하고 (b) 그 스텝이 **게이트 안쪽**이어야 한다
// = 그 스텝 자신이 준비상태 플래그를 읽는 `if:`를 갖거나, 그런 `if:`를 가진 스텝보다 뒤에 있어야 한다.
function declaresExecuted(job: Job | undefined, gatedStepIds: Set<string>): boolean {
  const expr = str(envMap(job?.outputs).executed);
  const hit = /^\s*\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+\s*\}\}\s*$/.exec(expr);
  return !!hit && gatedStepIds.has(hit[1]);
}

// 준비상태 플래그를 읽는 `if:`가 걸린 스텝의 id — 즉 "게이트 안쪽" 스텝들.
function gatedSteps(jobName: string, job: Job | undefined, flags: Set<string>): Set<string> {
  const out = new Set<string>();
  for (const st of steps(job)) {
    const id = str(st?.id);
    if (!id) continue;
    for (const m of str(st?.if).matchAll(/steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
      if (flags.has(`${jobName}.${m[1]}.${m[2]}`)) out.add(id);
    }
  }
  return out;
}

// 탐지기가 모은 플래그를 소비자(정적 검사)도 써야 하므로 함께 내보낸다.
export function readinessFlags(doc: Workflow): Set<string> {
  const jobs = doc?.jobs ?? {};
  const wfEnv = envMap(doc?.env);
  const flags = new Set<string>();
  for (const [jobName, job] of Object.entries(jobs)) {
    const jobEnv = { ...wfEnv, ...envMap(job?.env) };
    for (const st of steps(job)) {
      const id = str(st?.id);
      const run = str(st?.run);
      if (!id || !run) continue;
      const cred = Object.entries({ ...jobEnv, ...envMap(st?.env) })
        .filter(([, v]) => CRED_EXPR.test(str(v))).map(([k]) => k);
      if (!cred.some((v) => testsEmptiness(run, v))) continue;
      for (const m of run.matchAll(/["']?([A-Za-z0-9_-]+)=false["']?\s*>>\s*"?\$\{?GITHUB_OUTPUT/g)) {
        flags.add(`${jobName}.${id}.${m[1]}`);
      }
    }
  }
  return flags;
}

// ── 원장 ──────────────────────────────────────────────────────────────────────
// **필수 읽기**다. `existsSync ? … : {}` 폴백을 두면 원장이 사라졌을 때 "선언 0건 = 위반 0건"으로
// 조용히 통과한다 — 이 목록은 *차단 대상*이 아니라 *검사 계약*이라 부재가 곧 fail-open이다.
function loadPolicy(root: string): Policy {
  const raw = readFileSync(`${root}/${POLICY_PATH}`, "utf8");
  const p = JSON.parse(raw) as Policy;
  if (!p || typeof p !== "object" || !p.workflows || typeof p.workflows !== "object") {
    throw new Error(`${POLICY_PATH}: workflows 객체가 없다`);
  }
  return p;
}

function declaredJobs(wf: WfDecl | undefined): Record<string, JobDecl> {
  return wf?.jobs && typeof wf.jobs === "object" ? wf.jobs : {};
}

// ── 정적 검사 ─────────────────────────────────────────────────────────────────
function checkStatic(root: string, minWorkflows: number, minDeclarations: number): string[] {
  const bad: string[] = [];
  const policy = loadPolicy(root);
  const entries = walkManifests("workflows", root);
  if (entries.length < minWorkflows) {
    bad.push(`워크플로 열거 ${entries.length}건 < ${minWorkflows} — 열거 붕괴(이 회계가 vacuous해진다)`);
    return bad; // 열거가 무너지면 아래 대조는 전부 무의미하다.
  }

  const docs = new Map<string, Workflow>();
  for (const e of entries) {
    const name = e.path.slice(`${WORKFLOW_DIR}/`.length);
    try {
      docs.set(name, (parse(e.text) ?? {}) as Workflow);
    } catch (err) {
      bad.push(`${e.path}: YAML 파싱 실패 — ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  let declarations = 0;
  // 역방향 — 탐지된 준비상태 게이트는 **반드시** 원장에 있어야 한다(미선언 = 통과 불가).
  for (const [name, doc] of docs) {
    // 자격 플래그를 내는 job의 출력이 게이트로 쓰이는데 출처를 못 읽으면, 그 게이트는 탐지에서 빠져
    // 원장 강제를 통째로 우회한다(출력 이름만 바꾸면 되는 탈출구였다 — 적대 검토가 실측).
    for (const u of unresolvedGateOutputs(doc)) bad.push(`${WORKFLOW_DIR}/${name}: ${u}`);
    const decl = declaredJobs(policy.workflows?.[name]);
    for (const [job, kind] of readinessGates(doc)) {
      if (!decl[job]) {
        bad.push(
          `${WORKFLOW_DIR}/${name}: job '${job}' — 준비상태 게이트(${kind}-level)인데 ${POLICY_PATH}에 미선언 ` +
            `— required/unconfigured/optional 중 하나로 선언하라(선언되지 않은 미설정은 통과할 수 없다)`,
        );
      }
    }
  }

  // 정방향 — 원장의 항목은 실재하는 준비상태 게이트여야 한다(죽은 선언 = 아무도 대조하지 않는 주장).
  for (const [name, wf] of Object.entries(policy.workflows ?? {})) {
    const doc = docs.get(name);
    if (!doc) {
      bad.push(`${POLICY_PATH}: '${name}' 워크플로가 존재하지 않는다(리네임/삭제 후 원장 미갱신)`);
      continue;
    }
    const gates = readinessGates(doc);
    const flags = readinessFlags(doc);
    const decl = declaredJobs(wf);
    const jobs = doc.jobs ?? {};
    declarations += Object.keys(decl).length;
    if (!Object.keys(decl).length) {
      // 빈 항목은 "선언했다"는 인상만 남기고 아무것도 대조하지 않는다 — 원장이 아니라 장식이다.
      bad.push(`${POLICY_PATH}: '${name}' 항목의 jobs가 비었다(선언 0건 = 대조 0건)`);
      continue;
    }

    for (const [job, d] of Object.entries(decl)) {
      const state = str(d.state);
      if (!STATES.includes(state)) bad.push(`${name}.${job}: state='${state}' 미지원(허용: ${STATES.join("|")})`);
      if (!str(d.why).trim()) bad.push(`${name}.${job}: why가 비었다 — 판단 근거 없는 선언은 원장이 아니다`);
      if (!gates.has(job)) {
        bad.push(`${name}.${job}: 원장에 있으나 실제 준비상태 게이트가 아니다(게이트 제거 후 선언 잔존)`);
        continue;
      }
      if (state === "required") {
        if (!SEVERITIES.includes(str(d.severity))) {
          bad.push(`${name}.${job}: required는 severity가 필요하다(${SEVERITIES.join("|")})`);
        }
      } else if (d.severity !== undefined) {
        bad.push(`${name}.${job}: severity는 required 전용이다(state=${state}에 지정됨)`);
      }
      if (state === "unconfigured") {
        if (!SINCE_RE.test(str(d.since))) bad.push(`${name}.${job}: unconfigured는 since=YYYY-MM-DD가 필요하다`);
        if (!str(d.owner_action).trim()) bad.push(`${name}.${job}: unconfigured는 owner_action이 필요하다(갭을 닫는 방법)`);
      } else if (d.since !== undefined || d.owner_action !== undefined) {
        bad.push(`${name}.${job}: since/owner_action은 unconfigured 전용이다(state=${state}에 지정됨)`);
      }
      // 스텝-레벨 게이트는 job이 항상 success라 `outputs.executed` 승격 없이는 **원리적으로 관측 불가**다.
      if (gates.get(job) === "step" && state !== "optional" && !declaresExecuted(jobs[job], gatedSteps(job, jobs[job], flags))) {
        bad.push(
          `${WORKFLOW_DIR}/${name}: job '${job}' — 스텝-레벨 게이트라 job이 항상 success다. ` +
            `outputs.executed 승격 없이는 회계가 아무것도 못 잡는다`,
        );
      }
    }

    // 회계 job 계약 — required가 하나라도 있으면 게이트 **밖**의 회계 job이 있어야 한다.
    const required = Object.entries(decl).filter(([, d]) => str(d.state) === "required");
    const acct = str(wf.accounting_job);
    if (required.length === 0) {
      if (acct || wf.expect_executed !== undefined) {
        bad.push(`${name}: required 항목이 없는데 accounting_job/expect_executed가 선언됐다`);
      }
      continue;
    }
    if (wf.expect_executed !== required.length) {
      bad.push(`${name}: expect_executed=${String(wf.expect_executed)} != required 항목 수 ${required.length}(열거 바닥값 드리프트)`);
    }
    if (!acct) {
      bad.push(`${name}: required ${required.length}건인데 accounting_job 미선언`);
      continue;
    }
    const acctJob = jobs[acct];
    if (!acctJob) {
      bad.push(`${WORKFLOW_DIR}/${name}: accounting_job '${acct}' job이 워크플로에 없다`);
      continue;
    }
    if (gates.has(acct)) {
      bad.push(`${WORKFLOW_DIR}/${name}: 회계 job '${acct}' — 자기도 준비상태 게이트 안에 있다(감시자가 함께 skip된다)`);
    }
    // `if:`에 상태함수가 없으면 기본 success()가 걸려 **감시 대상이 skip되면 회계도 skip**된다.
    if (!/!\s*cancelled\(\)/.test(str(acctJob.if))) {
      bad.push(`${WORKFLOW_DIR}/${name}: 회계 job '${acct}'의 if에 !cancelled()가 없다(기본 success() 게이트에 함께 걸린다)`);
    }
    const needs = new Set(needsList(acctJob));
    for (const job of Object.keys(decl)) {
      if (!needs.has(job)) {
        bad.push(`${WORKFLOW_DIR}/${name}: 회계 job '${acct}'의 needs에서 '${job}' 누락(그 job의 결과를 볼 수 없다)`);
      }
    }
    // ⚠️ 호출 **문자열의 존재**만 보면 안 된다. 그 스텝이 `continue-on-error`거나 스텝-레벨 `if:`로
    // 게이트되거나 `|| true`로 끝나면 회계는 **조용히 무력화**된다 — 이 가드가 감시 대상 job에 대해
    // 못박은 병("조건부 skip은 success로 보인다")을 감시자 자신의 스텝에도 적용한다(적대 검토 실측).
    const invokeRe = new RegExp(`check-workflow-readiness\\.ts[^\\n]*--workflow\\s+${name.replace(/\./g, "\\.")}`);
    const invokers = steps(acctJob).filter((st) => invokeRe.test(str(st?.run)));
    if (!invokers.length) {
      bad.push(`${WORKFLOW_DIR}/${name}: 회계 job '${acct}' — check-workflow-readiness.ts --workflow ${name} 호출 없음`);
    }
    for (const st of invokers) {
      const run = str(st?.run);
      if ((st as { "continue-on-error"?: unknown })["continue-on-error"] === true) {
        bad.push(`${WORKFLOW_DIR}/${name}: 회계 호출 스텝이 continue-on-error다(비-0이 무시된다)`);
      }
      if (str(st?.if).trim()) {
        bad.push(`${WORKFLOW_DIR}/${name}: 회계 호출 스텝에 if가 걸려 있다(조건부 skip = 감시자 무력화)`);
      }
      if (/\|\|\s*(true|:)\s*$/m.test(run)) {
        bad.push(`${WORKFLOW_DIR}/${name}: 회계 호출이 '|| true'로 종료코드를 삼킨다`);
      }
    }
  }

  for (const { workflow, job } of SECURITY_CRITICAL) {
    // ⚠️ 예전엔 워크플로 파일이 없으면 `continue`했다. 그러면 **리네임 + 새 이름으로 optional 선언**
    // 두 편집만으로 면제 불가 통제가 통째로 사라진다(역방향 탐지는 '선언되어 있으므로' 만족된다 —
    // 적대 검토가 실측). 부재는 조용한 면제가 아니라 **원장 드리프트**다: 정말 폐기했다면 이 상수에서도
    // 함께 지워라(그 편집은 가드 소스에 남아 리뷰를 거친다).
    if (!docs.has(workflow)) {
      bad.push(
        `${POLICY_PATH}: 보안 핀 대상 ${WORKFLOW_DIR}/${workflow}가 없다 — 리네임/삭제라면 ` +
          `tools/check-workflow-readiness.ts의 SECURITY_CRITICAL도 함께 갱신하라(조용한 면제 금지)`,
      );
      continue;
    }
    const d = declaredJobs(policy.workflows?.[workflow])[job];
    if (!d) {
      bad.push(`${POLICY_PATH}: 보안 항목 ${workflow}.${job} 선언이 사라졌다(면제 불가 대상)`);
      continue;
    }
    if (str(d.state) !== "required" || str(d.severity) !== "error") {
      bad.push(
        `${POLICY_PATH}: 보안 항목 ${workflow}.${job}은 required+error 고정이다 ` +
          `(현재 state=${str(d.state)} severity=${str(d.severity)}) — 인가 회수는 가용성이 아니라 보안 속성이다`,
      );
    }
  }

  if (declarations < minDeclarations) {
    bad.push(`원장 선언 ${declarations}건 < ${minDeclarations} — 원장 붕괴(대조 대상이 사라졌다)`);
  }
  if (!bad.length) {
    console.log(`SCAN: check-workflow-readiness:workflows: ${entries.length}`);
    console.log(`SCAN: check-workflow-readiness:declarations: ${declarations}`);
  }
  return bad;
}

// ── 런타임 회계 ───────────────────────────────────────────────────────────────
type NeedsEntry = { result?: unknown; outputs?: Record<string, unknown> };

// 실행됐는가. **실패는 실행된 것으로 센다** — 이 회계가 잡는 것은 *조용한* 미실행이고, 실패는 이미
// run을 빨갛게 만든다. 실패를 여기서 또 미실행으로 세면 원인이 두 번 오귀속된다.
// ⚠️ 단, 그건 **job-level 게이트에만** 성립한다. 스텝-레벨 게이트 job이 게이트된 스텝에 **도달하기 전에**
// 죽으면(checkout 실패 등) 도메인을 평가한 적이 없는데도 '실행됨'이 되고, unconfigured 항목에서는
// stale(= "갭이 닫혔으니 required로 승격하라")라는 **정반대 처방**이 나간다(적대 검토가 실측).
// 그래서 스텝-레벨은 result와 무관하게 `outputs.executed`가 권위다.
export function wasExecuted(entry: NeedsEntry | undefined, kind: GateKind): boolean {
  if (!entry) return false;
  const result = str(entry.result);
  if (kind === "step") return str(entry.outputs?.executed) === "true";
  if (result === "failure") return true;
  return result === "success"; // skipped · cancelled = 미실행
}

// 판정 1건. `reason`을 남기는 이유는 아래 교차 대조 때문이다 — 위반을 문자열로만 모으면
// "required 몇 건이 안 돌았나"를 다시 셀 수 없어 두 번째 세기가 성립하지 않는다.
// `short`가 따로 있는 이유: `msg`에는 원장의 `why`/`owner_action` 전문이 들어가 한 건이 수백 자다.
// telegram은 4096자에서 잘리는데(notify.sh), 잘리면 **맨 뒤의 run 링크가 먼저 사라진다** — 알림을 받은
// 사람이 갈 곳을 잃는다. 그래서 알림 본문은 축약형, job summary·run 로그는 전문으로 나눈다.
export type Item = {
  job: string;
  level: "failure" | "warning" | "gap";
  reason: "not-executed" | "stale" | "absent";
  msg: string;
  short: string;
};

// 상류 job이 **실패해서** 하류가 skipped인 경우를 자격 부재와 갈라 적는다. 둘 다 `result=skipped`라
// 페이로드만으로는 구별되지 않는데, 원인이 정반대다(자격 미등록 vs preflight 크래시). 판정을 바꾸지는
// 않는다 — 미실행은 미실행이다 — 다만 메시지에 진짜 원인을 붙여 오귀속을 막는다.
function upstreamFailure(job: string, upstream: Map<string, string[]>, needs: Record<string, NeedsEntry>): string {
  const broken = (upstream.get(job) ?? []).filter((u) => {
    const r = str(needs[u]?.result);
    return r === "failure" || r === "cancelled";
  });
  return broken.length ? ` ⚠️ 원인은 자격 부재가 아니라 상류 job(${broken.join(", ")}) 실패다` : "";
}

export function accountRun(
  wf: WfDecl,
  gates: Map<string, GateKind>,
  needs: Record<string, NeedsEntry>,
  upstream: Map<string, string[]> = new Map(),
): Item[] {
  const items: Item[] = [];
  for (const [job, d] of Object.entries(declaredJobs(wf))) {
    const state = str(d.state);
    if (state === "optional") continue;
    if (!(job in needs)) {
      items.push({
        job,
        level: "failure",
        reason: "absent",
        msg: `'${job}' — 회계 job의 needs 페이로드에서 누락. 결과를 관측할 수 없다(needs 목록 드리프트)`,
        short: `${job}: needs 페이로드 누락(관측 불가)`,
      });
      continue;
    }
    const kind = gates.get(job) ?? "job";
    const ran = wasExecuted(needs[job], kind);
    if (state === "required") {
      if (ran) continue;
      items.push({
        job,
        level: str(d.severity) === "error" ? "failure" : "warning",
        reason: "not-executed",
        msg:
          `'${job}' 미실행(result=${str(needs[job]?.result) || "없음"}, ${kind}-level 게이트) — ${str(d.why)}` +
          upstreamFailure(job, upstream, needs),
        short:
          `${job}: 미실행(result=${str(needs[job]?.result) || "없음"}, ${kind}-level)` +
          upstreamFailure(job, upstream, needs),
      });
      continue;
    }
    // unconfigured — 안 도는 것이 **선언된 상태**다. 반대로 도는 순간 원장이 거짓이 되므로 그건 실패로
    // 낸다: 갭이 닫혔는데 원장이 따라오지 않으면 다음 사람이 "이건 원래 안 도는 거야"로 읽는다.
    if (!ran) {
      items.push({
        job,
        level: "gap",
        reason: "not-executed",
        msg: `'${job}' 미실행 — 선언된 갭(since ${str(d.since)}). ${str(d.owner_action)}`,
        short: `${job}: 미실행 — 원장에 선언된 갭(since ${str(d.since)})`,
      });
    } else {
      items.push({
        job,
        level: "failure",
        reason: "stale",
        msg:
          `'${job}' 실행됨 — 원장은 unconfigured다. 갭이 닫혔으니 ${POLICY_PATH}에서 ` +
          `state=required + severity를 지정하라(since ${str(d.since)} 선언이 낡았다)`,
        short: `${job}: 실행됨 — 원장은 unconfigured(갭이 닫혔다, 원장을 required로 승격하라)`,
      });
    }
  }
  return items;
}

function emit(name: string, value: string): void {
  const f = process.env[name];
  if (f) appendFileSync(f, value);
}

function runRuntime(root: string, name: string): string[] {
  const policy = loadPolicy(root);
  const wf = policy.workflows?.[name];
  if (!wf) return [`${POLICY_PATH}: '${name}' 선언이 없다 — 회계 대상이 아닌 워크플로가 회계를 부르고 있다`];
  const decl = declaredJobs(wf);
  if (!Object.keys(decl).length) return [`${POLICY_PATH}: '${name}'의 jobs가 비었다(원장 붕괴)`];

  const raw = process.env.WORKFLOW_NEEDS;
  if (!raw || !raw.trim()) return ["WORKFLOW_NEEDS 미설정 — 회계 job이 toJSON(needs)를 넘기지 않았다"];
  let needs: Record<string, NeedsEntry>;
  try {
    needs = JSON.parse(raw) as Record<string, NeedsEntry>;
  } catch (e) {
    return [`WORKFLOW_NEEDS 파싱 실패: ${e instanceof Error ? e.message : String(e)}`];
  }
  if (!needs || typeof needs !== "object" || Array.isArray(needs)) return ["WORKFLOW_NEEDS가 객체가 아니다"];

  const doc = parse(readFileSync(`${root}/${WORKFLOW_DIR}/${name}`, "utf8")) as Workflow;
  const gates = readinessGates(doc);
  const upstream = new Map(Object.entries(doc?.jobs ?? {}).map(([j, job]) => [j, needsList(job)]));
  const items = accountRun(wf, gates, needs, upstream);

  const required = Object.entries(decl).filter(([, d]) => str(d.state) === "required").map(([job]) => job);
  const ranCount = required.filter((job) => job in needs && wasExecuted(needs[job], gates.get(job) ?? "job")).length;
  // 정적 가드는 required 0건인 워크플로에 `expect_executed` 선언을 **금지**한다 — 그 형태를 런타임이
  // -1로 읽어 `-1 !== 0`으로 영구 실패시키면 정적이 강제하는 형태가 곧 런타임 고장이 된다(적대 검토 실측).
  // required가 있는데 선언이 없는 경우만 -1(=loud)로 남긴다.
  const expect = typeof wf.expect_executed === "number"
    ? wf.expect_executed
    : (required.length === 0 ? 0 : -1);
  const failures = items.filter((i) => i.level === "failure").map((i) => i.msg);
  const warnings = items.filter((i) => i.level === "warning").map((i) => i.msg);
  const gaps = items.filter((i) => i.level === "gap").map((i) => i.msg);

  // 열거 바닥값 — **사람이 적은 정수** vs **원장에서 센 수**. 이 회계에서 서로 독립인 유일한 두 값이라
  // (나머지 판정은 전부 같은 wasExecuted에서 파생된다) 여기서만 진짜 교차 대조가 성립한다.
  // 정적 가드도 같은 등식을 보지만 런타임에서도 본다: 원장만 고치고 정적 게이트를 우회하는 경로를 막는다.
  if (expect !== required.length) {
    failures.push(`expect_executed=${expect} != 원장의 required 항목 수 ${required.length}(바닥값 드리프트)`);
  }

  for (const m of failures) console.log(`::error::준비상태 회계(${name}): ${m}`);
  for (const m of warnings) console.log(`::warning::준비상태 회계(${name}): ${m}`);
  for (const m of gaps) console.log(`::warning::준비상태 갭(${name}, 원장 선언됨): ${m}`);
  console.log(`SCAN: check-workflow-readiness:accounted: ${Object.keys(decl).length}`);

  // 전문(job summary·run 로그) — 원장의 근거를 그대로 읽을 수 있어야 판단이 된다.
  const full = [
    ...failures.map((m) => `- ❌ ${m}`),
    ...warnings.map((m) => `- ⚠️ ${m}`),
    ...gaps.map((m) => `- 📋 ${m}`),
  ];
  emit("GITHUB_STEP_SUMMARY", `## 준비상태 회계 — ${name}\n\nrequired 실행 ${ranCount}/${expect}\n${full.join("\n") || "- ✅ 선언대로 전건 실행"}\n`);
  // gaps는 **telegram을 울리지 않는다** — 선언된 갭은 매 run 재발하므로 알림 트리거에 넣으면 30분마다
  // 스팸이 되고, 그 소음이 진짜 신호(failures·warnings)를 덮는다. 갭의 venue는 로그 + job summary + 원장이다.
  emit("GITHUB_OUTPUT", `failures=${failures.length}\nwarnings=${warnings.length}\ngaps=${gaps.length}\n`);
  // 알림 본문은 **축약형**이다(위 Item.short 주석 — 4096자 절단이 run 링크부터 먹는다).
  // 원장 텍스트가 heredoc 구분자를 포함하면 GITHUB_OUTPUT 파싱이 통째로 깨지므로 무해화한다
  // (원장은 사람이 편집한다 — "그럴 리 없다"를 파일 하나에 걸지 않는다).
  const EOF_MARK = "READINESS_EOF";
  const body = (
    [
      ...items.filter((i) => i.level === "failure").map((i) => `❌ ${i.short}`),
      ...items.filter((i) => i.level === "warning").map((i) => `⚠️ ${i.short}`),
      ...items.filter((i) => i.level === "gap").map((i) => `📋 ${i.short}`),
      ...(expect !== required.length ? [`❌ expect_executed=${expect} != required ${required.length}`] : []),
    ].join("\n") || "선언대로 전건 실행"
  ).split(EOF_MARK).join("READINESS-EOF");
  emit("GITHUB_OUTPUT", `body<<${EOF_MARK}\n${body}\n${EOF_MARK}\n`);

  if (!failures.length) {
    console.log(`check-workflow-readiness OK — ${name}: required ${ranCount}/${expect} 실행, 경고 ${warnings.length}건, 선언된 갭 ${gaps.length}건`);
  }
  return failures;
}

// ── CLI ───────────────────────────────────────────────────────────────────────
function positiveInt(raw: string | undefined, flag: string): number {
  // `Number("")===0`이라 빈 값이 바닥값을 조용히 끄는 자리다(같은 클래스의 실측 버그가 있었다).
  if (raw === undefined || raw.trim() === "" || !/^\d+$/.test(raw.trim())) {
    console.error(`${flag}는 음이 아닌 정수여야 한다(받은 값: '${raw ?? ""}')`);
    process.exit(2);
  }
  return Number(raw.trim());
}

if (import.meta.main) {
  let flags;
  try {
    flags = typedFlags(process.argv.slice(2), {
      value: ["--repo-root", "--workflow", "--min-workflows", "--min-declarations"],
      bool: [],
    });
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    console.error("사용법: check-workflow-readiness.ts [--repo-root <path>] [--workflow <file.yaml>] [--min-workflows <n>] [--min-declarations <n>]");
    process.exit(2);
  }
  const root = flags.str("--repo-root", ".")!;
  const workflow = flags.str("--workflow");

  let bad: string[];
  try {
    bad = workflow
      ? runRuntime(root, workflow)
      : checkStatic(
          root,
          positiveInt(flags.str("--min-workflows", "20"), "--min-workflows"),
          positiveInt(flags.str("--min-declarations", "8"), "--min-declarations"),
        );
  } catch (e) {
    console.error(`FAIL: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
  if (bad.length) {
    console.error("FAIL: 워크플로 준비상태 회계 위반:");
    for (const b of bad) console.error(`  ${b}`);
    process.exit(1);
  }
  if (!workflow) console.log("check-workflow-readiness OK (원장 ↔ 워크플로 양방향 정합)");
}
