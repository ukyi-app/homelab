// homelab olive: 올리브의 상태와 비상 정지 상태를 읽기만 한다(supervisor.md 7·10절).
// 대상 목록은 빌드할 때 실행 파일에 들어가 GitHub·네트워크에 기대지 않는다.
// 감독 상태는 kubectl exec로 읽어 쓰기로 판정되므로 --apply에서만 나온다.
import { defineCommand, type OliveAdminOutcome, type OliveSupervisorMissing, type OliveSupervisorTarget, type ReadCtx, type WriteCtx } from "../core/command";
import { oliveTargets } from "../core/names";
import { UsageError } from "../core/result";
import { countPods, lockSummary, podWords, readAll, readFailed, replicasWords, runAction, targetLine, type Action, type Outcome, type TargetView } from "./olive-state";
import { stopStatus, stopVerify } from "./olive-stop";

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

export function makeOlive() {
  return defineCommand({
    path: ["olive"],
    summary: "올리브 상태와 정지 상태 보기",
    help: {
      about:
        "올리브의 상태와 비상 정지 상태를 읽어 보여 줍니다. 정지를 걸거나 푸는 명령은 이 CLI에 아직 없습니다. stop verify는 밖에서 실제로 걸린 자물쇠만 판독합니다. 감독 상태 줄은 kubectl exec로 읽어 status --apply에서만 나옵니다. 종료 코드는 1 실패·차단 미완, 3 대기, 64 사용법이고, 0의 뜻은 동작마다 다릅니다: status·stop status는 읽은 상태를 보고했다, stop verify는 Kubernetes에서 자물쇠와 파드 소멸까지 확인했다(정지됨, 노드 미확인).",
      examples: ["homelab olive status", "homelab olive stop verify"],
      actions: [
        { name: "status", about: "정지 여부·replicas·자물쇠·실행 파드 보기" },
        { name: "stop", target: "status", about: "정지 상태 보기" },
        { name: "stop", target: "verify", about: "Kubernetes에서 실행 파드 소멸 확인(노드 확인 없음)" },
      ],
    },
    // status --apply가 감독 파드에 exec해서(쓰기로 판정) --apply를 받아야 한다.
    kind: "change",
    args: [
      { name: "action", required: true, help: "동작(아래 동작 목록)", pattern: /status|stop/ },
      { name: "sub", required: false, help: "stop의 동작(status, verify)", pattern: /status|verify/ },
    ],
    flags: [{ name: "verbose", kind: "bool", help: "대상별 줄까지 보기" }],
    async run(ctx, input) {
      const action = input.args.action as string;
      const sub = input.args.sub;
      const verbose = input.flags.verbose === true;
      if (action === "stop" && sub === undefined) throw new UsageError("stop 뒤에 status, verify 중 하나를 준다");
      if (action !== "stop" && sub !== undefined) throw new UsageError(`${action}에는 뒤 인자를 주지 않는다`);
      if (action === "stop" && input.apply) throw new UsageError(`stop ${sub}는 읽기 동작이라 --apply를 받지 않는다`);
      if (action === "status") return runAction(ctx, statusAction(verbose));
      if (sub === "status") return runAction(ctx, stopStatus(verbose));
      return runAction(ctx, stopVerify(verbose));
    },
  });
}

export default makeOlive();
