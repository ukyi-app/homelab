// homelab olive stop on|status|verify. 순서와 증거의 이름은 supervisor.md 7.3·7.4절을 따른다.
// 접수·차단·replicas·소멸을 따로 말한다. 현관과 감독의 종료 지시는 아직 상대가 없어 하지 못한 것으로 보고한다.
// 끝 상태는 그 실행이 마지막에 읽은 것으로만 정한다. 읽지 못한 것은 미상이고, 미상이 있으면 정지됨과 0을 내지 않는다.
// 소멸 확인은 Kubernetes에서 보는 기본 단계뿐이다. 노드에서의 확인과 런타임 대조는 이 CLI에 없어 "노드 미확인"이라고 말한다.
import type { HoldZero, WriteCtx } from "../core/command";
import type { Status } from "../core/result";
import { type PodCount, INTAKE_UNKNOWN, INTAKE_UNREACHED, anyUnread, countPods, forcedPods, lockSummary, podWords, readAll, replicasWords, stopTargets, targetLine, uniqueNamespaces, unreadWhy, type Action, type Limits, type Outcome, type TargetView } from "./olive-state";

const NO_SUPERVISOR_ORDER = "권한 폐기·실행 종료 지시: 하지 못함. CLI가 감독에게 시킬 길이 없어 replicas 0으로 파드를 내린다";
const VERIFY_SCOPE = "확인 범위: Kubernetes에서 본 파드 소멸까지다. replicas가 0으로 유지되는지는 보지 않는다(stop on이 지켜본다). 노드에서의 확인은 이 CLI에 아직 없다";
const NO_SPACES = "확인할 네임스페이스가 하나도 없다";
const CHECK_SPACES = "대상 목록과 클러스터를 확인한다";
const STOP_AGAIN = "homelab olive stop on --apply";
// 강제 삭제는 kubelet의 종료 확인 없이 API에서 파드를 지운다. 기다리거나 다시 읽어도 종료의 증거가 생기지 않는다.
const FORCED_NEXT = "강제 삭제된 파드가 있었다. Kubernetes의 목록만으로는 프로세스의 종료를 알 수 없고 이 CLI에는 아직 노드에서의 확인이 없다. 노드에서 직접 확인한다";

const verboseLines = (views: TargetView[], verbose: boolean) => (verbose ? views.map(targetLine) : []);
const applicationOf = (declaredBy: string) => /^platform\/([a-z0-9-]+)$/.exec(declaredBy)?.[1] ?? null;
const applicationsOf = (views: TargetView[]) => [...new Set(views.map((v) => applicationOf(v.target.declaredBy)).filter((a): a is string => a !== null))];

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

type Space = { ns: string; state: "gone" | "held" | "open" | "unread"; lock?: TargetView["lock"] };

// 네임스페이스마다 마지막으로 읽은 자물쇠. 네임스페이스나 자물쇠를 읽지 못한 곳은 걸렸다고도 없다고도 하지 않는다.
function spacesOf(views: TargetView[]): Space[] {
  return [...new Set(views.map((v) => v.target.namespace))].map((ns) => {
    const seen = views.filter((v) => v.target.namespace === ns);
    if (seen.every((v) => v.namespace === "absent")) return { ns, state: "gone" };
    if (seen.some((v) => v.namespace === "unread" || v.lock === "unread")) return { ns, state: "unread" };
    const open = seen.find((v) => v.lock !== "same");
    return open ? { ns, state: "open", lock: open.lock } : { ns, state: "held" };
  });
}

function spotWord(s: Space, attempted: LockResult[]): string {
  if (s.lock === "different" || s.lock === "deleting") return LOCK_FAIL_WORD[s.lock];
  return attempted.find((l) => l.ns === s.ns)?.state === "locked" ? "다시 읽으니 걸려 있지 않다" : LOCK_FAIL_WORD.failed;
}

function valueOf(v: TargetView): string {
  const d = v.deployment;
  return d.state === "present" && d.replicas !== null ? `replicas ${d.replicas}` : "읽지 못함";
}

// 마지막 읽기에서 0이 아니거나 읽지 못한 대상. 없는 Deployment는 내릴 것이 없다.
function replicasLeft(views: TargetView[]): string[] {
  return views.flatMap((v) => {
    const d = v.deployment;
    if (d.state === "absent" || (d.state === "present" && d.replicas === 0)) return [];
    return [`${v.target.id}(${valueOf(v)})`];
  });
}

// 지켜보기가 마지막으로 0을 확인하지 못한 대상과 그 값. 끝낼 때 다시 읽어 0이었으면 그것도 적는다.
// 끝낼 때의 0은 한 번 읽은 값이라 동기화가 다시 1을 쓰지 않는다는 증거가 아니다.
function unsettledOf(hold: HoldZero | null, scaled: TargetView[], after: TargetView[]): string[] {
  return (hold?.targets ?? [])
    .filter((t) => t.last !== 0)
    .flatMap((t) => {
      const value = t.last === "unread" ? "읽지 못함" : t.last === "absent" ? "사라짐" : `replicas ${t.last}`;
      return scaled
        .filter((v) => v.target.namespace === t.ns && v.target.deployment === t.deployment)
        .map((v) => {
          const end = after.find((a) => a.target.id === v.target.id)?.deployment;
          return `${v.target.id}(${value}${end?.state === "present" && end.replicas === 0 ? ", 끝낼 때 다시 읽은 값은 0" : ""})`;
        });
    });
}

type ReplicasSeen = { hold: HoldZero | null; watched: boolean; seen: boolean; unsettled: string[]; left: string[]; fresh: string[]; writeFailed: string[] };

function holdWords(r: ReplicasSeen): string {
  if (r.left.length === 0 && r.fresh.length === 0 && (!r.watched || r.hold?.result === "zero")) return r.seen ? "replicas: 0 확인" : "replicas: 대상 Deployment 없음";
  const parts = [
    ...(r.unsettled.length ? [`지켜보기에서 마지막으로 0을 확인하지 못한 대상 ${r.unsettled.join(", ")}`] : []),
    ...(r.left.length ? [`끝낼 때 0을 확인하지 못한 대상 ${r.left.join(", ")}`] : []),
    ...(r.fresh.length ? [`처음 읽을 때 없던 대상 ${r.fresh.join(", ")}: 이번 실행이 내리지도 지켜보지도 않았다`] : []),
    ...(r.writeFailed.length ? [`쓰기 실패 ${r.writeFailed.join(", ")}`] : []),
    ...(r.hold?.syncing.length ? [`동기화 중 ${r.hold.syncing.join(", ")}`] : []),
    ...(r.hold?.unreadApps.length ? [`읽지 못한 Application ${r.hold.unreadApps.join(", ")}`] : []),
    ...(r.hold?.missingApps.length ? [`없어진 Application ${r.hold.missingApps.join(", ")}`] : []),
  ];
  const why = parts.length ? parts.join(", ") : r.watched && r.hold === null ? "지켜보기를 끝내지 못했다" : "상한 안에 0 유지를 확인하지 못했다";
  return `replicas: 미확정(${why}). 자물쇠는 그대로 둔다`;
}

type Evidence = { spaces: number; blockOk: boolean; lockUnread: boolean; forcedSeen: number; pods: PodCount; replicasOk: boolean };

// 앞의 조건이 먼저다. 자물쇠를 못 건 것은 파드 수와 상관없이 차단 미완이다.
function stopVerdict(e: Evidence): { status: Status; label: string } {
  if (e.spaces === 0) return { status: "failed", label: "확인 실패" };
  if (!e.blockOk) return { status: "failed", label: e.lockUnread ? "차단 미확정" : "차단 미완" };
  if (e.pods.forced > 0) return { status: "failed", label: "강제 삭제 중, 소멸 확인 불가" };
  // 강제 삭제된 파드는 API에서 사라져도 종료의 증거가 아니다. 기다려도 증거가 생기지 않는다.
  if (e.forcedSeen > 0) return { status: "failed", label: "강제 삭제를 봤다, 소멸 확인 불가" };
  if (!e.replicasOk) return { status: "waiting", label: "차단됨, replicas 미확정" };
  if (e.pods.live > 0 || e.pods.unread > 0 || e.pods.blind > 0) return { status: "waiting", label: "차단됨, 소멸 확인 전" };
  return { status: "done", label: "정지됨(노드 미확인)" };
}

function stopOnApply(w: WriteCtx, limits: Limits, verbose: boolean): Outcome {
  const before = readAll(w, stopTargets());

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
    const apps = applicationsOf(scaled).filter((app) => {
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
  const spaces = spacesOf(after);
  const present = spaces.filter((s) => s.state !== "gone");
  const held = spaces.filter((s) => s.state === "held").length;
  const open = spaces.filter((s) => s.state === "open");
  const unread = spaces.filter((s) => s.state === "unread");
  const blockOk = present.length > 0 && held === present.length;

  const pods = countPods(after);
  // 처음 읽을 때 없던 Deployment는 이번 실행이 내리지도, 그 Application과 함께 지켜보지도 않았다.
  // 끝낼 때 읽은 0은 그 순간의 값이라 동기화가 끝난 뒤에도 0이라는 근거가 없다. 다음 실행은 처음부터 그 대상을 넣는다.
  const watched = new Set(scaled.map((v) => v.target.id));
  const fresh = after.filter((v) => v.deployment.state !== "absent" && !watched.has(v.target.id));
  const left = replicasLeft(after.filter((v) => watched.has(v.target.id)));
  const replicasOk = (scaled.length === 0 || hold?.result === "zero") && left.length === 0 && fresh.length === 0;
  // 파드가 API에서 사라지면 강제 삭제 표식도 다시 알 수 없어 이 실행에서 본 것을 끝까지 들고 간다.
  const forced = forcedPods([...before, ...after]);
  const { status, label } = stopVerdict({ spaces: present.length, blockOk, lockUnread: open.length === 0 && unread.length > 0, forcedSeen: forced.length, pods, replicasOk });

  const gone = spaces.length - present.length;
  const blockLine = `차단: 자물쇠 ${held}/${present.length}곳 걸림${gone > 0 ? `, 없는 네임스페이스 ${gone}곳` : ""}${open.length ? `, 못 건 곳 ${open.map((s) => `${s.ns}(${spotWord(s, locks)})`).join(", ")}` : ""}${unread.length ? `, 확인하지 못한 곳 ${unread.map((s) => `${s.ns}(자물쇠를 읽지 못했다)`).join(", ")}` : ""}`;
  const seenDeployment = after.some((v) => v.deployment.state !== "absent");
  const rezeroFailed = (hold?.targets ?? []).filter((t) => t.writeFailed > 0).flatMap((t) => scaled.filter((v) => v.target.namespace === t.ns && v.target.deployment === t.deployment).map((v) => v.target.id));
  const replicasLine = holdWords({
    hold,
    watched: scaled.length > 0,
    seen: seenDeployment,
    unsettled: unsettledOf(hold, scaled, after),
    left,
    fresh: fresh.map((v) => `${v.target.id}(${valueOf(v)})`),
    writeFailed: [...new Set([...writeFailed, ...rezeroFailed])],
  });
  const forcedLine = forced.length ? [`강제 삭제를 본 파드: ${forced.join(", ")}`] : [];

  const lockNext = open.length ? `못 건 곳의 원인을 고친 뒤 다시: ${STOP_AGAIN}` : `kubectl 접속을 확인한 뒤 다시: ${STOP_AGAIN}`;
  const podsNext = pods.blind > 0 ? "파드를 식별할 수 없는 대상의 Deployment를 확인한 뒤: homelab olive stop verify" : "잠시 뒤 확인: homelab olive stop verify";
  const next =
    present.length === 0 ? CHECK_SPACES : !blockOk ? (forced.length ? `${lockNext}. ${FORCED_NEXT}` : lockNext) : forced.length ? FORCED_NEXT : !replicasOk ? `미확정 대상을 다시 내린다: ${STOP_AGAIN}` : status === "waiting" ? podsNext : null;
  const replicasWord = replicasOk ? (seenDeployment ? "replicas 0" : "대상 Deployment 없음") : "replicas 미확정";
  return {
    status,
    label,
    headline: present.length === 0 ? `${label}: ${NO_SPACES}. 접수 닿지 못함` : `${label}: 접수 닿지 못함, 자물쇠 ${held}/${present.length}곳, ${replicasWord}, ${podWords(pods)}`,
    lines: [INTAKE_UNREACHED, blockLine, NO_SUPERVISOR_ORDER, replicasLine, `소멸: ${podWords(pods)}`, ...forcedLine, ...verboseLines(after, verbose)],
    next,
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
        headline: `계획: 접수 닿지 못함. 자물쇠 ${spaces}곳을 먼저 걸고 있는 Deployment를 replicas 0으로 내린 뒤 ${limits.holdZeroSec}초까지 지켜본다`,
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
      if (anyUnread(views)) return { status: "failed", label: "읽지 못함", headline: `확인 실패: ${unreadWhy(views)}. ${locks.words}, ${pods}`, lines: views.map(targetLine), next: "kubectl 접속과 대상의 Deployment를 확인한 뒤 다시: homelab olive stop status" };
      const state = locks.held === 0 ? "정지 아님" : locks.held === locks.present ? "정지 중" : "일부만 정지";
      return { status: "same", label: state, headline: `${state}: ${locks.words}, ${pods}`, lines: [INTAKE_UNKNOWN, replicasWords(views), ...verboseLines(views, verbose)], next: null };
    },
  };
}

export function stopVerify(verbose: boolean): Action {
  return {
    command: "olive stop verify",
    target: "올리브 정지 확인",
    title: "homelab olive stop verify",
    plan(c) {
      const views = readAll(c, stopTargets());
      const locks = lockSummary(views);
      const pods = countPods(views);
      const forced = forcedPods(views);
      const raised = views.filter((v) => v.deployment.state === "present" && (v.deployment.replicas ?? 0) > 0);
      // 자물쇠가 걸려 있다고 읽은 대상만 "새 파드만 막고 있다"고 말한다.
      const blocked = raised.filter((v) => v.lock === "same").map((v) => v.target.id);
      const raisedLine = raised.length ? [`주의: replicas가 0이 아닌 대상 ${raised.map((v) => v.target.id).join(", ")}${blocked.length ? `. 이 가운데 ${blocked.join(", ")}는 자물쇠가 새 파드만 막고 있다` : ""}. 내리려면: ${STOP_AGAIN}`] : [];
      const forcedLine = forced.length ? [`강제 삭제 중인 파드: ${forced.join(", ")}`] : [];
      const base = [INTAKE_UNKNOWN, `차단: ${locks.words}`, replicasWords(views), VERIFY_SCOPE, ...raisedLine, `소멸: ${podWords(pods)}`, ...forcedLine, ...verboseLines(views, verbose)];
      const fail = (label: string, why: string, next: string): Outcome => ({ status: "failed", label, headline: `${label}: ${why}`, lines: base, next: forced.length && next !== FORCED_NEXT ? `${next}. ${FORCED_NEXT}` : next });
      if (anyUnread(views)) return fail("확인 실패", unreadWhy(views), "kubectl 접속과 대상의 Deployment를 확인한 뒤 다시 실행한다");
      if (locks.present === 0) return fail("확인 실패", NO_SPACES, CHECK_SPACES);
      if (locks.held < locks.present) return fail("차단 미완", `자물쇠가 ${locks.present - locks.held}곳에 걸려 있지 않다`, STOP_AGAIN);
      if (pods.forced > 0) return fail("확인 실패", `강제 삭제 중인 파드 ${pods.forced}개. API에서 사라져도 종료의 증거가 아니다`, FORCED_NEXT);
      if (pods.live > 0) return { status: "waiting", label: "종료 대기", headline: `종료 대기: ${podWords(pods)}`, lines: base, next: "잠시 뒤 다시: homelab olive stop verify" };
      return { status: "same", label: "정지됨(노드 미확인)", headline: `정지됨(노드 미확인): ${locks.words}, ${podWords(pods)}`, lines: base, next: null };
    },
  };
}
