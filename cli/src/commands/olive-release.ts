// homelab olive release: 올리브 감독 장부에서 작업 자리를 쥔 채 스스로 풀리지 않는 실행을 관리자가 푼다(D-149 ④, D-156).
// 감독 관리 통로(D-60)로 holds를 읽어 실행마다 다음 행동과 절차를 보이고, 실행 ID와 확인 플래그를 받으면 holds를 다시 읽어 앞 상태에 맞는
// 쓰기 하나만 부른다(close-unconfirmed·abandon-result·close-store-reset·release-hold). exec는 쓰기로 판정되므로 plan은 대상 파드와 argv만 보인다.
// 파드 근거(이름·뜬 시각)는 쿠버네티스에서 그 실행기 Deployment의 파드를 소유 사슬로 확인해 읽고 사람이 넣지 않는다(D-97).
// 함정: 쓰기 전에 다시 읽는 것은 이 명령이고, 그 뒤 바뀐 상태는 감독(state_changed)과 장부가 거절한다. 이 명령의 대조는 장부 판정을 대신하지 않는다.
// 함정: 감독의 "자리 사용 가능"은 감독 장부만 본다. 실행기 저장소에 남은 기록 때문에 실행기가 새 시작을 거절하는 것은 보이지 않는다.
// 관리 기능이라 이 CLI에만 있다(Discord에서 하지 않는다).
import { defineCommand, type OliveAdminExit, type OliveHoldObservation, type OliveHoldRun, type OliveHolds, type OliveReleaseCall, type OliveSupervisorMissing, type OliveSupervisorTarget, type OliveWorkerPod, type ReadCtx, type Step, type WriteCtx } from "../core/command";
import { oliveTargets } from "../core/names";
import { UsageError, type Result, type Status } from "../core/result";

type Outcome = { status: Status; label: string; headline: string; lines: string[]; next?: string | null };
type Confirm = { kind: "pod-replaced"; observation: number | null } | { kind: "abandon-result"; reason: "no_answer" | "not_known" | "unstorable" } | { kind: "store-reset" };
type Request = { runId: string | null; confirm: Confirm | null };

const RUN_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
const LIST = "homelab olive release --apply";
const REREAD = "다시 쓰기 전에 homelab olive release --apply로 자리를 다시 읽는다";
// slotFree는 감독 장부만 본다(olive README "쓰기의 답"). 실행기 쪽 잔여는 이 값에 들지 않는다.
const EXECUTOR_SIDE = "실행기 쪽: 감독 장부의 자리가 풀려도 실행기 저장소에 그 기록이 남아 있으면 실행기가 새 시작을 거절할 수 있다(이 명령은 실행기 저장소를 보지 않는다)";
// D-94. 받은 적 없는 실행은 실행기가 다시 답하면 자동 닫기로 풀릴 수 있다.
const NOT_ACCEPTED = "주의: 실행기가 이 실행을 받았다고 알린 적이 없다. 실행기가 다시 답하면 저절로 풀릴 수 있고, 지금 닫으면 실패로 남아 시작 예산이 같은 요청의 한도에서 빠진 채 남는다";
const ABANDON_WARNING = [
  "경고: 이 실행의 결과를 버린다. 뒤에 결과 보고가 와도 쓰지 않고, 확정은 실패(요청한 취소였으면 취소)다",
  "경고: 장부는 사유를 확인하지 못한다. 곧 실행기의 답으로 풀릴 실행이나, 결과가 있는데 보관만 못 한 실행에 쓰면 그 결과를 잃는다",
  "머문 시간: 자리 목록에는 결과를 기다린 시간이 없다. 감독 로그의 result_check_alert(result_wait_overdue) 줄의 waitedMs로 본다",
];
// D-158·D-170. 장부는 저장소를 비웠는지 확인하지 못한다.
const STORE_RESET_WARNING = [
  "경고: 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤에만 쓴다. 장부는 저장소를 비웠는지 확인하지 못하고, 비우지 않으면 실행기에 그 실행의 기록이 남는다",
  "경고: 저장소를 비우면 그 실행기의 다른 기록도 모두 잃는다. 결과를 보관했던 실행도 실패로 보인다. 실행기 저장소는 사본·스냅샷에서 되살리지 않는다",
];
const REASON_WORD: Record<string, string> = { no_answer: "실행기가 답하지 않는다", not_known: "실행기가 그 실행을 모른다고 답했다", unstorable: "결과가 왔지만 감독이 보관하지 못한다" };

const STATE_WORD: Record<string, string> = {
  queued: "자리를 받기 전",
  preparing: "준비 중",
  running: "도는 중",
  stopping: "멈추는 중이고 종료를 확인하지 못함",
  checking: "종료는 확인됐고 결과를 기다림",
  ready_result: "결과를 받았고 정리를 기다림",
  finalized: "끝남",
  not_started: "시작하지 않음으로 닫힘",
  failed_stopped: "실패로 끝났고 정리를 기다림",
  unknown_running: "끝났는지 모름",
  cleanup_pending: "정리를 기다림",
};
const WHY_WORD: Record<string, string> = { outside_ledger: "장부에 없는 실행을 실행기가 쥐고 있었다", ended_in_ledger: "장부에서 끝난 실행의 시작 영수증이 늦게 왔다" };

// 장부의 거절 이름(olive ledger REFUSALS) 가운데 자리 풀기 쓰기가 낼 수 있는 것의 쉬운 말. 목록 밖은 "장부가 거절했다"와 원래 낱말이다.
const REFUSAL: Record<string, { why: string; next?: string }> = {
  unknown_run: { why: "장부에 그 실행이 없다" },
  run_not_worker: { why: "작업자 실행이 아니다" },
  run_ended: { why: "이미 끝난 실행이다" },
  stop_confirmed: { why: "종료가 이미 확인된 실행이라 파드 교체 닫기를 받지 않는다", next: LIST },
  stop_unconfirmed: { why: "종료가 확인되지 않은 실행이라 저장소 비움 닫기를 받지 않는다", next: LIST },
  transition_denied: { why: "그 상태에서는 이 쓰기를 받지 않는다", next: LIST },
  stop_unknown: { why: "장부가 정지 기록을 읽지 못했다" },
  start_may_launch: { why: "아직 시작이 새로 뜰 수 있는 때이거나, 시작 이력 때문에 닫을 수 없다" },
  pod_started_too_early: { why: "새 파드가 닫을 수 있는 시각 전에 떴다", next: "그 시각 뒤에 작업자 파드를 한 번 더 바꾼 뒤 같은 명령을 다시 실행한다" },
  not_checking: { why: "결과를 기다리는 실행이 아니다(이미 판정됐을 수 있다)", next: LIST },
  reference_mismatch: { why: "종료 영수증이나 관측이 지금 장부와 다르다", next: LIST },
  slot_not_held: { why: "그 관측은 이미 자리를 막지 않는다", next: LIST },
  report_pending: { why: "판정 전 결과 보고가 있다", next: "결과 검사가 그 보고를 판정하기를 기다린 뒤 homelab olive release --apply로 다시 읽는다" },
  outcome_unknown: { why: "사유 없는 취소만 있어 확정 결과를 정할 수 없다", next: "결과를 기다리거나, 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤 --store-reset으로 닫는다" },
  failed_at_unknown: { why: "실패 시각이 없는 옛 줄이다", next: "이 명령으로는 풀 수 없다. 장부 초기화로 넘긴다" },
  ledger_unwritable: { why: "장부에 쓸 수 없는 상태다(한 번 실패한 장부)" },
  invariant_violation: { why: "장부 규칙에 어긋난다" },
};
// 통로의 거절 사유. 어느 것이든 적힌 것 없음이다.
const CHANNEL_REFUSAL: Record<string, { why: string; next?: string }> = {
  state_changed: { why: "앞 상태가 바뀌었다", next: "homelab olive release --apply로 다시 읽고 절차를 다시 고른다" },
  pod_started_later: { why: "넘긴 파드 시각이 감독 시계보다 늦다(시계가 어긋났을 수 있다)" },
  malformed: { why: "감독이 값의 꼴을 받지 않았다(CLI와 감독 이미지의 판이 다를 수 있다)" },
  unknown_command: { why: "감독이 이 명령을 모른다(CLI와 감독 이미지의 판이 다를 수 있다)" },
  busy: { why: "감독의 관리 연결이 가득 찼다", next: "잠시 뒤 같은 명령을 다시 실행한다" },
  not_alive: { why: "감독이 끝나는 중이다" },
  late: { why: "요청 기한이 지났다", next: "잠시 뒤 같은 명령을 다시 실행한다" },
  disabled: { why: "이 감독에는 자리 풀기가 없다" },
};

const MISSING_WORD: Record<OliveSupervisorMissing["state"], string> = {
  absent: "감독이 꺼져 있다(파드 없음)",
  "not-owned": "대조 실패(감독 Deployment의 파드로 확인되지 않아 실행하지 않는다)",
  "not-ready": "감독이 준비되지 않았다",
  terminating: "감독이 내려가는 중이다",
  multiple: "감독 파드가 여럿이라 고르지 않았다",
};

// 감독 시계 epoch ms를 사람이 읽는 시각으로. 홈랩의 시간대(KST)로 적는다.
const at = (ms: number) => `${new Date(ms + 9 * 3_600_000).toISOString().slice(0, 19).replace("T", " ")} KST`;
const yesNo = (v: boolean | null) => (v === true ? "예" : v === false ? "아니오" : "모름");
const short = (id: string) => id.slice(0, 8);

// executor/<역할>/<인스턴스>/<저장소 ID>(olive 계약 principal). 대상 목록의 kind executor 줄과 인스턴스·역할이 같아야 한다.
function workerTarget(executorId: string): { id: string; namespace: string; deployment: string } | null {
  const m = /^executor\/([a-z_]+)\/([a-z0-9][a-z0-9-]{0,62})\/[a-z0-9][a-z0-9-]{0,62}$/.exec(executorId);
  if (m === null || m[1] === "session") return null;
  const t = oliveTargets().find((x) => x.kind === "executor" && x.id === m[2] && x.role === m[1]);
  return t === undefined ? null : { id: t.id, namespace: t.namespace, deployment: t.deployment };
}
const workerName = (executorId: string) => workerTarget(executorId)?.id ?? "모르는";

function replaceSteps(executorId: string, after: number | null, what: "close" | "hold"): string[] {
  const t = workerTarget(executorId);
  const where = t === null ? "그 실행기" : `실행기 ${t.namespace}/${t.deployment}`;
  const lines = [`절차 1) ${where}를 replicas 0으로 줄이고, 옛 파드의 컨테이너가 실제로 끝난 것을 확인한 뒤 1로 되돌린다(파드가 API에서 사라진 것만으로는 확인이 아니다)`];
  if (after !== null) lines.push(what === "close" ? `절차 2) 새 파드는 ${at(after)} 뒤에 떠야 한다` : `절차 2) 새 파드는 관측을 적은 ${at(after)} 뒤에 떠야 한다`);
  return lines;
}

// 실행 줄 하나의 안내. 명령 줄(cmd)은 그대로 붙여 쓸 수 있는 꼴이다.
function runGuide(run: OliveHoldRun, verbose: boolean): string[] {
  const head = `실행 ${run.runId}(${workerName(run.executorId)} 실행기): ${STATE_WORD[run.state] ?? run.state}(${run.state})`;
  const cmd = (flag: string) => `명령: homelab olive release ${run.runId} --apply ${flag}`;
  const lines = [head];
  if (verbose) lines.push(`  실행기 ${run.executorId}, 세대 ${run.runGeneration}, 접수 영수증 ${run.accepted ? "있음" : "없음"}, 확정 지시 ${run.finalizeSent ? "있음" : "없음"}, 닫을 수 있는 시각 ${run.closableAt === null ? "없음" : `${at(run.closableAt)}(${run.closableAt})`}, 다음 ${run.next}`);
  const add = (...more: string[]) => lines.push(...more.map((l) => `  ${l}`));
  if (run.kind !== "worker") {
    add("다음: 없음. 세션 실행은 이 명령으로 풀지 않는다");
    return lines;
  }
  if (run.next === "close_unconfirmed") {
    if (run.closableAt === null) {
      add("다음: 없음. 시작 지시 이력이 없거나 세션 시작이 섞여 관리자 닫기로 닫히지 않는다(기다려도 풀리지 않는다, 남은 길은 장부 초기화)");
      return lines;
    }
    add("다음: 작업자 파드를 바꾼 뒤 실패로 닫는다", ...replaceSteps(run.executorId, run.closableAt, "close"), `절차 3) ${cmd("--pod-replaced").slice(4)}`);
    if (!run.accepted) add(NOT_ACCEPTED);
    return lines;
  }
  if (run.next === "abandon_result") {
    add("다음: 결과를 기다리거나 결과를 버린다", cmd("--abandon-result <no_answer|not_known|unstorable>"), ...ABANDON_WARNING);
    add("실행기가 영영 돌아오지 않으면: 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤 --store-reset으로 닫는다");
    return lines;
  }
  if (run.next === "wait_cleanup") {
    add("다음: 기다린다. 실행기가 확정과 정리 영수증을 내면 저절로 풀린다");
    if (run.state !== "cleanup_pending") add("실행기가 영영 돌아오지 않으면: 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤 닫는다", cmd("--store-reset"), ...STORE_RESET_WARNING);
    return lines;
  }
  if (run.next === "close_store_reset") {
    add("다음: 기다려도 풀리지 않는다(확정 결과를 장부 사실로 정할 수 없다). 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤 닫는다", cmd("--store-reset"), ...STORE_RESET_WARNING);
    return lines;
  }
  if (run.state === "failed_stopped") add("다음: 없음. 실패 시각이 없는 옛 줄이라 이 명령으로 풀 수 없다(장부 초기화로 넘긴다)");
  else add("다음: 없음(진행 중이거나 이 명령으로 풀 상태가 아니다)");
  return lines;
}

function holdGuide(hold: OliveHoldObservation, verbose: boolean): string[] {
  const lines = [`점유 관측 ${hold.observation}(${workerName(hold.executorId)} 실행기, 실행 ${hold.runId}): ${WHY_WORD[hold.why] ?? "자리를 막는 관측"}(${hold.why})`];
  if (verbose) lines.push(`  실행기 ${hold.executorId}, 세대 ${hold.runGeneration}, 적은 시각 ${at(hold.heldAt)}(${hold.heldAt})`);
  const steps = [...replaceSteps(hold.executorId, hold.heldAt, "hold"), `절차 3) homelab olive release ${hold.runId} --apply --pod-replaced --observation ${hold.observation}`, "풀어도 이 실행 ID는 다시 시작하지 않는다(다시 할 일은 새 실행 ID로)"];
  lines.push("  다음: 작업자 파드를 바꾼 뒤 이 관측을 푼다", ...steps.map((l) => `  ${l}`));
  return lines;
}

function listing(h: OliveHolds, verbose: boolean): Outcome {
  const counts = h.runs.length === 0 && h.slotHolds.length === 0 ? "자리를 쥔 실행 없음" : `자리를 쥔 실행 ${h.runs.length}, 점유 관측 ${h.slotHolds.length}`;
  const headline = `자리 풀기: ${counts}. 작업자 자리 사용 가능: ${yesNo(h.slotFree)}`;
  const lines = [...h.runs.flatMap((r) => runGuide(r, verbose)), ...h.slotHolds.flatMap((x) => holdGuide(x, verbose))];
  if (h.truncated) lines.push("목록이 잘렸다: 감독이 앞쪽 줄만 실었다. 앞의 것을 푼 뒤 다시 읽는다");
  if (h.runs.length + h.slotHolds.length > 0) lines.push(EXECUTOR_SIDE);
  return { status: "done", label: "읽음", headline, lines, next: null };
}

function missing(t: OliveSupervisorMissing, what: string): Outcome {
  const waiting = t.state === "not-ready" || t.state === "terminating" || t.state === "multiple";
  return waiting
    ? { status: "waiting", label: "감독 대기", headline: `자리 풀기: ${what}. ${MISSING_WORD[t.state]}`, lines: [], next: "잠시 뒤 같은 명령을 다시 실행한다" }
    : { status: "failed", label: "감독 없음", headline: `자리 풀기: ${what}. ${MISSING_WORD[t.state]}`, lines: [], next: "homelab olive status로 감독 파드를 확인한다" };
}

const notSure = (why: string, lines: string[]): Outcome => ({ status: "failed", label: "결과 모름", headline: `자리 풀기: 결과 모름. ${why}. 장부에 적혔을 수 있다`, lines, next: REREAD });
const notWritten = (why: string, lines: string[], next?: string): Outcome => ({ status: "failed", label: "쓰지 않음", headline: `자리 풀기: 쓰지 않았다. ${why}`, lines, next: next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" });
const usage = (why: string, lines: string[] = []): Outcome => ({ status: "usage", label: "확인 플래그", headline: `자리 풀기: 쓰지 않았다. ${why}`, lines, next: LIST });

// 감독 진입점의 종료 코드를 CLI 공통 규칙(D-61: 0 완료, 1 실패, 3 대기, 64 사용법)으로 옮긴다. 진입점의 64는 이 CLI가 만든 argv를
// 감독이 받지 않은 것이라 사람의 사용법 오류가 아니라 판 어긋남일 수 있는 실패(1)다(D-120). 3은 복원 전이라 장부를 부르지 않은 대기다.
function readExited(r: OliveAdminExit, verbose: boolean): Outcome {
  const lines = verbose ? [`감독 파드 ${r.pod}`, `진입점 종료 코드 ${r.code}`] : [];
  if (r.code === 3) return { status: "waiting", label: "감독 복원 전", headline: `자리 풀기: 자리 목록 모름. 감독이 복원을 마치지 않았다(${r.reason?.word ?? "종료 코드 3"})`, lines, next: "감독이 복원을 마친 뒤 다시: homelab olive release --apply" };
  if (r.code === 64) return { status: "failed", label: "판 어긋남", headline: "자리 풀기: 자리 목록 모름. 감독 진입점이 요청을 받지 않았다(종료 코드 64, CLI와 감독 이미지의 판이 다를 수 있다)", lines, next: "감독 이미지가 자리 풀기를 아는 판인지 확인한다" };
  const word = r.reason ? `(${r.reason.word})` : `(종료 코드 ${r.code})`;
  return { status: "failed", label: "읽지 못함", headline: `자리 풀기: 자리 목록 모름. 감독이 자리 목록을 내지 못했다${word}`, lines, next: "homelab olive status --apply로 감독을 확인한다" };
}

function writeExited(r: OliveAdminExit, lines: string[], run: OliveHoldRun | null): Outcome {
  if (r.code === 3) return { status: "waiting", label: "감독 복원 전", headline: `자리 풀기: 쓰지 않았다. 감독이 복원을 마치지 않았다(${r.reason?.word ?? "종료 코드 3"})`, lines, next: "감독이 복원을 마친 뒤 같은 명령을 다시 실행한다" };
  if (r.code === 64) return notWritten("감독 진입점이 요청을 받지 않았다(종료 코드 64, CLI와 감독 이미지의 판이 다를 수 있다)", lines, "감독 이미지가 자리 풀기를 아는 판인지 확인한다");
  const reason = r.code === 1 ? r.reason : null;
  if (reason === null) return notSure(`감독 진입점이 종료 코드 ${r.code}로 끝났다`, lines);
  if (reason.kind === "refused" && reason.word === "ledger_refused" && reason.detail !== undefined) {
    const known = Object.hasOwn(REFUSAL, reason.detail) ? REFUSAL[reason.detail] : undefined;
    let next = known?.next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다";
    // ledger.md "관리자 닫기를 부르는 쪽": 시간만 모자란 경우와 이력 때문에 기다려도 안 되는 경우를 가른다.
    if (reason.detail === "start_may_launch") next = run?.closableAt == null ? "기다려도 닫히지 않는다(시작 지시 이력 때문). 남은 길은 장부 초기화다" : `${at(run.closableAt)} 뒤에 작업자 파드를 다시 바꾼 뒤 같은 명령을 다시 실행한다`;
    return { status: "failed", label: "장부 거절", headline: `자리 풀기 거절(ledger_refused:${reason.detail}): ${known?.why ?? "장부가 거절했다"}. 적힌 것 없음, 자리는 그대로`, lines, next };
  }
  if (reason.kind === "refused") {
    const known = Object.hasOwn(CHANNEL_REFUSAL, reason.word) ? CHANNEL_REFUSAL[reason.word] : undefined;
    return { status: "failed", label: "거절", headline: `자리 풀기 거절(${reason.word}): ${known?.why ?? "감독이 거절했다"}. 적힌 것 없음`, lines, next: known?.next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" };
  }
  if (reason.kind === "unreached") return notWritten(`감독에 닿지 못했다(${reason.word})`, lines, "homelab olive status --apply로 감독을 확인한다");
  // 진입점은 쓰기 요청을 다 보낸 뒤의 실패를 write_unknown:<까닭>으로 낸다. 이 갈래는 다 보내기 전이다(olive client.ts).
  if (reason.kind === "no-reply") return notWritten(`감독의 답을 받지 못했다(${reason.word}, 요청을 다 보내기 전)`, lines);
  if (reason.word === "write_unknown") return notSure(`장부에 적혔는지 모른다(write_unknown${reason.detail ? `:${reason.detail}` : ""})`, lines);
  return notWritten(`감독이 쓰기 전에 멈췄다(${reason.word})`, lines);
}

// plan의 "실행:" 줄은 사람이 복사해 붙일 수 있어 셸 인용 꼴로 보인다. 실제 실행은 셸 없이 argv 배열로 간다.
const shellWord = (t: string) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(t) ? t : `'${t.replaceAll("'", `'\\''`)}'`);

function planned(c: ReadCtx, req: Request): Outcome {
  let t: OliveSupervisorTarget;
  try {
    t = c.oliveAdmin.target("holds");
  } catch {
    return { status: "failed", label: "읽지 못함", headline: "자리 풀기: 감독 파드를 읽지 못했다", lines: [], next: "kubectl 접속을 확인한 뒤 다시 실행한다" };
  }
  if (t.state !== "ready") return missing(t, "읽지 않았다");
  const lines = [`실행: ${t.argv.map(shellWord).join(" ")}`];
  if (req.runId !== null && req.confirm !== null) lines.push("--apply에서 자리 목록을 다시 읽고, 앞 상태가 확인 플래그와 맞을 때만 맞는 쓰기 하나를 부른다(파드 근거는 그때 쿠버네티스에서 읽는다)");
  const headline = req.runId === null ? `자리 풀기: --apply로 자리 목록을 읽는다(쓰지 않는다). 대상 파드 ${t.pod}` : `자리 풀기: --apply로 자리 목록을 다시 읽은 뒤 실행 ${req.runId}를 푼다. 대상 파드 ${t.pod}`;
  return { status: "pending", label: "읽을 예정", headline, lines };
}

// 확인 플래그와 앞 상태를 맞춘다. 맞으면 부를 쓰기의 종류, 아니면 사용법(64)과 맞는 플래그 안내다.
type Plan = { kind: "close-unconfirmed" | "close-store-reset"; run: OliveHoldRun } | { kind: "abandon-result"; run: OliveHoldRun; reason: "no_answer" | "not_known" | "unstorable" } | { kind: "release-hold"; hold: OliveHoldObservation };

function choose(h: OliveHolds, req: Request & { runId: string }, verbose: boolean): Plan | Outcome {
  const run = h.runs.find((r) => r.runId === req.runId) ?? null;
  const holds = h.slotHolds.filter((x) => x.runId === req.runId);
  const confirm = req.confirm;
  if (confirm?.kind === "pod-replaced" && confirm.observation !== null) {
    const hold = holds.find((x) => x.observation === confirm.observation);
    if (hold === undefined) return usage(`실행 ${req.runId}에 점유 관측 ${confirm.observation}이 없다`, holds.flatMap((x) => holdGuide(x, verbose)));
    return { kind: "release-hold", hold };
  }
  if (run === null) {
    if (holds.length > 0) return usage("이 실행 ID는 점유 관측으로만 자리를 막는다. 관측 번호를 --observation으로 준다", holds.flatMap((x) => holdGuide(x, verbose)));
    const why = h.truncated ? "자리 목록에 그 실행이 없다(목록이 잘려 빠졌을 수 있다)" : "그 실행은 지금 자리를 쥐고 있지 않다";
    return { status: "failed", label: "목록에 없음", headline: `자리 풀기: 쓰지 않았다. ${why}`, lines: [], next: LIST };
  }
  const guide = runGuide(run, verbose);
  if (confirm === null) return usage("확인 플래그가 없다. 아래 안내의 플래그를 준다", guide);
  if (run.kind === "worker" && confirm.kind === "pod-replaced" && run.next === "close_unconfirmed") {
    if (run.closableAt === null) return { status: "failed", label: "닫을 수 없음", headline: "자리 풀기: 쓰지 않았다. 시작 지시 이력이 없거나 세션 시작이 섞여 관리자 닫기로 닫히지 않는다(기다려도 풀리지 않는다)", lines: guide, next: "이 명령으로는 풀 수 없다. 남은 길은 장부 초기화다" };
    return { kind: "close-unconfirmed", run };
  }
  if (run.kind === "worker" && confirm.kind === "abandon-result" && run.next === "abandon_result" && run.stopReceiptId !== null) return { kind: "abandon-result", run, reason: confirm.reason };
  // D-158: 저장소 비움 닫기는 종료가 확인된 checking·ready_result·failed_stopped(실패 시각 있음)만 받는다. cleanup_pending은 목록 밖이다.
  const storeResettable = run.state === "checking" || run.state === "ready_result" || (run.state === "failed_stopped" && run.next !== "none");
  if (run.kind === "worker" && confirm.kind === "store-reset" && storeResettable) {
    if (run.closableAt === null) return { status: "failed", label: "닫을 수 없음", headline: "자리 풀기: 쓰지 않았다. 시작 지시 이력이 없어 저장소 비움 닫기로 닫히지 않는다", lines: guide, next: "이 명령으로는 풀 수 없다. 남은 길은 장부 초기화다" };
    return { kind: "close-store-reset", run };
  }
  return usage(`확인 플래그 --${confirm.kind}가 이 실행의 앞 상태(${run.state})와 맞지 않는다. 아래 안내의 플래그를 준다`, guide);
}

// 그 실행기의 새 파드를 읽어 근거로 쓴다. 준비 전·내려가는 중·여럿이면 대기(3), 없거나 대조 실패면 1이다. 쓰기 전이라 적힌 것 없음.
function podEvidence(w: WriteCtx, executorId: string, after: number, what: "close" | "hold", lines: string[], verbose: boolean): { pod: { name: string; createdAt: number } } | { outcome: Outcome } {
  const t = workerTarget(executorId);
  if (t === null) return { outcome: notWritten("이 CLI의 대상 목록에서 그 실행기를 찾지 못했다", lines, "대상 목록이 바뀌었으면 CLI를 다시 설치한 뒤 다시 실행한다") };
  let p: OliveWorkerPod;
  try {
    p = w.oliveAdmin.workerPod(t.id);
  } catch {
    return { outcome: notWritten("작업자 파드를 읽지 못했다(읽지 못함 또는 시간 초과)", lines, "kubectl 접속을 확인한 뒤 다시 실행한다") };
  }
  const where = `${t.namespace}/${t.deployment}`;
  if (p.state === "absent") return { outcome: notWritten(`작업자 파드가 없다(${where})`, lines, "작업자 파드를 새로 띄운 뒤 같은 명령을 다시 실행한다") };
  if (p.state === "not-owned") return { outcome: notWritten(`작업자 파드가 그 실행기 Deployment의 것으로 확인되지 않았다(${where})`, lines, "kubectl로 그 파드의 소유 관계를 확인한다") };
  if (p.state !== "ready") {
    const why = p.state === "terminating" ? "옛 파드가 아직 내려가는 중이다" : p.state === "multiple" ? "작업자 파드가 여럿이다" : "새 파드가 아직 준비되지 않았다";
    return { outcome: { status: "waiting", label: "파드 대기", headline: `자리 풀기: 쓰지 않았다. ${why}(${where})`, lines, next: "새 파드 하나만 준비된 뒤 같은 명령을 다시 실행한다" } };
  }
  if (verbose) lines.push(`작업자 파드 ${p.name}, 뜬 시각 ${at(p.createdAt)}(${p.createdAt}, creationTimestamp 초 단위 내림)`);
  // 장부도 같은 조건으로 거절한다(pod_started_too_early, 점유 관측은 그 관측 시각). 쓰기 전에 멈춰 다시 바꿀 시각을 보인다.
  if (p.createdAt < after) {
    const why = what === "close" ? `새 파드가 닫을 수 있는 시각(${at(after)}) 전에 떴다(${at(p.createdAt)})` : `새 파드가 관측을 적은 시각(${at(after)}) 전에 떴다(${at(p.createdAt)})`;
    return { outcome: notWritten(why, lines, `${at(after)} 뒤에 작업자 파드를 다시 바꾼 뒤 같은 명령을 다시 실행한다`) };
  }
  return { pod: { name: p.name, createdAt: p.createdAt } };
}

function released(call: OliveReleaseCall, a: { released: boolean; slotFree: boolean | null }, lines: string[]): Outcome {
  const headline =
    call.command === "abandon-result"
      ? `자리 풀기: 실행 ${call.runId}의 결과를 버렸다(실패로 옮김)`
      : call.command === "release-hold"
        ? `자리 풀기: 점유 관측 ${call.observation}(실행 ${call.runId})을 풀었다`
        : `자리 풀기: 실행 ${call.runId}를 실패로 닫았다`;
  const held = a.released ? "예" : call.command === "abandon-result" ? "아니오(실패 확정과 실행기의 정리 영수증 뒤에 놓는다)" : "아니오";
  const out = [`그 실행의 자리를 놓았다: ${held}`, `작업자 자리 사용 가능: ${yesNo(a.slotFree)}`, EXECUTOR_SIDE, ...lines];
  return { status: "done", label: call.command === "abandon-result" ? "결과 버림" : call.command === "release-hold" ? "관측 풀림" : "닫음", headline, lines: out, next: a.slotFree === true ? null : "homelab olive release --apply로 남은 자리를 본다" };
}

function applied(w: WriteCtx, req: Request, verbose: boolean): Outcome {
  let read;
  try {
    read = w.oliveAdmin.holds();
  } catch {
    return { status: "failed", label: "읽지 못함", headline: "자리 풀기: 자리 목록 모름. 감독 관리 진입점이 실패했거나 감독 파드를 읽지 못했다", lines: [], next: "kubectl 접속을 확인한 뒤 다시 실행한다" };
  }
  if (read.state === "no-target") return missing(read.target, req.runId === null ? "읽지 않았다" : "쓰지 않았다");
  if (read.state === "exit") return readExited(read, verbose);
  if (read.state === "unknown") return { status: "failed", label: "읽지 못함", headline: "자리 풀기: 자리 목록 모름. 감독의 답을 확인하지 못했다(시간 초과이거나 답의 꼴이 다르다. CLI와 감독 이미지의 판이 다를 수 있다)", lines: [], next: "homelab olive status --apply로 감독을 확인한다" };
  const lines = verbose ? [`감독 파드 ${read.pod}`] : [];
  if (req.runId === null) {
    const o = listing(read.holds, verbose);
    return { ...o, lines: [...lines, ...o.lines] };
  }
  const plan = choose(read.holds, { runId: req.runId, confirm: req.confirm }, verbose);
  if ("status" in plan) return { ...plan, lines: [...lines, ...plan.lines] };
  let call: OliveReleaseCall;
  if (plan.kind === "abandon-result") {
    call = { command: "abandon-result", runId: plan.run.runId, reason: plan.reason, stopReceiptId: plan.run.stopReceiptId as string };
    lines.push(`사유: ${REASON_WORD[plan.reason]}(${plan.reason})`, ...ABANDON_WARNING);
  } else if (plan.kind === "release-hold") {
    const ev = podEvidence(w, plan.hold.executorId, plan.hold.heldAt, "hold", lines, verbose);
    if ("outcome" in ev) return ev.outcome;
    const h = plan.hold;
    call = { command: "release-hold", executorId: h.executorId, runId: h.runId, runGeneration: h.runGeneration, observation: h.observation, podName: ev.pod.name, podStartedAt: ev.pod.createdAt };
  } else {
    const ev = podEvidence(w, plan.run.executorId, plan.run.closableAt as number, "close", lines, verbose);
    if ("outcome" in ev) return ev.outcome;
    call = { command: plan.kind, runId: plan.run.runId, fromState: plan.run.state, podName: ev.pod.name, podStartedAt: ev.pod.createdAt };
    if (plan.kind === "close-unconfirmed" && !plan.run.accepted) lines.push(NOT_ACCEPTED);
    if (plan.kind === "close-store-reset") lines.push(...STORE_RESET_WARNING);
  }
  let r;
  try {
    r = w.oliveAdmin.release(call);
  } catch {
    // 어댑터는 exec 전에만 던진다(감독 파드를 읽지 못함·시간 초과, 값의 꼴). 보낸 것이 없다.
    return notWritten("쓰기 전에 멈췄다(감독 파드를 읽지 못했거나 시간 초과, 또는 값의 꼴이 다르다)", lines, "kubectl 접속을 확인한 뒤 다시 실행한다");
  }
  if (r.state === "no-target") return missing(r.target, "쓰지 않았다");
  if (r.state === "exit") return writeExited(r, lines, "run" in plan ? plan.run : null);
  if (r.state === "unknown") return notSure("실행했지만 감독의 답을 확인하지 못했다", lines);
  return released(call, r.answer, lines);
}

// olive test-job과 같은 꼴의 한 단계: apply 뒤의 끝 상태는 엔진이 아니라 Outcome이 정한다.
async function runRelease(ctx: ReadCtx, req: Request, verbose: boolean): Promise<Result> {
  let done = null as Outcome | null;
  let plan = null as Outcome | null;
  const step: Step = {
    id: "olive-release",
    target: "올리브 자리 풀기",
    async read(c) {
      if (done) return { state: "same", action: "none", detail: done.label };
      if (c.mode === "apply") return { state: "differs", action: "update", detail: "실행" };
      plan = planned(c, req);
      return { state: "differs", action: "update", detail: plan.label };
    },
    async apply(w) {
      done = applied(w, req, verbose);
    },
  };
  const r = await ctx.engine({ command: "olive release", steps: [step] });
  const o: Outcome | null = done ?? plan;
  if (o === null || r.status === "failed") return r;
  const failing = o.status === "failed" || o.status === "usage";
  const steps = r.steps.map((s) => ({ ...s, detail: o.label, result: failing ? ("failed" as const) : o.status === "waiting" ? ("waiting" as const) : s.result }));
  const next = o.next === undefined ? r.next : o.next;
  const result: Result = { ...r, status: o.status, steps, body: [o.headline, ...o.lines].join("\n"), next };
  if (failing) result.error = { message: o.headline, next: next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" };
  return result;
}

export function makeOliveRelease() {
  return defineCommand({
    path: ["olive", "release"],
    summary: "올리브 작업 자리 풀기(관리자)",
    help: {
      about:
        "올리브 감독 장부에서 작업 자리를 쥔 채 스스로 풀리지 않는 실행을 풉니다. 실행 ID 없이 --apply를 주면 자리 목록을 읽어 실행마다 다음 행동과 절차를 보이고 쓰지 않습니다. 실행 ID와 확인 플래그 하나를 주고 --apply를 주면 자리 목록을 다시 읽어 앞 상태가 플래그와 맞을 때만 쓰기 하나를 부르고, 맞지 않으면 쓰지 않고 맞는 플래그를 알립니다(64). --pod-replaced는 작업자 파드를 바꾼 뒤 그 파드의 이름과 뜬 시각을 쿠버네티스에서 읽어 넘깁니다. 계획은 대상 파드와 실행할 명령만 보입니다. 결과는 그 실행의 자리를 놓았는지와 작업자 자리를 쓸 수 있는지를 따로 보이고, 작업자 자리는 감독 장부만 본 값입니다. 종료 코드는 0 읽음·풀림, 1 거절·실패·결과 모름, 3 대기(감독 복원 전, 파드 준비 전), 64 사용법·확인 플래그가 앞 상태와 맞지 않음입니다. 결과 모름이면 장부에 적혔을 수 있으니 다시 쓰기 전에 자리 목록을 다시 읽습니다.",
      examples: ["homelab olive release", "homelab olive release 0f0f0f0f-0000-4000-8000-000000000001 --pod-replaced"],
      related: ["olive"],
      destructive: "닫거나 결과를 버린 실행은 되돌릴 수 없고, --abandon-result는 그 실행의 결과를 버립니다.",
    },
    // --apply에서 감독 파드에 exec해서(쓰기로 판정) --apply를 받아야 한다.
    kind: "change",
    args: [{ name: "run", required: false, help: "풀 실행 ID(자리 목록의 실행 ID)", pattern: RUN_ID }],
    flags: [
      { name: "pod-replaced", kind: "bool", help: "작업자 파드를 바꿨다(종료 모름 닫기, 점유 관측 풀기)" },
      { name: "abandon-result", kind: "value", valueName: "사유", values: ["no_answer", "not_known", "unstorable"], help: "결과를 버린다(결과를 기다리는 실행)" },
      { name: "store-reset", kind: "bool", help: "실행기 저장소를 비우고 파드를 새로 띄웠다" },
      { name: "observation", kind: "value", valueName: "번호", pattern: /0|[1-9][0-9]{0,15}/, help: "풀 점유 관측 번호(--pod-replaced와 함께)" },
      { name: "verbose", kind: "bool", help: "실행기·세대·시각·파드까지 보기" },
    ],
    async run(ctx, input) {
      const f = input.flags;
      const runId = (input.args.run as string | undefined) ?? null;
      const picked = [f["pod-replaced"] === true, f["abandon-result"] !== undefined, f["store-reset"] === true].filter(Boolean).length;
      if (picked > 1) throw new UsageError("확인 플래그(--pod-replaced, --abandon-result, --store-reset)는 하나만 준다");
      if (picked === 1 && runId === null) throw new UsageError("확인 플래그는 실행 ID와 함께 준다");
      if (f.observation !== undefined && f["pod-replaced"] !== true) throw new UsageError("--observation은 --pod-replaced와 함께 준다");
      let confirm: Confirm | null = null;
      if (f["pod-replaced"] === true) confirm = { kind: "pod-replaced", observation: f.observation === undefined ? null : Number(f.observation) };
      else if (typeof f["abandon-result"] === "string") confirm = { kind: "abandon-result", reason: f["abandon-result"] as "no_answer" | "not_known" | "unstorable" };
      else if (f["store-reset"] === true) confirm = { kind: "store-reset" };
      return runRelease(ctx, { runId, confirm }, f.verbose === true);
    },
  });
}

export default makeOliveRelease();
