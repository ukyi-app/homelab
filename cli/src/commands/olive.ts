// homelab olive: 올리브의 상태 보기, 켜기, 비상 정지(supervisor.md 7·10절).
// 켜고 끄기와 정지는 Kubernetes만으로 된다. 대상 목록은 빌드할 때 실행 파일에 들어가 GitHub·네트워크에 기대지 않는다.
// 감독 상태는 kubectl exec로 읽어 쓰기로 판정되므로 --apply에서만 나온다.
import { defineCommand, type OliveAdminOutcome, type OliveSupervisorMissing, type OliveSupervisorTarget, type ReadCtx, type WriteCtx } from "../core/command";
import { oliveTargets } from "../core/names";
import { UsageError } from "../core/result";
import { LIMITS, bringUp, countPods, lockSpots, lockSummary, podWords, readAll, readFailed, readLocks, replicasWords, runAction, targetLine, uniqueNamespaces, type Action, type Limits, type LockSpot, type Outcome, type TargetView, type UpState } from "./olive-state";
import { stopOn, stopStatus, stopVerify } from "./olive-stop";

const MISSING_WORD: Record<OliveSupervisorMissing["state"], string> = {
  absent: "꺼져 있음(파드 없음)",
  "not-owned": "대조 실패(감독 Deployment의 파드로 확인되지 않아 실행하지 않았다)",
  "not-ready": "준비되지 않음",
  terminating: "내려가는 중",
  multiple: "파드가 여럿이라 고르지 않았다",
};

type Supervisor = { line: string; status: "ok" | "waiting" | "failed" };

function missing(t: OliveSupervisorMissing): Supervisor {
  const status = t.state === "absent" ? "ok" : t.state === "not-owned" ? "failed" : "waiting";
  return { line: `감독: ${MISSING_WORD[t.state]}`, status };
}

function plannedSupervisor(c: ReadCtx): Supervisor {
  let t: OliveSupervisorTarget;
  try {
    t = c.oliveAdmin.target("status");
  } catch {
    return { line: "감독: 읽지 못함", status: "failed" };
  }
  return t.state === "ready" ? { line: `감독: --apply로 읽는다. 대상 파드 ${t.pod}, 실행: ${t.argv.join(" ")}`, status: "ok" } : missing(t);
}

function reportedSupervisor(w: WriteCtx): Supervisor {
  let r: OliveAdminOutcome;
  try {
    r = w.oliveAdmin.run("status");
  } catch {
    return { line: "감독: 관리 진입점이 실패했거나 응답 꼴이 다르다", status: "failed" };
  }
  if (r.state === "unknown") return { line: "감독: 결과 미상(시간 초과. 꺼짐으로 읽지 않는다)", status: "failed" };
  if (r.state === "no-target") return missing(r.target);
  const s = r.status;
  return { line: `감독: ${s.alive ? "살아 있음" : "응답했지만 살아 있지 않음"}, 대기 ${s.queued}, 실행 ${s.running}, 자동 진단 ${s.diagnosis === "active" ? "켜짐" : "멈춤"}, 정지 ${s.stop}(세대 ${s.stopGeneration}), 접수 ${s.intakeOpen ? "열림" : "닫힘"}`, status: "ok" };
}

function statusOutcome(views: TargetView[], sup: Supervisor, verbose: boolean, planned: boolean): Outcome {
  const locks = lockSummary(views);
  const state = locks.held === 0 ? "정지 아님" : locks.held === locks.present ? "정지 중" : "일부만 정지";
  const lines = [sup.line, replicasWords(views), ...(verbose ? views.map(targetLine) : [])];
  const summary = `${locks.words}, ${podWords(countPods(views))}`;
  if (readFailed(views)) return { status: "failed", label: "읽지 못함", headline: `확인 실패: 읽지 못한 대상이 있다. ${summary}`, lines: [sup.line, replicasWords(views), ...views.map(targetLine)], next: "kubectl 접속을 확인한 뒤 다시: homelab olive status" };
  if (sup.status === "failed") return { status: "failed", label: "감독 확인 실패", headline: `${state}: ${summary}. ${sup.line}`, lines, next: "homelab olive status --verbose로 대상별 상태를 본다" };
  if (sup.status === "waiting") return { status: "waiting", label: "감독 대기", headline: `${state}: ${summary}. ${sup.line}`, lines, next: "잠시 뒤 다시: homelab olive status --apply" };
  return { status: planned ? "pending" : "done", label: state, headline: `${state}: ${summary}`, lines, ...(planned ? {} : { next: null }) };
}

function statusAction(verbose: boolean): Action {
  const targets = () => oliveTargets();
  return {
    command: "olive status",
    target: "올리브 상태",
    title: "homelab olive status",
    plan: (c) => statusOutcome(readAll(c, targets()), plannedSupervisor(c), verbose, true),
    apply: (w) => statusOutcome(readAll(w, targets()), reportedSupervisor(w), verbose, false),
  };
}

const NO_RELEASE = "정지를 푸는 명령은 이 CLI에 아직 없다. 정지 상태는 homelab olive stop status로 본다";
const LOCK_WORD = { same: "걸림", different: "같은 이름의 다른 quota", deleting: "지우는 중" } as const;
const isHeld = (s: LockSpot): s is LockSpot & { lock: keyof typeof LOCK_WORD } => s.lock === "same" || s.lock === "different" || s.lock === "deleting";
const heldWords = (spots: LockSpot[]) => spots.filter(isHeld).map((s) => `${s.ns}(${LOCK_WORD[s.lock]})`);
const unreadSpots = (spots: LockSpot[]) => spots.filter((s) => s.lock === "unread").map((s) => s.ns);

// 자물쇠가 조금이라도 있으면 켜지 않는다. 읽지 못한 자물쇠는 정지 중이라고도 아니라고도 하지 않고 켜지 않는다.
function startRefused(spots: LockSpot[], moment: string): Outcome | null {
  const held = heldWords(spots);
  const unread = unreadSpots(spots);
  if (held.length) return { status: "failed", label: "켜지 않음", headline: `켜지 않음: 정지 중이다. ${moment}정지 자물쇠가 있어 켜지 않는다(${held.join(", ")})`, lines: unread.length ? [`자물쇠를 읽지 못한 곳: ${unread.join(", ")}`] : [], next: NO_RELEASE };
  if (unread.length) return { status: "failed", label: "자물쇠 미상", headline: `켜지 않음: ${moment}자물쇠를 읽지 못해 정지 중인지 모른다(${unread.join(", ")})`, lines: [], next: "kubectl 접속을 확인한 뒤 다시: homelab olive start" };
  return null;
}

const UP_WORD: Record<UpState, string> = { ready: "준비됨", "not-ready": "준비를 확인하지 못함", deleting: "다시 읽은 Deployment가 삭제 중", unknown: "다시 읽어 replicas 1을 확인하지 못함" };

function startApply(w: WriteCtx, limits: Limits, verbose: boolean): Outcome {
  const views = readAll(w, oliveTargets());
  const refused = startRefused(lockSpots(views), "");
  if (refused) return refused;
  const startable = views.filter((v) => v.target.start);
  const present = startable.filter((v) => v.deployment.state === "present");
  const unread = startable.filter((v) => v.deployment.state === "unread").map((v) => v.target.id);
  const before = [...startable.filter((v) => v.deployment.state !== "present").map((v) => `${v.target.id}: Deployment ${v.deployment.state === "absent" ? "없음" : "읽지 못함"}`), ...(verbose ? views.map((v) => `실행 전 ${targetLine(v)}`) : [])];
  if (present.length === 0) {
    if (unread.length) return { status: "failed", label: "켤 대상 미상", headline: `켜지 않음: 켤 대상의 Deployment를 읽지 못했다(${unread.join(", ")})`, lines: before, next: "kubectl 접속을 확인한 뒤 다시: homelab olive start" };
    return { status: "failed", label: "켤 대상 없음", headline: "켜지 않음: 켤 수 있는 Deployment가 없다", lines: before, next: "homelab olive status --verbose로 대상을 확인한다" };
  }

  // 처음 읽기와 replicas 쓰기 사이에 정지가 걸렸을 수 있어 쓰기 직전에 자물쇠를 다시 읽는다.
  // 함정: 다른 객체의 읽기와 쓰기라 원자적이지 않다. 이 읽기 뒤에 걸린 정지는 아래의 끝 읽기에서만 보인다.
  const recheck = startRefused(readLocks(w, uniqueNamespaces(views).map((v) => v.target.namespace)), "켜기 직전에 다시 읽으니 ");
  if (recheck) return { ...recheck, lines: [...before, ...recheck.lines] };

  const results = present.map((v) => ({ id: v.target.id, ...bringUp(w, v, limits.startReadySec) }));
  // 결과를 말하기 전에 다시 읽는다. 켜는 동안 걸린 정지를 보통의 준비 대기·켜짐으로 덮지 않는다.
  const after = readAll(w, oliveTargets());
  const lines = [...before, ...results.map((r) => `${r.id}: ${r.asked ? "replicas 1을 요청했다" : "replicas가 이미 1이라 쓰지 않았다"}, ${UP_WORD[r.state]}`), ...(verbose ? after.map(targetLine) : [])];
  const asked = results.filter((r) => r.asked).map((r) => r.id);
  const stopped = heldWords(lockSpots(after));
  if (stopped.length) {
    return {
      status: "failed",
      label: "켜는 중 정지됨",
      headline: `켜는 중에 정지가 걸렸다: 자물쇠 ${stopped.join(", ")}. ${asked.length ? `${asked.join(", ")}에 replicas 1을 요청했다` : "replicas는 쓰지 않았다"}`,
      lines,
      next: "replicas를 다시 0으로 내리고 정지를 확인한다: homelab olive stop on --apply",
    };
  }
  const lockUnread = unreadSpots(lockSpots(after));
  if (lockUnread.length) return { status: "failed", label: "자물쇠 미상", headline: `켜기 결과 미상: 끝낼 때 자물쇠를 읽지 못해 켜는 중에 정지가 걸렸는지 모른다(${lockUnread.join(", ")})`, lines, next: "kubectl 접속을 확인한 뒤: homelab olive stop status" };

  const idsOf = (state: UpState) => results.filter((r) => r.state === state).map((r) => r.id);
  if (idsOf("unknown").length) return { status: "failed", label: "켜기 미상", headline: `켜기 미상: ${idsOf("unknown").join(", ")}의 replicas 1을 다시 읽어 확인하지 못했다`, lines, next: "homelab olive status --verbose로 확인한 뒤 다시: homelab olive start --apply" };
  if (idsOf("deleting").length) return { status: "failed", label: "켜기 미상", headline: `켜기 미상: ${idsOf("deleting").join(", ")}의 Deployment가 삭제 중이다`, lines, next: "homelab olive status --verbose로 확인한다" };
  if (unread.length) return { status: "failed", label: "일부 확인 실패", headline: `일부만 켰다: ${unread.join(", ")}의 Deployment를 읽지 못했다`, lines, next: "kubectl 접속을 확인한 뒤 다시: homelab olive start --apply" };
  if (idsOf("not-ready").length) return { status: "waiting", label: "준비 대기", headline: `준비 대기: ${idsOf("not-ready").join(", ")}의 준비를 ${limits.startReadySec}초 안에 확인하지 못했다`, lines, next: "homelab olive status --verbose로 확인한다" };
  return { status: "done", label: "켜짐", headline: `켜짐: ${present.map((v) => v.target.id).join(", ")}`, lines, next: null };
}

function startAction(limits: Limits, verbose: boolean): Action {
  return {
    command: "olive start",
    target: "올리브 켜기",
    plan(c) {
      const views = readAll(c, oliveTargets());
      const refused = startRefused(lockSpots(views), "");
      if (refused) return refused;
      const names = views.filter((v) => v.target.start).map((v) => v.target.id);
      return { status: "pending", label: "켤 수 있는 대상만 올린다", headline: `계획: ${names.join(", ")}를 replicas 1로 올린다`, lines: verbose ? views.map(targetLine) : [] };
    },
    apply: (w) => startApply(w, limits, verbose),
  };
}

export function makeOlive(limits: Limits = LIMITS) {
  return defineCommand({
    path: ["olive"],
    summary: "올리브 상태 보기·켜기·비상 정지",
    help: {
      about:
        "올리브의 상태를 보고, 켜고, 비상 정지를 겁니다. 정지를 푸는 동작은 아직 없습니다. 바꾸는 동작은 --apply가 있어야 실행합니다. 감독 상태 줄도 kubectl exec로 읽어 --apply에서만 나옵니다. 종료 코드는 1 실패·차단 미완, 3 대기, 64 사용법이고, 0의 뜻은 동작마다 다릅니다: --apply 없는 start·stop on은 계획을 냈다, status·stop status는 읽은 상태를 보고했다, stop on --apply·stop verify는 Kubernetes에서 파드 소멸까지 확인했다(정지됨, 노드 미확인), start --apply는 다시 읽어 켜짐을 확인했다.",
      examples: ["homelab olive status", "homelab olive stop on", "homelab olive stop verify"],
      destructive: "stop on을 실행하면 진행 중인 실행과 세션이 끝나고, 끝난 실행은 되살릴 수 없습니다. 정지를 푸는 동작도 아직 없습니다.",
      actions: [
        { name: "status", about: "정지 여부·replicas·자물쇠·실행 파드 보기" },
        { name: "start", about: "켤 수 있는 대상만 켜기(정지 중이면 거절)" },
        { name: "stop", target: "on", about: "비상 정지 걸기" },
        { name: "stop", target: "status", about: "정지 상태 보기" },
        { name: "stop", target: "verify", about: "Kubernetes에서 실행 파드 소멸 확인(노드 확인 없음)" },
      ],
    },
    kind: "change",
    args: [
      { name: "action", required: true, help: "동작(아래 동작 목록)", pattern: /status|start|stop/ },
      { name: "sub", required: false, help: "stop의 동작(on, status, verify)", pattern: /on|status|verify/ },
    ],
    flags: [{ name: "verbose", kind: "bool", help: "대상별 줄까지 보기" }],
    async run(ctx, input) {
      const action = input.args.action as string;
      const sub = input.args.sub;
      const verbose = input.flags.verbose === true;
      if (action === "stop" && sub === undefined) throw new UsageError("stop 뒤에 on, status, verify 중 하나를 준다");
      if (action !== "stop" && sub !== undefined) throw new UsageError(`${action}에는 뒤 인자를 주지 않는다`);
      if (action === "stop" && (sub === "status" || sub === "verify") && input.apply) throw new UsageError(`stop ${sub}는 읽기 동작이라 --apply를 받지 않는다`);
      if (action === "status") return runAction(ctx, statusAction(verbose));
      if (action === "start") return runAction(ctx, startAction(limits, verbose));
      if (sub === "on") return runAction(ctx, stopOn(limits, verbose));
      if (sub === "status") return runAction(ctx, stopStatus(verbose));
      return runAction(ctx, stopVerify(verbose));
    },
  });
}

export default makeOlive();
