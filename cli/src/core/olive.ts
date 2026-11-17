// 올리브 비상 정지용 kubectl 어댑터(supervisor.md §7.1~§7.4, spec D-38·D-39).
// 명령은 ns·Deployment·Application 이름과 상한만 넘긴다. 자물쇠의 이름·모양, replicas 값, argv는 여기 고정이다.
// 파드를 지우거나 kubectl exec로 들어가는 길은 두지 않는다(강제 삭제 금지, supervisor.md §2.4의 exec 제약).
// 읽지 못한 것은 던진다. 시간 초과는 ExecTimeout(결과 미상)이고 "없음"으로 바꾸지 않는다.
import type { AppOperation, HoldZero, HoldZeroTarget, KubeRead, OliveRead, OliveWrite, RunPod, StopLockState, StopTarget } from "./command";
import { ExecTimeout, must, why, type Exec } from "./exec";
import { isArray, jsonParse, jsonStringify } from "./intrinsics";
import { kubectlArgv } from "./kubectl";

export const STOP_LOCK_NAME = "olive-stop";
export const STOP_LOCK_LABEL = "homelab.ukyi.app/olive-stop";
const STOP_LOCK_LABEL_VALUE = "lock";
const ARGO_NS = "argocd";
const POLL_MS = 2_000;

// ns·Deployment·Application 모두 DNS label 꼴로 좁힌다(점 없음, 63자).
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
// key=value를 쉼표로 이은 꼴만(있음·없음·집합 셀렉터는 받지 않는다).
const SELECTOR = /^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+(,[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+)*$/;
export const POD_UID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const K8S_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const PHASES = new Set(["Running", "Terminating", "Succeeded", "Failed", "Error"]);
// 값이 0·1뿐이라 argv를 표에서 꺼낸다. 다른 값이 argv에 끼어들 자리가 없다.
const REPLICAS_FLAG: Record<0 | 1, string> = { 0: "--replicas=0", 1: "--replicas=1" };

function checkLabel(what: string, v: unknown): asserts v is string {
  if (typeof v !== "string" || v.length > 63 || !LABEL.test(v)) throw new Error(`${what} 이름 형식이 아니다`);
}

function checkTimeout(sec: unknown): asserts sec is number {
  if (typeof sec !== "number" || !Number.isInteger(sec) || sec < 1 || sec > 3600) throw new Error("기다림 상한은 1~3600초다");
}

const run = (exec: Exec, args: string[], opts: Parameters<Exec>[1] = {}) => exec(kubectlArgv(args), opts);

export function stopLockManifest(ns: string): Record<string, unknown> {
  checkLabel("namespace", ns);
  return {
    apiVersion: "v1",
    kind: "ResourceQuota",
    metadata: { name: STOP_LOCK_NAME, namespace: ns, labels: { [STOP_LOCK_LABEL]: STOP_LOCK_LABEL_VALUE } },
    spec: { hard: { pods: "0" } },
  };
}

// 우리가 만드는 모양과 같은지. 범위(scopes·scopeSelector)가 붙으면 일부 파드만 막으므로 다르다.
export function lockShape(doc: any): "same" | "different" {
  const hard = doc?.spec?.hard;
  const scopes = doc?.spec?.scopes;
  const sameHard = hard !== null && typeof hard === "object" && !isArray(hard) && Object.keys(hard).length === 1 && hard.pods === "0";
  const noScope = (scopes === undefined || (isArray(scopes) && scopes.length === 0)) && doc?.spec?.scopeSelector === undefined;
  const labeled = doc?.metadata?.labels?.[STOP_LOCK_LABEL] === STOP_LOCK_LABEL_VALUE;
  return sameHard && noScope && labeled ? "same" : "different";
}

// 자물쇠 원문 읽기. 없으면 null, 실패·시간 초과·꼴이 다르면 던진다.
function readLock(exec: Exec, ns: string): any | null {
  checkLabel("namespace", ns);
  const r = run(exec, ["-n", ns, "get", "resourcequotas", STOP_LOCK_NAME, "-o", "json"]);
  if (r.errKind === "timeout") throw new ExecTimeout(`자물쇠 ${ns}: 시간 초과(결과 미상)`);
  if (r.code !== 0 && r.notFound) return null;
  must(r, `자물쇠 ${ns}`);
  const doc = jsonParse(r.stdout);
  if (doc?.kind !== "ResourceQuota" || doc?.metadata?.name !== STOP_LOCK_NAME) throw new Error(`자물쇠 ${ns}: 응답이 그 ResourceQuota가 아니다`);
  return doc;
}

function parsePod(p: any): RunPod {
  const name = p?.metadata?.name;
  const uid = p?.metadata?.uid;
  if (typeof name !== "string" || !name) throw new Error("파드 목록: 이름이 없는 항목이 있다");
  if (typeof uid !== "string" || !POD_UID.test(uid)) throw new Error(`파드 ${name}: uid 형식이 아니다`);
  const str = (v: unknown, what: string): string | null => {
    if (v === undefined || v === null) return null;
    if (typeof v !== "string") throw new Error(`파드 ${name}: ${what} 형식이 아니다`);
    return v;
  };
  const int = (v: unknown, what: string): number | null => {
    if (v === undefined || v === null) return null;
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0) throw new Error(`파드 ${name}: ${what} 형식이 아니다`);
    return v;
  };
  const deletionTimestamp = str(p?.metadata?.deletionTimestamp, "deletionTimestamp");
  if (deletionTimestamp !== null && !K8S_TIME.test(deletionTimestamp)) throw new Error(`파드 ${name}: deletionTimestamp 형식이 아니다`);
  const deletionGracePeriodSeconds = int(p?.metadata?.deletionGracePeriodSeconds, "deletionGracePeriodSeconds");
  return {
    name,
    uid,
    phase: str(p?.status?.phase, "phase"),
    nodeName: str(p?.spec?.nodeName, "nodeName"),
    deletionTimestamp,
    deletionGracePeriodSeconds,
    terminationGracePeriodSeconds: int(p?.spec?.terminationGracePeriodSeconds, "terminationGracePeriodSeconds"),
    forceDeleting: deletionTimestamp !== null && deletionGracePeriodSeconds === 0,
  };
}

export function oliveRead(exec: Exec): OliveRead {
  return {
    stopLock(ns): StopLockState {
      const doc = readLock(exec, ns);
      return doc === null ? "absent" : lockShape(doc);
    },
    appOperation(app): AppOperation | null {
      checkLabel("Application", app);
      const r = run(exec, ["-n", ARGO_NS, "get", "applications.argoproj.io", app, "-o", "json"]);
      if (r.errKind === "timeout") throw new ExecTimeout(`Application ${app}: 시간 초과(결과 미상)`);
      if (r.code !== 0 && r.notFound) return null;
      must(r, `Application ${app}`);
      const doc = jsonParse(r.stdout);
      if (doc?.kind !== "Application" || doc?.metadata?.name !== app) throw new Error(`Application ${app}: 응답이 그 Application이 아니다`);
      const phase = doc?.status?.operationState?.phase;
      if (phase !== undefined && phase !== null && !PHASES.has(phase)) throw new Error(`Application ${app}: 모르는 동기화 단계다`);
      const op = doc?.operation;
      if (op !== undefined && op !== null && (typeof op !== "object" || isArray(op))) throw new Error(`Application ${app}: operation 형식이 아니다`);
      // Argo CD는 operation을 요청하면 .operation을 두고, 끝나면 지우며 operationState.phase를 끝 단계로 바꾼다.
      // 요청만 있고 아직 시작 전(phase가 옛 끝 단계)인 것도 진행 중으로 본다.
      const requested = op !== undefined && op !== null;
      return { inProgress: requested || phase === "Running" || phase === "Terminating", phase: phase ?? null };
    },
    runPods(ns, selector) {
      checkLabel("namespace", ns);
      if (typeof selector !== "string" || !SELECTOR.test(selector)) throw new Error("파드 selector는 key=value(쉼표로 여럿) 꼴만");
      const r = run(exec, ["-n", ns, "get", "pods", "-l", selector, "-o", "json"]);
      must(r, `파드 목록 ${ns}`);
      const doc = jsonParse(r.stdout);
      // items가 없는 응답을 빈 목록으로 읽으면 "파드 0개"를 지어낸다.
      if (!isArray(doc?.items)) throw new Error(`파드 목록 ${ns}: items가 없는 응답이다`);
      return doc.items.map(parsePod);
    },
  };
}

export function oliveWrite(exec: Exec, readExec: Exec, k8s: KubeRead, opts: { pollMs?: number } = {}): OliveWrite {
  const pollMs = opts.pollMs ?? POLL_MS;
  const reads = oliveRead(readExec);
  const setReplicas = (ns: string, deployment: string, replicas: 0 | 1): void => {
    checkLabel("namespace", ns);
    checkLabel("Deployment", deployment);
    if (replicas !== 0 && replicas !== 1) throw new Error("replicas는 0·1만");
    must(run(exec, ["-n", ns, "scale", "deployments.apps", deployment, REPLICAS_FLAG[replicas]]), `replicas ${ns}/${deployment}`);
  };
  return {
    setReplicas,
    stopLockSet(ns) {
      const cur = readLock(readExec, ns);
      if (cur !== null) return lockShape(cur);
      const x = run(exec, ["-n", ns, "create", "-f", "-"], { input: jsonStringify(stopLockManifest(ns)) });
      if (x.errKind === "timeout") throw new ExecTimeout(`자물쇠 ${ns} 걸기: 시간 초과(결과 미상)`);
      // 읽은 뒤 누가 먼저 만들었으면 그것을 본다(같으면 same, 다르면 different).
      const raced = x.code !== 0 && /AlreadyExists/.test(x.stderr);
      if (x.code !== 0 && !raced) throw new Error(`자물쇠 ${ns} 걸기: ${why(x)}`);
      const back = readLock(readExec, ns);
      if (back === null) throw new Error(`자물쇠 ${ns}: 만든 뒤 다시 읽었더니 없다`);
      const shape = lockShape(back);
      if (raced) return shape;
      if (shape !== "same") throw new Error(`자물쇠 ${ns}: 만든 뒤 다시 읽었더니 모양이 다르다`);
      return "created";
    },
    stopLockClear(ns) {
      const cur = readLock(readExec, ns);
      if (cur === null) return "absent";
      if (lockShape(cur) !== "same") return "different";
      const uid = cur?.metadata?.uid;
      if (typeof uid !== "string" || !/^[0-9a-f-]{8,64}$/.test(uid)) throw new Error(`자물쇠 ${ns}: uid를 읽지 못했다`);
      // 확인한 그 객체만 지운다(확인과 삭제 사이에 다른 모양으로 바뀌었으면 API 서버가 거부한다). kubectl delete는 precondition을
      // 넣지 않아 DeleteOptions를 --raw 본문으로 보낸다(kubectl.ts deleteRestoreObject와 같은 방식).
      const body = jsonStringify({ kind: "DeleteOptions", apiVersion: "v1", preconditions: { uid } });
      const x = run(exec, ["delete", "--raw", `/api/v1/namespaces/${ns}/resourcequotas/${STOP_LOCK_NAME}`, "-f", "-"], { input: body, secretStdout: true, signals: { conflict: /Precondition failed|\(Conflict\)/ } });
      if (x.errKind === "timeout") throw new ExecTimeout(`자물쇠 ${ns} 풀기: 시간 초과(결과 미상)`);
      if (x.signals?.includes("conflict")) throw new Error(`자물쇠 ${ns}: 확인 뒤 다른 객체로 바뀌었다. 지우지 않았다`);
      if (x.code !== 0 && !x.notFound) throw new Error(`자물쇠 ${ns} 풀기: ${why(x)}`);
      const back = readLock(readExec, ns);
      if (back !== null) throw new Error(`자물쇠 ${ns}: 지운 뒤에도 있다`);
      return "deleted";
    },
    holdZero(o) {
      checkTimeout(o?.timeoutSec);
      if (!isArray(o.targets) || o.targets.length === 0) throw new Error("지켜볼 대상이 없다");
      if (!isArray(o.apps)) throw new Error("Application 목록이 배열이 아니다");
      for (const t of o.targets) {
        checkLabel("namespace", t?.ns);
        checkLabel("Deployment", t?.deployment);
      }
      for (const a of o.apps) checkLabel("Application", a);
      const state: HoldZeroTarget[] = o.targets.map((t: StopTarget) => ({ ns: t.ns, deployment: t.deployment, last: "unread", rezeroed: 0, writeFailed: 0 }));
      const deadline = Date.now() + o.timeoutSec * 1000;
      for (;;) {
        // 동기화를 먼저 읽고 대상을 나중에 읽는다. 동기화가 끝난 뒤 쓴 1을 같은 회차에서 놓치지 않게.
        const syncing: string[] = [];
        const unreadApps: string[] = [];
        for (const app of o.apps) {
          try {
            if (reads.appOperation(app)?.inProgress) syncing.push(app);
          } catch {
            unreadApps.push(app);
          }
        }
        for (const t of state) {
          let d: any;
          try {
            d = k8s.get("deployment", t.ns, t.deployment);
          } catch {
            t.last = "unread";
            continue;
          }
          if (d === null) {
            t.last = "absent";
            continue;
          }
          const r = d?.spec?.replicas;
          if (typeof r !== "number" || !Number.isInteger(r) || r < 0) {
            t.last = "unread";
            continue;
          }
          t.last = r;
          if (r === 0) continue;
          // 1(또는 그 밖의 값)로 돌아왔으면 기다리지 않고 바로 0을 쓴다. 0 쓰기는 몇 번 해도 같아 다시 써도 안전하다.
          // 성공 여부는 다음 회차의 읽기로만 판정한다(이 회차의 last는 읽은 값 그대로 둔다).
          try {
            setReplicas(t.ns, t.deployment, 0);
            t.rezeroed++;
          } catch {
            t.writeFailed++;
          }
        }
        const zero = state.every((t) => t.last === 0);
        const snapshot = (result: HoldZero["result"]): HoldZero => ({ result, targets: state.map((t) => ({ ...t })), syncing, unreadApps });
        if (zero && syncing.length === 0 && unreadApps.length === 0) return snapshot("zero");
        if (Date.now() + pollMs > deadline) return snapshot("unconfirmed");
        Bun.sleepSync(pollMs);
      }
    },
  };
}
