// homelab olive: 올리브의 상태 보기, 켜기, 비상 정지(supervisor.md 7·10절).
// 켜고 끄기와 정지는 Kubernetes만으로 된다. 대상 목록은 빌드할 때 실행 파일에 들어가 GitHub·네트워크에 기대지 않는다.
// 감독 상태는 kubectl exec로 읽어 쓰기로 판정되므로 --apply에서만 나온다.
import { defineCommand, type OliveAdminOutcome, type OliveSupervisorMissing, type OliveSupervisorTarget, type ReadCtx, type WriteCtx } from "../core/command";
import { oliveTargets } from "../core/names";
import { UsageError } from "../core/result";
import { LIMITS, anyUnread, countPods, lockSummary, podWords, readAll, runAction, targetLine, type Action, type Limits, type Outcome, type TargetView } from "./olive-state";
import { stopOff, stopOn, stopStatus, stopVerify } from "./olive-stop";

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const UIDS = new RegExp(`${UUID}(,${UUID})*`);

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
  const lines = [sup.line, ...(verbose ? views.map(targetLine) : [])];
  const summary = `${locks.words}, ${podWords(countPods(views))}`;
  if (anyUnread(views)) return { status: "failed", label: "읽지 못함", headline: `확인 실패: 읽지 못한 대상이 있다. ${summary}`, lines: [sup.line, ...views.map(targetLine)], next: "kubectl 접속을 확인한 뒤 다시: homelab olive status" };
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

// 자물쇠가 조금이라도 있거나 읽지 못하면 켜지 않는다. 풀기는 stop off의 일이다.
function startRefused(views: TargetView[]): Outcome | null {
  const word = { same: "걸림", different: "같은 이름의 다른 quota", deleting: "지우는 중", unread: "읽지 못함" };
  const spots = views.flatMap((v) => (v.lock === "absent" ? [] : [`${v.target.namespace}(${word[v.lock]})`]));
  if (spots.length === 0) return null;
  return { status: "failed", label: "켜지 않음", headline: `켜지 않음: 정지 중이다(${spots.join(", ")})`, lines: [], next: "정지를 풀려면: homelab olive stop off --apply" };
}

function startApply(w: WriteCtx, limits: Limits, verbose: boolean): Outcome {
  const views = readAll(w, oliveTargets());
  const refused = startRefused(views);
  if (refused) return refused;
  const startable = views.filter((v) => v.target.start);
  const present = startable.filter((v) => v.deployment.state === "present");
  const lines = [...startable.filter((v) => v.deployment.state !== "present").map((v) => `${v.target.id}: Deployment ${v.deployment.state === "absent" ? "없음" : "읽지 못함"}`), ...(verbose ? views.map(targetLine) : [])];
  if (present.length === 0) return { status: "failed", label: "켤 대상 없음", headline: "켜지 않음: 켤 수 있는 Deployment가 없다", lines, next: "homelab olive status --verbose로 대상을 확인한다" };
  const failed: string[] = [];
  const notReady: string[] = [];
  for (const v of present) {
    try {
      if (v.deployment.state === "present" && v.deployment.replicas !== 1) w.olive.setReplicas(v.target.namespace, v.target.deployment, 1);
    } catch {
      failed.push(v.target.id);
      continue;
    }
    try {
      if (!w.k8s.rolloutStatus(v.target.namespace, v.target.deployment, limits.startReadySec)) notReady.push(v.target.id);
    } catch {
      notReady.push(v.target.id);
    }
  }
  if (failed.length) return { status: "failed", label: "켜기 실패", headline: `켜기 실패: ${failed.join(", ")}에 replicas 1을 쓰지 못했다`, lines, next: "원인을 고친 뒤 다시: homelab olive start --apply" };
  const unread = startable.filter((v) => v.deployment.state === "unread").map((v) => v.target.id);
  if (unread.length) return { status: "failed", label: "일부 확인 실패", headline: `일부만 켰다: ${unread.join(", ")}의 Deployment를 읽지 못했다`, lines, next: "kubectl 접속을 확인한 뒤 다시: homelab olive start --apply" };
  if (notReady.length) return { status: "waiting", label: "준비 대기", headline: `replicas 1을 썼지만 ${limits.startReadySec}초 안에 준비되지 않았다: ${notReady.join(", ")}`, lines, next: "homelab olive status --verbose로 확인한다" };
  return { status: "done", label: "켜짐", headline: `켜짐: ${present.map((v) => v.target.id).join(", ")}`, lines, next: null };
}

function startAction(limits: Limits, verbose: boolean): Action {
  return {
    command: "olive start",
    target: "올리브 켜기",
    plan(c) {
      const views = readAll(c, oliveTargets());
      const refused = startRefused(views);
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
        "올리브의 상태를 보고, 켜고, 비상 정지를 걸고 풉니다. 바꾸는 동작은 --apply가 있어야 실행합니다. 감독 상태 줄도 kubectl exec로 읽어 --apply에서만 나옵니다. 종료 코드는 0 완료, 1 실패·차단 미완, 3 대기, 64 사용법입니다.",
      examples: ["homelab olive status", "homelab olive stop on --apply", "homelab olive stop verify"],
      actions: [
        { name: "status", about: "정지 여부·replicas·자물쇠·실행 파드 보기" },
        { name: "start", about: "켤 수 있는 대상만 켜기(정지 중이면 거절)" },
        { name: "stop", target: "on", about: "비상 정지 걸기" },
        { name: "stop", target: "status", about: "정지 상태 보기" },
        { name: "stop", target: "verify", about: "실행 파드 소멸 확인" },
        { name: "stop", target: "off", about: "비상 정지 풀기(현관이 없어 끝나지 않음)" },
      ],
    },
    kind: "change",
    args: [
      { name: "action", required: true, help: "동작(아래 동작 목록)", pattern: /status|start|stop/ },
      { name: "sub", required: false, help: "stop의 동작(on, status, verify, off)", pattern: /on|status|verify|off/ },
    ],
    flags: [
      { name: "verbose", kind: "bool", help: "대상별 줄까지 보기" },
      { name: "deep", kind: "bool", help: "런타임 대조(stop verify 전용, 아직 없어 실패로 끝남)" },
      { name: "uids", kind: "value", valueName: "UID,UID", help: "stop on이 알려 준 파드 UID(stop verify 전용)", pattern: UIDS },
    ],
    async run(ctx, input) {
      const action = input.args.action as string;
      const sub = input.args.sub;
      const verbose = input.flags.verbose === true;
      const deep = input.flags.deep === true;
      const uids = typeof input.flags.uids === "string" ? input.flags.uids.split(",") : [];
      if (action === "stop" && sub === undefined) throw new UsageError("stop 뒤에 on, status, verify, off 중 하나를 준다");
      if (action !== "stop" && sub !== undefined) throw new UsageError(`${action}에는 뒤 인자를 주지 않는다`);
      const verifying = action === "stop" && sub === "verify";
      if ((deep || uids.length > 0) && !verifying) throw new UsageError("--deep과 --uids는 stop verify에만 쓴다");
      if (action === "stop" && (sub === "status" || sub === "verify") && input.apply) throw new UsageError(`stop ${sub}는 읽기 동작이라 --apply를 받지 않는다`);
      // 낮은 단계의 확인을 --deep의 결과처럼 내지 않는다. 런타임 목록을 sudo 없이 읽는 길이 정해지기 전에는 실패로 끝낸다.
      if (deep) {
        return runAction(ctx, {
          command: "olive stop verify",
          target: "올리브 정지 확인",
          title: "homelab olive stop verify --deep",
          plan: () => ({ status: "failed", label: "런타임 대조 없음", headline: "확인 실패: 런타임 대조는 아직 없다. 아무것도 확인하지 않았다", lines: [], next: "노드 단계까지 보려면: homelab olive stop verify" }),
        });
      }
      if (action === "status") return runAction(ctx, statusAction(verbose));
      if (action === "start") return runAction(ctx, startAction(limits, verbose));
      if (sub === "on") return runAction(ctx, stopOn(limits, verbose));
      if (sub === "status") return runAction(ctx, stopStatus(verbose));
      if (sub === "verify") return runAction(ctx, stopVerify(uids, verbose));
      return runAction(ctx, stopOff(limits, verbose));
    },
  });
}

export default makeOlive();
