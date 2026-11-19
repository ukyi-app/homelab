// homelab olive stop on|status|verify|off. 순서와 증거의 이름은 supervisor.md 7.3·7.4·7.6절을 따른다.
// 접수·차단·replicas·소멸을 따로 말한다. 현관과 감독의 종료 지시는 아직 상대가 없어 하지 못한 것으로 보고한다.
// 끝 상태는 그 실행이 마지막에 읽은 것으로만 정한다. 읽지 못한 것은 미상이고, 미상이 있으면 정지됨과 0을 내지 않는다.
import type { HoldZero, ReadCtx, WriteCtx } from "../core/command";
import type { Status } from "../core/result";
import { type PodCount, INTAKE_UNKNOWN, INTAKE_UNREACHED, anyUnread, bringUp, countPods, forcedUids, lockSummary, podWords, readAll, readFailed, replicasWords, stopTargets, targetLine, uniqueNamespaces, unreadWhy, type Action, type Limits, type Outcome, type TargetView } from "./olive-state";

const NO_SUPERVISOR_ORDER = "권한 폐기·실행 종료 지시: 하지 못함. CLI가 감독에게 시킬 길이 없어 replicas 0으로 파드를 내린다";
const OFF_UNCHECKED = "풀기 전 확인: 정책 revision과 확정되지 않은 외부 효과는 볼 상대가 없어 확인하지 못했다";
const OFF_UNFINISHED = "남은 일: 새 실행 세대 적기와 현관의 접수 열기는 현관·감독의 진입점이 없어 하지 못했다";
const VERIFY_SCOPE = "확인 범위: 파드 소멸까지다. replicas가 0으로 유지되는지는 보지 않는다(stop on이 지켜본다)";
const NO_SPACES = "확인할 네임스페이스가 하나도 없다";
const CHECK_SPACES = "대상 목록과 클러스터를 확인한다";
const STOP_AGAIN = "homelab olive stop on --apply";

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

// 마지막 읽기에서 0이 아니거나 읽지 못한 대상. 없는 Deployment는 내릴 것이 없다.
function replicasLeft(views: TargetView[]): string[] {
  return views.flatMap((v) => {
    const d = v.deployment;
    if (d.state === "absent") return [];
    if (d.state === "unread" || d.replicas === null) return [`${v.target.id}(읽지 못함)`];
    return d.replicas > 0 ? [`${v.target.id}(replicas ${d.replicas})`] : [];
  });
}

function holdWords(hold: HoldZero | null, watched: boolean, seen: boolean, writeFailed: string[], left: string[]): string {
  if (left.length === 0 && (!watched || hold?.result === "zero")) return seen ? "replicas: 0 확인" : "replicas: 대상 Deployment 없음";
  const parts = [
    ...(left.length ? [`대상 ${left.join(", ")}`] : []),
    ...(writeFailed.length ? [`쓰기 실패 ${writeFailed.join(", ")}`] : []),
    ...(hold?.syncing.length ? [`동기화 중 ${hold.syncing.join(", ")}`] : []),
    ...(hold?.unreadApps.length ? [`읽지 못한 Application ${hold.unreadApps.join(", ")}`] : []),
    ...(hold?.missingApps.length ? [`없어진 Application ${hold.missingApps.join(", ")}`] : []),
  ];
  const why = parts.length ? parts.join(", ") : hold === null ? "지켜보기를 끝내지 못했다" : "상한 안에 0 유지를 확인하지 못했다";
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
  const left = replicasLeft(after);
  const replicasOk = (scaled.length === 0 || hold?.result === "zero") && left.length === 0;
  // 파드가 API에서 사라지면 UID도 강제 삭제 표식도 다시 알 수 없어 이 실행에서 본 것을 끝까지 들고 간다.
  const uids = [...new Set([...before, ...after].flatMap((v) => (v.pods ?? []).map((p) => p.uid)))];
  const forced = [...new Set(forcedUids([...before, ...after]))];
  const { status, label } = stopVerdict({ spaces: present.length, blockOk, lockUnread: open.length === 0 && unread.length > 0, forcedSeen: forced.length, pods, replicasOk });

  const gone = spaces.length - present.length;
  const blockLine = `차단: 자물쇠 ${held}/${present.length}곳 걸림${gone > 0 ? `, 없는 네임스페이스 ${gone}곳` : ""}${open.length ? `, 못 건 곳 ${open.map((s) => `${s.ns}(${spotWord(s, locks)})`).join(", ")}` : ""}${unread.length ? `, 확인하지 못한 곳 ${unread.map((s) => `${s.ns}(자물쇠를 읽지 못했다)`).join(", ")}` : ""}`;
  const seenDeployment = after.some((v) => v.deployment.state !== "absent");
  const rezeroFailed = (hold?.targets ?? []).filter((t) => t.writeFailed > 0).flatMap((t) => scaled.filter((v) => v.target.namespace === t.ns && v.target.deployment === t.deployment).map((v) => v.target.id));
  const replicasLine = holdWords(hold, scaled.length > 0, seenDeployment, [...new Set([...writeFailed, ...rezeroFailed])], left);
  const uidGap = before.filter((v) => v.pods === null).length;
  const uidLines = [...(uids.length ? [`파드 UID: 이 실행에서 본 ${uids.length}개 ${uids.join(",")}`] : []), ...(uidGap > 0 ? [`파드 UID: 내리기 전에 읽지 못한 대상 ${uidGap}곳의 UID는 이 목록에 없다`] : []), ...(forced.length ? [`강제 삭제를 본 파드 UID: ${forced.join(",")}`] : [])];

  const verify = uids.length ? `homelab olive stop verify --uids ${uids.join(",")}${uidGap > 0 ? ` (목록이 완전하지 않다: 내리기 전에 읽지 못한 대상 ${uidGap}곳이 빠졌다)` : ""}` : "homelab olive stop verify";
  const next = present.length === 0 ? CHECK_SPACES : !blockOk ? (open.length ? `못 건 곳의 원인을 고친 뒤 다시: ${STOP_AGAIN}` : `kubectl 접속을 확인한 뒤 다시: ${STOP_AGAIN}`) : forced.length ? `노드에서 강제 삭제된 파드의 cgroup을 확인한다: homelab olive stop verify --uids ${forced.join(",")}` : !replicasOk ? `미확정 대상을 다시 내린다: ${STOP_AGAIN}` : verify;
  const replicasWord = replicasOk ? (seenDeployment ? "replicas 0" : "대상 Deployment 없음") : "replicas 미확정";
  return {
    status,
    label,
    headline: present.length === 0 ? `${label}: ${NO_SPACES}. 접수 닿지 못함` : `${label}: 접수 닿지 못함, 자물쇠 ${held}/${present.length}곳, ${replicasWord}, ${podWords(pods)}`,
    lines: [INTAKE_UNREACHED, blockLine, NO_SUPERVISOR_ORDER, replicasLine, `소멸: ${podWords(pods)}`, ...uidLines, ...verboseLines(after, verbose)],
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

// 넘겨받은 UID가 이번 정지의 파드 전부라는 증거가 없어 지정한 UID의 관측까지만 말한다.
function verifyNode(c: ReadCtx, uids: string[], base: string[]): Outcome {
  const basic = (reason: string, lines = base): Outcome => ({ status: "same", label: "정지됨(노드 미확인)", headline: `정지됨(노드 미확인): ${reason}`, lines, next: null });
  const host = c.node.host();
  if (host.state === "not-node") return basic("이 기기는 클러스터 노드가 아니다");
  if (host.state === "unknown") return basic(`노드인지 확인하지 못했다(${host.reason})`);
  if (uids.length === 0) return basic("확인할 파드 UID가 없다. stop on이 알려 준 --uids를 붙이면 그 UID의 cgroup을 본다");
  const seen = [...new Set(uids)].map((uid) => ({ uid, state: c.node.podCgroup(uid) }));
  const list = (state: string) => seen.filter((s) => s.state === state).map((s) => s.uid);
  const lines = [...base, `노드 ${host.node}: 지정한 UID ${seen.length}개의 cgroup을 봤다`];
  if (list("unreadable").length > 0) return { status: "failed", label: "확인 실패", headline: `확인 실패: cgroup을 읽지 못한 파드 ${list("unreadable").length}개`, lines: [...lines, `읽지 못함: ${list("unreadable").join(", ")}`], next: "노드에서 cgroup 경로를 확인한 뒤 다시 실행한다" };
  if (list("populated").length > 0) return { status: "waiting", label: "프로세스 남음", headline: `종료 대기: cgroup에 프로세스가 남은 파드 ${list("populated").length}개`, lines: [...lines, `남은 파드: ${list("populated").join(", ")}`], next: `잠시 뒤 다시: homelab olive stop verify --uids ${uids.join(",")}` };
  return basic(`지정한 UID ${seen.length}개의 cgroup이 비었거나 사라졌다. 지정하지 않은 파드는 확인하지 않았다`, lines);
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
      const raised = views.filter((v) => v.deployment.state === "present" && (v.deployment.replicas ?? 0) > 0).map((v) => v.target.id);
      const raisedLine = raised.length ? [`주의: replicas가 0이 아닌 대상 ${raised.join(", ")}. 자물쇠가 새 파드만 막고 있다. 내리려면: ${STOP_AGAIN}`] : [];
      const base = [INTAKE_UNKNOWN, `차단: ${locks.words}`, replicasWords(views), VERIFY_SCOPE, ...raisedLine, `소멸: ${podWords(pods)}`, ...verboseLines(views, verbose)];
      const fail = (label: string, why: string, next: string): Outcome => ({ status: "failed", label, headline: `${label}: ${why}`, lines: base, next });
      if (anyUnread(views)) return fail("확인 실패", unreadWhy(views), "kubectl 접속과 대상의 Deployment를 확인한 뒤 다시 실행한다");
      if (locks.present === 0) return fail("확인 실패", NO_SPACES, CHECK_SPACES);
      if (locks.held < locks.present) return fail("차단 미완", `자물쇠가 ${locks.present - locks.held}곳에 걸려 있지 않다`, STOP_AGAIN);
      if (pods.forced > 0) return fail("확인 실패", `강제 삭제 중인 파드 ${pods.forced}개. API에서 사라져도 종료의 증거가 아니다`, "노드에서 그 파드의 cgroup을 확인한다");
      if (pods.live > 0) return { status: "waiting", label: "종료 대기", headline: `종료 대기: ${podWords(pods)}`, lines: base, next: "잠시 뒤 다시: homelab olive stop verify" };
      return verifyNode(c, uids, base);
    },
  };
}

type Rollback = { ok: boolean; raised: boolean; lines: string[] };

// 되돌리기: 자물쇠를 먼저 걸고 올린 것을 내린다. 한 일까지만 적는다. replicas 0은 요청이 접수된 것이고 파드의 소멸은 여기서 보지 않는다.
function rollback(w: WriteCtx, spaces: string[], raised: TargetView[]): Rollback {
  const relocked = spaces.map((ns) => ({ ns, state: setLock(w, ns) }));
  const locked = relocked.filter((l) => l.state === "locked").map((l) => l.ns);
  const missed = relocked.filter((l) => l.state !== "locked").map((l) => l.ns);
  const lowered = raised.map((v) => {
    try {
      w.olive.setReplicas(v.target.namespace, v.target.deployment, 0);
      return { id: v.target.id, ok: true };
    } catch {
      return { id: v.target.id, ok: false };
    }
  });
  const asked = lowered.filter((l) => l.ok).map((l) => l.id);
  const stuck = lowered.filter((l) => !l.ok).map((l) => l.id);
  return {
    ok: missed.length === 0 && stuck.length === 0,
    raised: raised.length > 0,
    lines: [
      ...(locked.length ? [`되돌림: 자물쇠를 다시 건 곳 ${locked.join(", ")}`] : []),
      ...(missed.length ? [`되돌림: 자물쇠를 다시 걸지 못한 곳 ${missed.join(", ")}`] : []),
      ...(asked.length ? [`되돌림: ${asked.join(", ")}에 replicas 0을 요청했다`] : []),
      ...(stuck.length ? [`되돌림: replicas 0을 요청하지 못한 대상 ${stuck.join(", ")}`] : []),
      "되돌림: 파드의 소멸은 확인하지 않았다",
    ],
  };
}

function offFailed(why: string, back: Rollback): Outcome {
  const end = back.ok ? `자물쇠를 다시 걸었다${back.raised ? ", 올린 대상에 replicas 0을 요청했다" : ""}. 파드 소멸은 확인하지 않았다` : "되돌리기가 끝나지 않았다. 아래 줄의 대상을 손으로 확인한다";
  return { status: "failed", label: "풀기 실패", headline: `풀기 실패: ${why}. ${end}`, lines: back.lines, next: `${STOP_AGAIN}로 다시 정지하고 소멸을 확인한다` };
}

const noLocks = (views: TargetView[]) => !readFailed(views) && views.every((v) => v.lock === "absent");

// 동기화가 끝났다고 확인하지 못한 Application. 진행 중인 동기화는 읽어 둔 1을 자물쇠가 풀린 뒤에 쓸 수 있다.
function unsettledApps(c: Pick<ReadCtx, "olive">, views: TargetView[]): { syncing: string[]; unread: string[] } {
  const syncing: string[] = [];
  const unread: string[] = [];
  for (const app of applicationsOf(views)) {
    try {
      if (c.olive.appOperation(app)?.inProgress) syncing.push(app);
    } catch {
      unread.push(app);
    }
  }
  return { syncing, unread };
}

// 풀어도 되는지. 파드가 남았거나 읽지 못했으면 자물쇠를 지우지 않는다.
function offBlocked(c: Pick<ReadCtx, "olive">, views: TargetView[]): Outcome | null {
  const pods = countPods(views);
  const refuse = (why: string, next = "homelab olive stop verify로 확인한 뒤 다시 실행한다"): Outcome => ({ status: "failed", label: "풀지 않음", headline: `풀지 않음: ${why}`, lines: views.map(targetLine), next });
  const stopFirst = `${STOP_AGAIN}로 0을 확인한 뒤 다시 실행한다`;
  // 켤 수 없는 대상은 자물쇠만 파드를 막고 있을 수 있다. 자물쇠를 지우는 순간 CLI가 쓰지 않아도 컨트롤러가 파드를 띄운다.
  const armed = views.filter((v) => !v.target.start && v.deployment.state !== "absent" && !(v.deployment.state === "present" && v.deployment.replicas === 0));
  if (armed.length) return refuse(`켤 수 없는 대상의 replicas가 확인된 0이 아니다(${armed.map((v) => v.target.id).join(", ")})`, stopFirst);
  const apps = unsettledApps(c, views);
  if (apps.syncing.length) return refuse(`Argo CD 동기화가 진행 중이다(${apps.syncing.join(", ")})`, stopFirst);
  if (apps.unread.length) return refuse(`Argo CD 동기화를 읽지 못했다(${apps.unread.join(", ")})`, stopFirst);
  if (anyUnread(views)) return refuse(`${unreadWhy(views)}. 실행 파드 0개를 확인하지 못했다`);
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
  const blocked = offBlocked(w, views);
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
    raised.push(v);
    const up = bringUp(w, v, limits.startReadySec);
    if (up === "unknown") return offFailed(`${v.target.id}의 replicas 1을 다시 읽어 확인하지 못했다`, rollback(w, allSpaces, raised));
    if (up === "not-ready") return offFailed(`${v.target.id}가 ${limits.startReadySec}초 안에 준비되지 않았다`, rollback(w, allSpaces, raised));
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
      const blocked = offBlocked(c, views);
      if (blocked) return blocked;
      const names = views.filter((v) => v.target.start).map((v) => v.target.id);
      return { status: "pending", label: "자물쇠를 지우고 켤 수 있는 대상을 올린다", headline: `계획: 자물쇠를 지우고 ${names.join(", ")}를 올린다. 현관의 접수 열기는 끝나지 않아 3으로 끝난다`, lines: [OFF_UNCHECKED, OFF_UNFINISHED, ...verboseLines(views, verbose)] };
    },
    apply: (w) => stopOffApply(w, limits, verbose),
  };
}
