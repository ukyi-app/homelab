// homelab olive test-job: 시험 클러스터의 올리브 감독에 배정 대기 시험 작업 한 줄을 넣는다(D-98·D-101).
// 감독 관리 통로(D-60)로 `bun src/main/admin.ts test-job …`을 kubectl exec한다. exec는 쓰기로 판정되므로 plan은 대상 파드와 argv만 보인다.
// 값은 꼴만 거르고 뜻(UUID, 역할, 해시)은 감독이 장부 규칙으로 본다. 감독은 OLIVE_TEST_JOBS=on일 때만 받고 운영 값은 꺼짐이라 disabled다.
// 감독의 답은 닫힌 목록의 낱말로만 받는다. 함정: 답을 받지 못한 경우는 장부에 적혔을 수 있어 "넣지 않았다"로 말하지 않는다.
import { defineCommand, type OliveAdminExit, type OliveSupervisorMissing, type OliveSupervisorTarget, type OliveTestJob, type OliveTestJobOutcome, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { OLIVE_TEST_JOB_VALUE, oliveTestJobFits } from "../core/names";
import { UsageError, type Result, type Status } from "../core/result";

type Outcome = { status: Status; label: string; headline: string; lines: string[]; next?: string | null };

// 다시 부르기 전에 볼 것: 답을 받지 못한 부탁이 대기 중이면 같은 키로 다시 불러도 limit이다(olive README "같은 키로 다시 부르기").
const CHECK_QUEUE = "같은 키로 다시 부르기 전에 homelab olive status --apply의 대기 수를 본다";

const REFUSED: Record<string, { why: string; next?: string }> = {
  malformed: { why: "값의 꼴이 감독 규칙에 맞지 않다", next: "값의 꼴(UUID 소문자, 키 문자, 해시 64자 등)을 고친 뒤 다시" },
  unknown_command: { why: "감독이 이 명령을 모른다(CLI와 감독 이미지의 판이 다를 수 있다)" },
  busy: { why: "감독의 관리 연결이 가득 찼다", next: "잠시 뒤 같은 명령을 다시 실행한다" },
  disabled: { why: "이 감독은 시험 작업 넣기가 꺼져 있다", next: "시험 클러스터의 감독에서만 쓴다(운영 값은 늘 꺼짐)" },
  not_alive: { why: "감독이 끝나는 중이다" },
  stopped: { why: "정지 중이다" },
  intake_closed: { why: "접수가 닫혀 있다" },
  owner_inactive: { why: "소유자 입력이 취소·만료됐다", next: "접수된 다른 입력을 소유자로 쓴다" },
  limit: { why: "배정될 수 있는 대기 한도에 닿았다", next: "homelab olive status --apply의 대기 수가 줄면 다시" },
  late: { why: "요청 기한이 지났다", next: "잠시 뒤 같은 명령을 다시 실행한다" },
  conflict: { why: "같은 키에 다른 내용의 부탁이 있다", next: "다른 키를 쓴다" },
  invariant_violation: { why: "장부가 거절했다(소유자가 접수된 입력이 아님 등)" },
  ledger_refused: { why: "장부가 거절했다" },
};

const MISSING_WORD: Record<OliveSupervisorMissing["state"], string> = {
  absent: "감독이 꺼져 있다(파드 없음)",
  "not-owned": "대조 실패(감독 Deployment의 파드로 확인되지 않아 실행하지 않는다)",
  "not-ready": "감독이 준비되지 않았다",
  terminating: "감독이 내려가는 중이다",
  multiple: "감독 파드가 여럿이라 고르지 않았다",
};

function missing(t: OliveSupervisorMissing): Outcome {
  const waiting = t.state === "not-ready" || t.state === "terminating" || t.state === "multiple";
  return waiting
    ? { status: "waiting", label: "감독 대기", headline: `시험 작업: 넣지 않았다. ${MISSING_WORD[t.state]}`, lines: [], next: "잠시 뒤 같은 명령을 다시 실행한다" }
    : { status: "failed", label: "감독 없음", headline: `시험 작업: 넣지 않았다. ${MISSING_WORD[t.state]}`, lines: [], next: "homelab olive status로 감독 파드를 확인한다" };
}

const notSure = (why: string, lines: string[]): Outcome => ({ status: "failed", label: "결과 모름", headline: `시험 작업: 결과 모름. ${why}. 장부에 적혔을 수 있다`, lines, next: CHECK_QUEUE });
const notWritten = (why: string, lines: string[], next?: string): Outcome => ({ status: "failed", label: "넣지 않음", headline: `시험 작업: 넣지 않았다. ${why}`, lines, next: next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" });

// 감독 진입점의 종료 코드를 CLI 공통 규칙(D-61: 0 완료, 1 실패, 3 대기, 64 사용법)으로 옮긴다.
// 3은 복원 전이라 장부를 읽지 않고 멈춘 것(적힌 것 없음)이라 대기다. 진입점의 64는 이 CLI가 만든 argv를 감독이 받지 않은 것이라
// 사람의 사용법 오류가 아니다(판 어긋남일 수 있다). 사유를 읽지 못한 1과 모르는 코드는 적혔을 수 있다.
function exited(r: OliveAdminExit, verbose: boolean): Outcome {
  const lines = verbose ? [`감독 파드 ${r.pod}`, `진입점 종료 코드 ${r.code}`, `사유 ${r.reason ? `${r.reason.kind} ${r.reason.word}` : "읽지 못함"}`] : [];
  if (r.code === 3) return { status: "waiting", label: "감독 복원 전", headline: `시험 작업: 넣지 않았다. 감독이 복원을 마치지 않았다(${r.reason?.word ?? "종료 코드 3"})`, lines, next: "감독이 복원을 마친 뒤 같은 명령을 다시 실행한다" };
  if (r.code === 64) return notWritten("감독 진입점이 요청을 받지 않았다(종료 코드 64, CLI와 감독 이미지의 판이 다를 수 있다)", lines);
  const reason = r.code === 1 ? r.reason : null;
  if (reason === null) return notSure(`감독 진입점이 종료 코드 ${r.code}로 끝났다`, lines);
  if (reason.kind === "refused") {
    const known = Object.hasOwn(REFUSED, reason.word) ? REFUSED[reason.word] : undefined;
    return { status: "failed", label: "거절", headline: `시험 작업 거절(${reason.word}): ${known?.why ?? "감독이 거절했다"}. 적힌 것 없음`, lines, next: known?.next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" };
  }
  if (reason.kind === "unreached") return notWritten(`감독에 닿지 못했다(${reason.word})`, lines, "homelab olive status --apply로 감독을 확인한다");
  if (reason.kind === "no-reply") return notSure(`감독의 답을 받지 못했다(${reason.word})`, lines);
  if (reason.word === "write_unknown") return notSure("장부에 적혔는지 모른다(write_unknown)", lines);
  return notWritten(`감독이 쓰기 전에 멈췄다(${reason.word})`, lines);
}

function planned(c: ReadCtx, job: OliveTestJob): Outcome {
  let t: OliveSupervisorTarget;
  try {
    t = c.oliveAdmin.target("test-job", job);
  } catch {
    return { status: "failed", label: "읽지 못함", headline: "시험 작업: 감독 파드를 읽지 못했다", lines: [], next: "kubectl 접속을 확인한 뒤 다시 실행한다" };
  }
  if (t.state !== "ready") return missing(t);
  return { status: "pending", label: "넣을 예정", headline: `시험 작업: --apply로 넣는다. 대상 파드 ${t.pod}`, lines: [`실행: ${t.argv.join(" ")}`] };
}

function applied(w: WriteCtx, job: OliveTestJob, verbose: boolean): Outcome {
  let r: OliveTestJobOutcome;
  try {
    r = w.oliveAdmin.testJob(job);
  } catch {
    return notWritten("감독 파드를 찾지 못했다(읽지 못함 또는 시간 초과)", [], "kubectl 접속을 확인한 뒤 다시 실행한다");
  }
  if (r.state === "no-target") return missing(r.target);
  if (r.state === "exit") return exited(r, verbose);
  const lines = verbose ? [`감독 파드 ${r.pod}`] : [];
  if (r.state === "unknown") return notSure("실행했지만 감독의 답을 확인하지 못했다", lines);
  const headline = r.outcome === "created" ? `시험 작업: 새로 넣음(참조 ${r.ref})` : `시험 작업: 같은 키·내용의 부탁이 이미 있다(참조 ${r.ref})`;
  return { status: "done", label: r.outcome === "created" ? "넣음" : "이미 있음", headline, lines, next: null };
}

// olive status와 같은 꼴의 한 단계: apply 뒤의 끝 상태는 엔진이 아니라 Outcome이 정한다(엔진의 단계 실패는 뒤를 끊고 waiting은 plan에서 나오지 않는다).
async function runTestJob(ctx: ReadCtx, job: OliveTestJob, verbose: boolean): Promise<Result> {
  let done = null as Outcome | null;
  let plan = null as Outcome | null;
  const step: Step = {
    id: "olive-test-job",
    target: "올리브 시험 작업",
    async read(c) {
      if (done) return { state: "same", action: "none", detail: done.label };
      if (c.mode === "apply") return { state: "differs", action: "update", detail: "실행" };
      plan = planned(c, job);
      return { state: "differs", action: "update", detail: plan.label };
    },
    async apply(w) {
      done = applied(w, job, verbose);
    },
  };
  const r = await ctx.engine({ command: "olive test-job", steps: [step] });
  const o: Outcome | null = done ?? plan;
  if (o === null || r.status === "failed") return r;
  const steps = r.steps.map((s) => ({ ...s, detail: o.label, result: o.status === "failed" ? ("failed" as const) : o.status === "waiting" ? ("waiting" as const) : s.result }));
  const next = o.next === undefined ? r.next : o.next;
  const result: Result = { ...r, status: o.status, steps, body: [o.headline, ...o.lines].join("\n"), next };
  if (o.status === "failed") result.error = { message: o.headline, next: next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" };
  return result;
}

export function makeOliveTestJob() {
  return defineCommand({
    path: ["olive", "test-job"],
    summary: "올리브 시험 작업 넣기(시험 클러스터)",
    help: {
      about:
        "시험 클러스터의 올리브 감독에 배정 대기 시험 작업 한 줄을 넣습니다. 감독이 시험 작업 넣기를 켠 때만 받고, 운영 클러스터의 감독은 꺼진 설정이라 늘 거절(disabled)합니다. 계획은 대상 파드와 실행할 명령만 보이고, --apply에서 감독 파드에 kubectl exec합니다. 예의 대문자 자리는 실제 값으로 바꿉니다. 값은 꼴(빈 값·공백·제어 문자·길이)만 보고 뜻은 감독이 봅니다. 종료 코드는 0 넣음·이미 있음, 1 거절·실패·결과 모름, 3 대기(감독이 복원 전·준비 전), 64 사용법입니다. 결과 모름이면 장부에 적혔을 수 있으니 같은 키로 다시 부르기 전에 status --apply의 대기 수를 봅니다.",
      // 실제 값(UUID·64자 해시)은 80칸 한 줄에 들지 않아 대문자 자리로 적는다.
      examples: ["homelab olive test-job OWNER-ID retry-1 reader smoke_check SOURCE-REF DIGEST"],
      related: ["olive"],
    },
    // --apply에서 감독 파드에 exec해서(쓰기로 판정) --apply를 받아야 한다.
    kind: "change",
    args: [
      { name: "owner", required: true, help: "소유자 입력의 요청 ID(접수된 입력)", pattern: OLIVE_TEST_JOB_VALUE },
      { name: "key", required: true, help: "재시도 키", pattern: OLIVE_TEST_JOB_VALUE },
      { name: "role", required: true, help: "역할 이름", pattern: OLIVE_TEST_JOB_VALUE },
      { name: "purpose", required: true, help: "목적 분류 코드", pattern: OLIVE_TEST_JOB_VALUE },
      { name: "sourceRef", required: true, help: "원본 참조(종류/UUID)", pattern: OLIVE_TEST_JOB_VALUE },
      { name: "inputDigest", required: true, help: "입력 SHA-256(소문자 hex 64자)", pattern: OLIVE_TEST_JOB_VALUE },
    ],
    flags: [{ name: "verbose", kind: "bool", help: "감독 파드·종료 코드·사유까지 보기" }],
    async run(ctx, input) {
      const a = input.args;
      const job: OliveTestJob = { owner: a.owner as string, key: a.key as string, role: a.role as string, purpose: a.purpose as string, sourceRef: a.sourceRef as string, inputDigest: a.inputDigest as string };
      if (!oliveTestJobFits([job.owner, job.key, job.role, job.purpose, job.sourceRef, job.inputDigest])) throw new UsageError("값 여섯이 감독이 받는 요청 한 줄(1,024바이트)을 넘는다");
      return runTestJob(ctx, job, input.flags.verbose === true);
    },
  });
}

export default makeOliveTestJob();
