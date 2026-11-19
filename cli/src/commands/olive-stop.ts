// homelab olive stop on|status|verify|off. 순서와 증거의 이름은 supervisor.md 7.3·7.4·7.6절을 따른다.
// 접수·차단·replicas·소멸을 따로 말한다. 현관과 감독의 종료 지시는 아직 상대가 없어 하지 못한 것으로 보고한다.
import type { HoldZero, ReadCtx, WriteCtx } from "../core/command";
import type { Status } from "../core/result";
import { type PodCount, INTAKE_UNKNOWN, INTAKE_UNREACHED, anyUnread, countPods, lockSummary, podWords, readAll, replicasWords, stopTargets, targetLine, uniqueNamespaces, type Action, type Limits, type Outcome, type TargetView } from "./olive-state";

const NO_SUPERVISOR_ORDER = "권한 폐기·실행 종료 지시: 하지 못함. CLI가 감독에게 시킬 길이 없어 replicas 0으로 파드를 내린다";
const OFF_UNCHECKED = "풀기 전 확인: 정책 revision과 확정되지 않은 외부 효과는 볼 상대가 없어 확인하지 못했다";
const OFF_UNFINISHED = "남은 일: 새 실행 세대 적기와 현관의 접수 열기는 현관·감독의 진입점이 없어 하지 못했다";

const verboseLines = (views: TargetView[], verbose: boolean) => (verbose ? views.map(targetLine) : []);
const applicationOf = (declaredBy: string) => /^platform\/([a-z0-9-]+)$/.exec(declaredBy)?.[1] ?? null;

type LockResult = { ns: string; state: "locked" | "absent" | "different" | "deleting" | "failed" };

function setLock(w: WriteCtx, ns: string): LockResult["state"] {
  try {
    const r = w.olive.stopLockSet(ns);
    return r === "created" || r === "same" ? "locked" : r;
  } catch {
    // 시간 초과면 걸렸을 수 있다. 다시 읽어 걸린 것만 걸렸다고 한다.
    try {
      return w.olive.stopLock(ns) === "same" ? "locked" : "failed";
    } catch {
      return "failed";
    }
  }
}

const LOCK_FAIL_WORD: Record<string, string> = { different: "다른 모양의 quota가 있다", deleting: "지우는 중이다", failed: "걸지 못했다" };

function holdWords(hold: HoldZero | null, held: boolean, writeFailed: string[]): string {
  if (!held) return "replicas: 대상 Deployment 없음";
  if (hold?.result === "zero") return "replicas: 0 확인";
  const parts = [...(writeFailed.length ? [`쓰기 실패 ${writeFailed.join(", ")}`] : []), ...(hold?.syncing.length ? [`동기화 중 ${hold.syncing.join(", ")}`] : []), ...(hold?.unreadApps.length ? [`읽지 못한 Application ${hold.unreadApps.join(", ")}`] : [])];
  return `replicas: 미확정${parts.length ? `(${parts.join(", ")})` : ""}. 자물쇠는 그대로 둔다`;
}

// 앞의 조건이 먼저다. 자물쇠를 못 건 것은 파드 수와 상관없이 차단 미완이다.
function stopVerdict(blockOk: boolean, pods: PodCount, replicasOk: boolean): { status: Status; label: string } {
  if (!blockOk) return { status: "failed", label: "차단 미완" };
  if (pods.forced > 0) return { status: "failed", label: "강제 삭제 중, 소멸 확인 불가" };
  if (!replicasOk) return { status: "waiting", label: "차단됨, replicas 미확정" };
  if (pods.live > 0 || pods.unread > 0) return { status: "waiting", label: "차단됨, 소멸 확인 전" };
  return { status: "done", label: "정지됨(노드 미확인)" };
}

function stopOnApply(w: WriteCtx, limits: Limits, verbose: boolean): Outcome {
  const before = readAll(w, stopTargets());
  // 파드가 API에서 사라지면 UID를 다시 알 수 없어 내리기 전에 적어 둔다.
  const uids = [...new Set(before.flatMap((v) => (v.pods ?? []).map((p) => p.uid)))];

  // 자물쇠를 replicas보다 먼저 건다. Argo CD가 읽어 둔 1을 늦게 다시 써도 파드가 생기지 못한다.
  const locks: LockResult[] = uniqueNamespaces(before).map((v) => ({ ns: v.target.namespace, state: v.namespace === "absent" ? "absent" : setLock(w, v.target.namespace) }));

  const scaled = before.filter((v) => v.deployment.state !== "absent");
  const writeFailed: string[] = [];
  for (const v of scaled) {
    try {
      w.olive.setReplicas(v.target.namespace, v.target.deployment, 0);
    } catch {
      writeFailed.push(v.target.id);
    }
  }

  let hold: HoldZero | null = null;
  if (scaled.length > 0) {
    // 없는 Application을 넘기면 holdZero가 끝까지 미확정이다. 읽지 못한 것은 넘겨 미확정으로 남긴다.
    const apps = [...new Set(scaled.map((v) => applicationOf(v.target.declaredBy)).filter((a): a is string => a !== null))].filter((app) => {
      try {
        return w.olive.appOperation(app) !== null;
      } catch {
        return true;
      }
    });
    try {
      hold = w.olive.holdZero({ targets: scaled.map((v) => ({ ns: v.target.namespace, deployment: v.target.deployment })), apps, timeoutSec: limits.holdZeroSec });
    } catch {
      hold = null;
    }
  }

  const after = readAll(w, stopTargets());
  const lockFailed = locks.filter((l) => l.state !== "locked" && l.state !== "absent");
  const reopened = uniqueNamespaces(after).filter((v) => v.namespace !== "absent" && (v.lock === "absent" || v.lock === "different" || v.lock === "deleting") && !lockFailed.some((l) => l.ns === v.target.namespace));
  const held = locks.filter((l) => l.state === "locked").length;
  const pods = countPods(after);
  const replicasOk = scaled.length === 0 || hold?.result === "zero";
  const blockOk = lockFailed.length === 0 && reopened.length === 0;

  const failedSpots = [...lockFailed.map((l) => `${l.ns}(${LOCK_FAIL_WORD[l.state]})`), ...reopened.map((v) => `${v.target.namespace}(다시 읽으니 걸려 있지 않다)`)];
  const blockLine = `차단: 자물쇠 ${held}곳 걸림${locks.length - held - lockFailed.length > 0 ? `, 없는 네임스페이스 ${locks.length - held - lockFailed.length}곳` : ""}${failedSpots.length ? `, 못 건 곳 ${failedSpots.join(", ")}` : ""}`;
  const goneLine = `소멸: ${podWords(pods)}`;
  const replicasLine = holdWords(hold, scaled.length > 0, writeFailed);
  const { status, label } = stopVerdict(blockOk, pods, replicasOk);

  const verify = `homelab olive stop verify${uids.length ? ` --uids ${uids.join(",")}` : ""}`;
  const uidGap = before.filter((v) => v.pods === null).length;
  const uidLine = uidGap > 0 ? [`파드 UID: 내리기 전에 읽지 못한 대상 ${uidGap}곳은 노드 확인에 들지 않는다`] : [];
  return {
    status,
    label,
    headline: `${label}: 접수 닿지 못함, 자물쇠 ${held}곳, ${replicasOk ? "replicas 0" : "replicas 미확정"}, ${podWords(pods)}`,
    lines: [INTAKE_UNREACHED, blockLine, NO_SUPERVISOR_ORDER, replicasLine, goneLine, ...uidLine, ...verboseLines(after, verbose)],
    next: status === "failed" && !blockOk ? "못 건 곳의 원인을 고친 뒤 다시: homelab olive stop on --apply" : verify,
  };
}

export function stopOn(limits: Limits, verbose: boolean): Action {
  return {
    command: "olive stop on",
    target: "올리브 비상 정지",
    plan(c) {
      const views = readAll(c, stopTargets());
      const spaces = uniqueNamespaces(views).filter((v) => v.namespace !== "absent").length;
      return {
        status: "pending",
        label: "자물쇠를 걸고 replicas를 0으로 내린다",
        headline: `계획: 자물쇠 ${spaces}곳을 먼저 걸고 있는 Deployment를 replicas 0으로 내린 뒤 ${limits.holdZeroSec}초까지 지켜본다`,
        lines: [INTAKE_UNREACHED, NO_SUPERVISOR_ORDER, ...verboseLines(views, verbose)],
      };
    },
    apply: (w) => stopOnApply(w, limits, verbose),
  };
}

export function stopStatus(verbose: boolean): Action {
  return {
    command: "olive stop status",
    target: "올리브 정지 상태",
    title: "homelab olive stop status",
    plan(c) {
      const views = readAll(c, stopTargets());
      const locks = lockSummary(views);
      const pods = podWords(countPods(views));
      if (anyUnread(views)) return { status: "failed", label: "읽지 못함", headline: `확인 실패: 읽지 못한 대상이 있다. ${locks.words}, ${pods}`, lines: views.map(targetLine), next: "kubectl 접속을 확인한 뒤 다시: homelab olive stop status" };
      const state = locks.held === 0 ? "정지 아님" : locks.held === locks.present ? "정지 중" : "일부만 정지";
      return { status: "same", label: state, headline: `${state}: ${locks.words}, ${pods}`, lines: [INTAKE_UNKNOWN, replicasWords(views), ...verboseLines(views, verbose)], next: null };
    },
  };
}

function verifyNode(c: ReadCtx, uids: string[], base: string[]): Outcome {
  const basic = (reason: string): Outcome => ({ status: "same", label: "정지됨(노드 미확인)", headline: `정지됨(노드 미확인): ${reason}`, lines: base, next: null });
  const host = c.node.host();
  if (host.state === "not-node") return basic("이 기기는 클러스터 노드가 아니다");
  if (host.state === "unknown") return basic(`노드인지 확인하지 못했다(${host.reason})`);
  if (uids.length === 0) return basic("확인할 파드 UID가 없다. stop on이 알려 준 --uids를 붙이면 cgroup까지 본다");
  const seen = uids.map((uid) => ({ uid, state: c.node.podCgroup(uid) }));
  const list = (state: string) => seen.filter((s) => s.state === state).map((s) => s.uid);
  const lines = [...base, `노드 ${host.node}: 파드 cgroup ${seen.length}개 확인`];
  if (list("unreadable").length > 0) return { status: "failed", label: "확인 실패", headline: `확인 실패: cgroup을 읽지 못한 파드 ${list("unreadable").length}개`, lines: [...lines, `읽지 못함: ${list("unreadable").join(", ")}`], next: "노드에서 cgroup 경로를 확인한 뒤 다시 실행한다" };
  if (list("populated").length > 0) return { status: "waiting", label: "프로세스 남음", headline: `종료 대기: cgroup에 프로세스가 남은 파드 ${list("populated").length}개`, lines: [...lines, `남은 파드: ${list("populated").join(", ")}`], next: `잠시 뒤 다시: homelab olive stop verify --uids ${uids.join(",")}` };
  return { status: "same", label: "정지 완료(노드 확인)", headline: `정지 완료(노드 확인): 파드 cgroup ${seen.length}개가 비었거나 사라졌다`, lines, next: null };
}

export function stopVerify(uids: string[], verbose: boolean): Action {
  return {
    command: "olive stop verify",
    target: "올리브 정지 확인",
    title: "homelab olive stop verify",
    plan(c) {
      const views = readAll(c, stopTargets());
      const locks = lockSummary(views);
      const pods = countPods(views);
      const base = [INTAKE_UNKNOWN, `차단: ${locks.words}`, replicasWords(views), `소멸: ${podWords(pods)}`, ...verboseLines(views, verbose)];
      const fail = (label: string, why: string, next: string): Outcome => ({ status: "failed", label, headline: `${label}: ${why}`, lines: base, next });
      if (anyUnread(views)) return fail("확인 실패", "읽지 못한 대상이 있다", "kubectl 접속을 확인한 뒤 다시 실행한다");
      if (locks.present === 0) return fail("확인 실패", "확인할 네임스페이스가 하나도 없다", "대상 목록과 클러스터를 확인한다");
      if (locks.held < locks.present) return fail("차단 미완", `자물쇠가 ${locks.present - locks.held}곳에 걸려 있지 않다`, "homelab olive stop on --apply");
      if (pods.forced > 0) return fail("확인 실패", `강제 삭제 중인 파드 ${pods.forced}개. API에서 사라져도 종료의 증거가 아니다`, "노드에서 그 파드의 cgroup을 확인한다");
      if (pods.live > 0) return { status: "waiting", label: "종료 대기", headline: `종료 대기: ${podWords(pods)}`, lines: base, next: "잠시 뒤 다시: homelab olive stop verify" };
      return verifyNode(c, uids, base);
    },
  };
}

// 되돌리기: 자물쇠를 먼저 걸고 올린 것을 내린다. 어디까지 되돌렸는지 그대로 적는다.
function rollback(w: WriteCtx, spaces: string[], raised: TargetView[]): { ok: boolean; lines: string[] } {
  const relocked = spaces.map((ns) => ({ ns, state: setLock(w, ns) }));
  const missed = relocked.filter((l) => l.state !== "locked").map((l) => l.ns);
  const lowered = raised.map((v) => {
    try {
      w.olive.setReplicas(v.target.namespace, v.target.deployment, 0);
      return { id: v.target.id, ok: true };
    } catch {
      return { id: v.target.id, ok: false };
    }
  });
  const stuck = lowered.filter((l) => !l.ok).map((l) => l.id);
  return {
    ok: missed.length === 0 && stuck.length === 0,
    lines: [
      missed.length ? `되돌림: 자물쇠를 다시 걸지 못한 곳 ${missed.join(", ")}` : `되돌림: 자물쇠 ${relocked.length}곳을 다시 걸었다`,
      ...(raised.length ? [stuck.length ? `되돌림: replicas 0으로 내리지 못한 대상 ${stuck.join(", ")}` : `되돌림: 올린 대상 ${lowered.length}개를 replicas 0으로 내렸다`] : []),
    ],
  };
}

function offFailed(why: string, back: { ok: boolean; lines: string[] }): Outcome {
  const end = back.ok ? "다시 정지 상태로 되돌렸다" : "되돌리기가 끝나지 않았다. 아래 줄의 대상을 손으로 확인한다";
  return { status: "failed", label: "풀기 실패", headline: `풀기 실패: ${why}. ${end}`, lines: back.lines, next: back.ok ? "원인을 고친 뒤 다시: homelab olive stop off --apply" : "homelab olive stop on --apply로 다시 정지한다" };
}

const noLocks = (views: TargetView[]) => !anyUnread(views) && views.every((v) => v.lock === "absent");

// 풀어도 되는지. 파드가 남았거나 읽지 못했으면 자물쇠를 지우지 않는다.
function offBlocked(views: TargetView[]): Outcome | null {
  const pods = countPods(views);
  const refuse = (why: string): Outcome => ({ status: "failed", label: "풀지 않음", headline: `풀지 않음: ${why}`, lines: views.map(targetLine), next: "homelab olive stop verify로 확인한 뒤 다시 실행한다" });
  if (anyUnread(views)) return refuse("읽지 못한 대상이 있어 실행 파드 0개를 확인하지 못했다");
  const other = views.filter((v) => v.lock === "different").map((v) => v.target.namespace);
  if (other.length) return refuse(`자물쇠가 아닌 같은 이름의 quota가 있다(${other.join(", ")})`);
  if (pods.live > 0) return refuse(`${podWords(pods)}. 실행 파드가 남아 있다`);
  return null;
}

const unfinished = (label: string, done: string[], views: TargetView[], verbose: boolean): Outcome => ({
  status: "waiting",
  label,
  headline: `${label}: 현관의 접수 열기가 끝나지 않았다`,
  lines: [...done, OFF_UNCHECKED, OFF_UNFINISHED, ...verboseLines(views, verbose)],
  next: "현관의 관리 진입점이 생긴 뒤 접수를 연다. 그 전까지 풀기는 끝나지 않는다",
});

function stopOffApply(w: WriteCtx, limits: Limits, verbose: boolean): Outcome {
  const views = readAll(w, stopTargets());
  if (noLocks(views)) return unfinished("자물쇠 없음", ["차단: 걸린 자물쇠가 없어 바꾸지 않았다"], views, verbose);
  const held = uniqueNamespaces(views).filter((v) => v.lock === "same" || v.lock === "deleting");
  const blocked = offBlocked(views);
  if (blocked) return blocked;

  // 되돌릴 때는 지운 곳만이 아니라 있는 네임스페이스 전부에 건다. 일부만 걸려 있던 정지도 온전한 정지로 돌아간다.
  const allSpaces = uniqueNamespaces(views).filter((v) => v.namespace !== "absent").map((v) => v.target.namespace);
  const cleared: string[] = [];
  for (const v of held) {
    const ns = v.target.namespace;
    let state: string;
    try {
      state = w.olive.stopLockClear(ns);
    } catch {
      state = "failed";
    }
    if (state === "deleted" || state === "absent") {
      cleared.push(ns);
      continue;
    }
    return offFailed(`${ns}의 자물쇠를 지우지 못했다`, rollback(w, allSpaces, []));
  }

  const raised: TargetView[] = [];
  const starting = views.filter((v) => v.target.start && v.deployment.state === "present");
  for (const v of starting) {
    try {
      raised.push(v);
      if (v.deployment.state === "present" && v.deployment.replicas !== 1) w.olive.setReplicas(v.target.namespace, v.target.deployment, 1);
      if (!w.k8s.rolloutStatus(v.target.namespace, v.target.deployment, limits.startReadySec)) throw new Error("not ready");
    } catch {
      return offFailed(`${v.target.id}가 ${limits.startReadySec}초 안에 준비되지 않았다`, rollback(w, allSpaces, raised));
    }
  }
  const up = starting.length ? `켜기: ${starting.map((v) => v.target.id).join(", ")} 준비됨` : "켜기: 켤 수 있는 Deployment가 없다";
  return unfinished("자물쇠 풀림, 풀기 미완", [`차단: 자물쇠 ${cleared.length}곳을 지웠다`, up], readAll(w, stopTargets()), verbose);
}

export function stopOff(limits: Limits, verbose: boolean): Action {
  return {
    command: "olive stop off",
    target: "올리브 정지 풀기",
    plan(c) {
      const views = readAll(c, stopTargets());
      if (noLocks(views)) return { status: "pending", label: "걸린 자물쇠가 없다", headline: "계획: 걸린 자물쇠가 없어 바꾸는 것이 없다. 현관의 접수 열기는 끝나지 않아 3으로 끝난다", lines: [OFF_UNCHECKED, OFF_UNFINISHED, ...verboseLines(views, verbose)] };
      const blocked = offBlocked(views);
      if (blocked) return blocked;
      const names = views.filter((v) => v.target.start).map((v) => v.target.id);
      return { status: "pending", label: "자물쇠를 지우고 켤 수 있는 대상을 올린다", headline: `계획: 자물쇠를 지우고 ${names.join(", ")}를 올린다. 현관의 접수 열기는 끝나지 않아 3으로 끝난다`, lines: [OFF_UNCHECKED, OFF_UNFINISHED, ...verboseLines(views, verbose)] };
    },
    apply: (w) => stopOffApply(w, limits, verbose),
  };
}
