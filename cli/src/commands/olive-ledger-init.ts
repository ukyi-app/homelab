// homelab olive ledger-init: 감독을 처음 켜기 전에 빈 장부를 한 번 만든다(D-110·D-176).
// 계획은 읽기만 해서 대상·확인·만들 Job을 보이고, --apply에서 확인을 다시 읽어 모두 맞을 때만 Argo CD 밖의 일회성 Job을 띄운다.
// 판정은 초기화 진입점의 종료 코드로 한다: 0 만듦·90 이미 있음(바꾸지 않음)은 성공, 그 밖은 실패, 종료 코드를 확인하지 못하면 결과 모름.
// 함정: 결과 모름은 장부가 만들어졌을 수 있다. 다시 불러 보면 된다(있으면 90으로 끝나고 바꾸지 않는다). 94는 자동으로 다시 돌리지 않는다.
import { defineCommand, type OliveLedgerCheck, type OliveLedgerCleanup, type OliveLedgerInspection, type OliveLedgerJob, type OliveLedgerOutcome, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import type { Result, Status } from "../core/result";

type Outcome = { status: Status; label: string; headline: string; lines: string[]; next?: string | null };
type Word = { line: string; waiting?: boolean; next: string };

const AGAIN = "homelab olive ledger-init";
const CHECK_AGAIN = `다시 불러 확인한다: ${AGAIN} --apply(장부가 있으면 90으로 끝나고 바꾸지 않는다)`;

const OK_WORD: Record<OliveLedgerCheck["id"], string> = {
  deployment: "감독 Deployment 있음",
  replicas: "감독 replicas 0",
  rollout: "감독 Deployment가 replicas 0을 반영함",
  "supervisor-pods": "감독 파드 0개(내려가는 중 포함)",
  shape: "감독 Deployment에서 Job 모양을 읽음",
  "ledger-users": "장부 PVC를 붙인 다른 파드 없음",
  pvc: "장부 PVC 있음",
  "stop-lock": "정지 자물쇠 없음",
  leftover: "지난 초기화 Job·파드 없음",
  quota: "olive-limits 사용량 0, 집행 중인 한도 = 감독 limits, 적용 범위 없음",
};

// 정지 자물쇠(파드 0개 쿼터)가 걸려 있으면 거절한다. 만들어도 쿼터가 파드를 막아 기한까지 기다린 뒤 결과 모름이 되고,
// 비상 정지를 풀지는 그 절차(정지 원인 확인, 실행 파드 0개)로 사람이 정할 일이라 이 명령이 풀거나 비켜 가지 않는다.
const LOCK_NEXT = `정지를 건 까닭이 풀렸는지 확인하고 정지 절차대로 자물쇠를 푼 뒤 다시: ${AGAIN}`;
const LEFTOVER_NEXT = `지난 초기화의 결과를 확인하고 Job을 지운 뒤 다시: ${AGAIN}(끝난 Job은 끝난 뒤 600초면 스스로 지워진다)`;
// Job 없이 남은 초기화 파드(손으로 띄운 본보기 등)에는 ttl이 없어 기다려도 풀리지 않는다.
const POD_LEFTOVER_NEXT = `지난 초기화 파드의 결과(종료 코드)를 확인하고 그 파드를 지운 뒤 다시: ${AGAIN}(Job 없이 남은 파드는 스스로 지워지지 않는다)`;
const LATER = `잠시 뒤 다시: ${AGAIN}`;
const SHAPE_NEXT = "CLI와 차트의 판을 맞춘다(CLI를 다시 설치하거나 감독 Deployment를 확인한다)";

function failWord(c: OliveLedgerCheck & { ok: false }): Word {
  const d = c.detail;
  switch (c.id) {
    case "deployment":
      return { line: "감독 Deployment가 없다", next: "올리브 차트를 먼저 적용한다(감독 replicas 0인 채)" };
    case "replicas":
      return { line: `감독 replicas가 ${d}이다`, next: `감독을 끄고(replicas 0) 파드가 사라진 뒤 다시: ${AGAIN}` };
    case "rollout":
      return { line: d === "unobserved" ? "감독 Deployment가 replicas 0을 아직 반영하지 않았다" : `감독 파드 ${d}개가 아직 Deployment에 남아 있다`, waiting: true, next: LATER };
    case "supervisor-pods":
      return d === "selector" ? { line: "감독 Deployment의 파드 선택자를 읽지 못했다", next: SHAPE_NEXT } : { line: `감독 파드가 ${d}개 남아 있다(내려가는 중 포함)`, waiting: true, next: `감독 파드가 사라진 뒤 다시: ${AGAIN}` };
    case "shape":
      if (d === "zero-limits") return { line: "감독 limits에 0인 자원이 있다(초기화는 CPU와 메모리 둘 다 양수 한도를 요구한다)", next: "올리브 차트의 감독 resources.limits를 확인한다(cpu·memory 모두 0보다 커야 한다)" };
      return { line: `감독 Deployment의 꼴이 예상과 다르다(${d})`, next: SHAPE_NEXT };
    case "ledger-users":
      return { line: `장부 PVC를 붙인 다른 파드가 ${d}개 있다`, next: `그 파드가 끝난 뒤 다시: ${AGAIN}` };
    case "pvc":
      return { line: d === "deleting" ? "장부 PVC가 지워지는 중이다" : "장부 PVC가 없다", next: "올리브 차트의 장부 PVC를 확인한다" };
    case "stop-lock":
      if (d === "deleting") return { line: "정지 자물쇠(olive-stop)가 지워지는 중이다", waiting: true, next: LATER };
      if (d === "different") return { line: "정지 자물쇠 자리(olive-stop)에 다른 모양의 쿼터가 있다", next: "그 쿼터가 무엇인지 확인한다(이 명령은 지우지 않는다)" };
      return { line: "정지 자물쇠(olive-stop)가 걸려 있어 초기화 파드도 뜰 수 없다", next: LOCK_NEXT };
    case "leftover":
      return d === "job" ? { line: "지난 초기화 Job(olive-ledger-init)이 남아 있다", next: LEFTOVER_NEXT } : { line: `지난 초기화 파드가 남아 있다(${d.replace("pods ", "")}개)`, next: POD_LEFTOVER_NEXT };
    case "quota":
      if (d === "absent") return { line: "olive-limits 쿼터가 없다(감독과 함께 뜨는 것을 막지 못한다)", next: "올리브 차트의 olive-limits를 확인한다" };
      if (d === "unchecked") return { line: "olive-limits 한도를 감독 limits와 비교하지 못했다(감독 limits를 읽지 못했다)", next: SHAPE_NEXT };
      if (d === "mismatch") return { line: "olive-limits 한도가 감독 limits와 다르다(감독과 함께 뜨는 것을 막지 못한다)", next: "올리브 차트의 olive-limits와 감독 resources를 확인한다" };
      if (d === "deleting") return { line: "olive-limits 쿼터가 지워지는 중이다(감독과 함께 뜨는 것을 막지 못한다)", next: "올리브 차트의 olive-limits를 확인한다" };
      if (d === "scoped") return { line: "olive-limits에 적용 범위(scopes·scopeSelector)가 있다(차트와 다르다)", next: "올리브 차트의 olive-limits를 확인한다(이 명령은 고치지 않는다)" };
      if (d === "enforcing") return { line: "olive-limits가 집행 중인 한도(status.hard)가 아직 감독 limits와 같지 않다", waiting: true, next: LATER };
      return { line: d === "unread" ? "olive-limits 사용량을 아직 계산하지 않았다" : "olive-limits 사용량이 0이 아니다", waiting: true, next: LATER };
  }
}

// 문맥 이름은 kubectl에 넘긴 그대로가 아니라 화면용으로 보인다. 규칙 하나로 서로 다른 이름이 같은 줄로 보이지 않게 한다:
// 따옴표·역슬래시·공백·보이지 않는 글자가 하나라도 있으면 따옴표로 감싸고, 그 안의 따옴표·역슬래시는 역슬래시를 붙이고
// 보이지 않는 글자(글자·숫자·기호·문장 부호가 아닌 것과 U+034F·U+200B 같은 무시 가능 글자)는 \u{…}로 적는다. 감싸지 않은 이름에는
// 따옴표가 없어 감싼 이름과 겹치지 않는다.
const ESCAPED = /[^\p{L}\p{M}\p{N}\p{P}\p{S} ]|\p{Default_Ignorable_Code_Point}/u;
function shownContext(name: string): string {
  const chars = [...name];
  if (chars.every((ch) => ch !== '"' && ch !== "\\" && ch !== " " && !ESCAPED.test(ch))) return name;
  const body = chars.map((ch) => (ch === '"' || ch === "\\" ? `\\${ch}` : ESCAPED.test(ch) ? `\\u{${(ch.codePointAt(0) as number).toString(16)}}` : ch)).join("");
  return `"${body}"`;
}

const target = (i: OliveLedgerInspection) => `대상: 문맥 ${i.context === null ? "모름" : shownContext(i.context)}, ${i.namespace}/${i.deployment}`;
const jobLine = (j: OliveLedgerJob) => `Job: 이미지 ${j.image}, 장부 ${j.ledgerDir}(PVC ${j.pvc}), limits ${j.limits.cpu}·${j.limits.memory}`;
const jobDetail = (j: OliveLedgerJob) => `Job ${j.namespace}/${j.name}, 기한 ${j.deadlineSec}초, 끝난 뒤 ${j.ttlSec}초면 스스로 지워짐`;
const checkLines = (i: OliveLedgerInspection) => i.checks.map((c) => (c.ok ? `확인: ${OK_WORD[c.id]}` : `어긋남: ${failWord(c).line}`));

// 어긋난 확인이 하나라도 있으면 만들지 않는다. 모두 잠시 뒤 풀리는 것(감독이 내려가는 중 등)이면 대기(3), 아니면 실패(1)다.
function blocked(i: OliveLedgerInspection, verbose: boolean, planned: boolean): Outcome | null {
  if (i.context === null) {
    return { status: "failed", label: "확인 어긋남", headline: `장부 초기화: ${planned ? "만들 수 없다" : "Job을 만들지 않았다"}. kubectl 문맥을 정하지 못했다`, lines: [], next: `kubectl config current-context가 대상 클러스터의 문맥을 내는지 확인한 뒤 다시: ${AGAIN}` };
  }
  const bad = i.checks.filter((c): c is OliveLedgerCheck & { ok: false } => !c.ok).map(failWord);
  if (bad.length === 0 && i.job !== null) return null;
  const first = bad[0] ?? { line: "Job 모양을 만들지 못했다", next: SHAPE_NEXT };
  const lines = verbose ? [target(i), ...checkLines(i)] : [target(i), ...bad.slice(1).map((w) => `어긋남: ${w.line}`)];
  const waiting = bad.length > 0 && bad.every((w) => w.waiting === true);
  const headline = `장부 초기화: ${planned ? "만들 수 없다" : "Job을 만들지 않았다"}. ${first.line}`;
  return { status: waiting ? "waiting" : "failed", label: waiting ? "대기" : "확인 어긋남", headline, lines, next: first.next };
}

function planned(c: ReadCtx, verbose: boolean): Outcome {
  let i: OliveLedgerInspection;
  try {
    i = c.oliveLedger.inspect();
  } catch {
    return { status: "failed", label: "읽지 못함", headline: "장부 초기화: 클러스터를 읽지 못했다", lines: [], next: `kubectl 접속을 확인한 뒤 다시: ${AGAIN}` };
  }
  const stop = blocked(i, verbose, true);
  if (stop) return stop;
  const job = i.job as OliveLedgerJob;
  const lines = [target(i), ...(verbose ? checkLines(i) : [`확인: ${i.checks.length}개 모두 맞음`]), jobLine(job), ...(verbose ? [jobDetail(job)] : [])];
  return { status: "pending", label: "만들 예정", headline: "장부 초기화: --apply로 일회성 Job을 띄워 장부를 만든다", lines };
}

const UNKNOWN_WHY: Record<string, string> = {
  "create-timeout": "Job을 만들었는지 모른다(시간 초과)",
  "create-unread": "만든 Job의 응답을 읽지 못했다",
  "create-lost": "Job을 만들었는지 모른다(만들기 응답을 받지 못했다)",
  "not-owned": "종료 코드를 낸 파드가 만든 Job의 것인지 확인하지 못했다",
  deadline: "초기화 파드가 기한 안에 끝나지 않았다",
  wait: "기다림 상한 안에 Job이 끝나지 않았다",
  gone: "기다리는 도중 Job이 사라졌다",
  pods: "초기화 파드를 하나로 찾지 못했다",
  "no-exit": "초기화 파드의 종료 코드를 읽지 못했다",
  mismatch: "Job 상태와 종료 코드가 맞지 않는다",
  unread: "Job 상태를 읽지 못했다",
  "complete-unread": "Job 완료는 확인했으나 초기화 파드의 종료 코드를 읽지 못했다",
  "failed-unread": "Job 실패는 확인했으나 초기화 파드의 종료 코드를 읽지 못했다",
};

// 지우지 못한 Job은 다음 실행을 막으므로(지난 초기화 Job이 남아 있음) 기본 출력에도 한 줄 남긴다.
function cleanupLine(c: OliveLedgerCleanup, j: OliveLedgerJob): string | null {
  if (c.state === "deleted") return null;
  if (c.state === "kept" && c.why === "exit-unread") return `Job ${j.name}을 지우지 않았다(끝났으나 종료 코드를 읽지 못했다. 파드의 종료 코드를 확인할 수 있게 남겼다). 끝난 뒤 ${j.ttlSec}초면 스스로 지워진다`;
  if (c.state === "kept" && c.why === "unread") return `Job ${j.name}을 지우지 않았다(상태를 읽지 못했다). 끝난 뒤 ${j.ttlSec}초면 스스로 지워진다`;
  if (c.state === "kept") return c.why === "running" ? `Job ${j.name}을 지우지 않았다(아직 끝나지 않았다). 기한 ${j.deadlineSec}초에 끝나고, 끝난 뒤 ${j.ttlSec}초면 스스로 지워진다` : `Job ${j.name}을 지우지 않았다(만들었는지 모른다). 있으면 끝난 뒤 ${j.ttlSec}초면 스스로 지워진다`;
  return `Job ${j.name}을 지우지 못했다(${c.why}). 끝난 뒤 ${j.ttlSec}초면 스스로 지워진다`;
}

// 진입점 종료 코드(olive ledger-init: 0 만듦, 64 사용법, 90 이미 있음, 91 환경, 94 그 밖)를 CLI 공통 규칙(D-61)으로 옮긴다.
// 64·91은 장부를 열기 전에 멈춘 것이다. 모르는 코드는 만들어졌을 수 있다. 94는 사유마다 장부가 생겼는지가 다르다:
// close:threw는 장부를 만든 뒤 닫기만 실패한 것이다(진입점의 명시 계약). "만들지 못했다"는 첫 설치 기록을 커밋하기 전에만 나는
// 판정 사유(BEFORE_WRITE)에만 쓴다. 나머지 열기 사유는 커밋 뒤의 WAL 전환·장부 객체 생성에서 난 SQLite 오류도 같은 이름으로
// 분류되어(olive src/ledger/ledger.ts openLedger, src/ledger/errors.ts classify) 시점을 가릴 수 없고, 사유를 읽지 못한 94도 그렇다.
// 어느 쪽이든 CLI는 1이고 자동으로 다시 돌리지 않는다.
const BEFORE_WRITE = new Set(["deps:threw", "open:too_new", "open:migration_mismatch", "open:migration_failed", "open:not_initialized", "open:foreign_data", "open:interrupted_install"]);
const FIX_THEN = "자동으로 다시 돌리지 않았다. 사유를 보고 장부 자리를 바로잡은 뒤";

function failedLine(code: number, reason: string | null, kubelet: string | null): { line: string; maybe: boolean; next: string } {
  if (code === 64) return { line: "초기화 진입점이 실행을 받지 않았다(종료 64, CLI와 감독 이미지의 판이 다를 수 있다)", maybe: false, next: SHAPE_NEXT };
  if (code === 91) return { line: `초기화 진입점이 장부 경로 환경을 받지 못했다(종료 91${reason ? `, ${reason}` : ""})`, maybe: false, next: "감독 Deployment의 OLIVE_LEDGER_DIR을 확인한다" };
  if (code === 94 && reason === "close:threw") return { line: "장부는 만들었고 닫기가 실패했다(종료 94, close:threw)", maybe: false, next: `자동으로 다시 돌리지 않았다. ${CHECK_AGAIN}` };
  if (code === 94 && reason !== null && BEFORE_WRITE.has(reason)) return { line: `장부를 만들지 못했다(종료 94, ${reason})`, maybe: false, next: `${FIX_THEN} 다시: ${AGAIN}(0바이트 장부 파일만 남았으면 olive README의 장부 초기화 절을 본다)` };
  if (code === 94 && reason !== null && reason.startsWith("open:")) return { line: `장부 열기가 실패했다(종료 94, ${reason})`, maybe: true, next: `${FIX_THEN} ${CHECK_AGAIN}` };
  if (code === 94) return { line: `초기화 진입점이 종료 94로 끝났다(${reason ?? "사유를 읽지 못함"})`, maybe: true, next: `${FIX_THEN} ${CHECK_AGAIN}` };
  return { line: `초기화 파드가 종료 ${code}로 끝났다(${kubelet ?? "사유를 읽지 못함"})`, maybe: true, next: CHECK_AGAIN };
}

function applied(w: WriteCtx, verbose: boolean): Outcome {
  let r: OliveLedgerOutcome;
  try {
    r = w.oliveLedger.run();
  } catch {
    return { status: "failed", label: "읽지 못함", headline: "장부 초기화: Job을 만들지 않았다. 클러스터를 읽지 못했다", lines: [], next: `kubectl 접속을 확인한 뒤 다시: ${AGAIN}` };
  }
  if (r.state === "blocked") return blocked(r.inspection, verbose, false) ?? { status: "failed", label: "확인 어긋남", headline: "장부 초기화: Job을 만들지 않았다", lines: [], next: SHAPE_NEXT };
  const j = r.job;
  if (r.state === "not-created") {
    const why = r.why === "exists" ? "같은 이름의 Job이 먼저 생겼다" : r.why === "forbidden" || r.why === "refused" ? "API 서버가 거절했다" : r.why === "not-run" ? "kubectl을 띄우지 못했다" : `kubectl ${r.why}`;
    return { status: "failed", label: "만들지 못함", headline: `장부 초기화: Job을 만들지 못했다(${why}). 아무것도 돌지 않았다`, lines: verbose ? [jobLine(j)] : [], next: r.why === "exists" ? LEFTOVER_NEXT : `원인을 고친 뒤 다시: ${AGAIN}` };
  }
  const tail = [cleanupLine(r.cleanup, j)].filter((l): l is string => l !== null);
  const more = verbose ? [jobLine(j), jobDetail(j), r.cleanup.state === "deleted" ? "Job을 지웠다" : null].filter((l): l is string => l !== null) : [];
  if (r.state === "created" || r.state === "exists") {
    const headline = r.state === "created" ? "장부 초기화: 장부를 만들었다" : "장부 초기화: 장부가 이미 있다(바꾸지 않았다)";
    return { status: "done", label: r.state === "created" ? "만듦" : "이미 있음", headline, lines: [...tail, ...more, ...(verbose ? [`파드 종료 코드 ${r.state === "created" ? 0 : 90}`] : [])], next: null };
  }
  if (r.state === "failed") {
    const f = failedLine(r.code, r.reason, r.kubelet);
    const lines = [...tail, ...more, ...(verbose ? [`파드 종료 코드 ${r.code}`, `사유 ${r.reason ?? r.kubelet ?? "읽지 못함"}`] : [])];
    return { status: "failed", label: "실패", headline: `장부 초기화 실패: ${f.line}${f.maybe ? ". 장부가 만들어졌을 수 있다" : ""}`, lines, next: f.next };
  }
  const why = UNKNOWN_WHY[r.why] ?? "종료 코드를 확인하지 못했다";
  const waited = r.waiting ? [`마지막 파드 대기 사유 ${r.waiting}`] : [];
  const next = r.cleanup.state === "deleted" ? CHECK_AGAIN : `Job이 끝나고 지워진 뒤 ${CHECK_AGAIN}`;
  return { status: "failed", label: "결과 모름", headline: `장부 초기화: 결과 모름. ${why}. 장부가 만들어졌을 수 있다`, lines: [...tail, ...waited, ...more], next };
}

// olive test-job과 같은 꼴의 한 단계: apply 뒤의 끝 상태는 엔진이 아니라 Outcome이 정한다(엔진의 단계 실패는 뒤를 끊고 waiting은 plan에서 나오지 않는다).
async function runLedgerInit(ctx: ReadCtx, verbose: boolean): Promise<Result> {
  let done = null as Outcome | null;
  let plan = null as Outcome | null;
  const step: Step = {
    id: "olive-ledger-init",
    target: "올리브 장부 초기화",
    async read(c) {
      if (done) return { state: "same", action: "none", detail: done.label };
      if (c.mode === "apply") return { state: "differs", action: "create", detail: "실행" };
      plan = planned(c, verbose);
      return { state: "differs", action: "create", detail: plan.label };
    },
    async apply(w) {
      done = applied(w, verbose);
    },
  };
  const r = await ctx.engine({ command: "olive ledger-init", steps: [step] });
  const o: Outcome | null = done ?? plan;
  if (o === null || r.status === "failed") return r;
  const steps = r.steps.map((s) => ({ ...s, detail: o.label, result: o.status === "failed" ? ("failed" as const) : o.status === "waiting" ? ("waiting" as const) : s.result }));
  const next = o.next === undefined ? r.next : o.next;
  const result: Result = { ...r, status: o.status, steps, body: [o.headline, ...o.lines].join("\n"), next };
  if (o.status === "failed") result.error = { message: o.headline, next: next ?? `원인을 고친 뒤 다시: ${AGAIN}` };
  return result;
}

export function makeOliveLedgerInit() {
  return defineCommand({
    path: ["olive", "ledger-init"],
    summary: "올리브 감독 장부 처음 만들기",
    help: {
      about:
        "감독을 처음 켜기 전에 빈 장부를 한 번 만듭니다. 계획은 클러스터를 읽기만 해서 대상, 확인 결과, 띄울 Job(이미지, 장부 경로, PVC, 자원 한도)을 보입니다. 계획과 --apply 모두 시작에 kubectl 문맥을 한 번 정해 모든 호출에 같은 문맥을 씁니다. --apply는 확인을 다시 읽어 감독 replicas와 파드가 0이고 정지 자물쇠가 없으며 지난 초기화가 남지 않았을 때만 감독과 같은 이미지·보안 설정의 일회성 Job을 띄우고, 끝날 때까지(기한 5분) 기다려 판정한 뒤 Job을 지웁니다. 정지 자물쇠가 걸려 있으면 풀지 않고 거절합니다. 종료 코드는 0 장부를 만듦·이미 있음(바꾸지 않음), 1 확인 어긋남·실패·결과 모름, 3 대기(감독이 내려가는 중 등), 64 사용법입니다. 결과 모름이면 장부가 만들어졌을 수 있으니 다시 불러 확인합니다(있으면 바꾸지 않고 끝납니다).",
      examples: ["homelab olive ledger-init", "homelab olive ledger-init --verbose"],
      related: ["olive"],
    },
    // --apply에서 Job을 만들고 지운다.
    kind: "change",
    args: [],
    flags: [{ name: "verbose", kind: "bool", help: "확인마다의 줄과 Job 자세히 보기" }],
    async run(ctx, input) {
      return runLedgerInit(ctx, input.flags.verbose === true);
    },
  });
}

export default makeOliveLedgerInit();
