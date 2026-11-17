// 올리브 비상 정지용 kubectl 어댑터(supervisor.md §7.1~§7.4, spec D-38·D-39).
// 명령은 ns·Deployment·Application 이름과 상한만 넘긴다. 자물쇠의 이름·모양, replicas 값, argv는 여기 고정이다.
// 파드를 지우거나 kubectl exec로 들어가는 길은 두지 않는다(강제 삭제 금지, supervisor.md §2.4의 exec 제약).
// 읽지 못한 것은 던진다. 시간 초과는 ExecTimeout(결과 미상)이고 "없음"으로 바꾸지 않는다.
import type { AppOperation, HoldZero, HoldZeroTarget, OliveRead, OliveWrite, RunPod, StopLockState, StopTarget } from "./command";
import { ExecTimeout, must, why, type Exec } from "./exec";
import { isArray, jsonParse, jsonStringify } from "./intrinsics";
import { kubectlArgv } from "./kubectl";

export const STOP_LOCK_NAME = "olive-stop";
export const STOP_LOCK_LABEL = "homelab.ukyi.app/olive-stop";
const STOP_LOCK_LABEL_VALUE = "lock";
const ARGO_NS = "argocd";
const POLL_MS = 2_000;
// 남은 시간이 이보다 짧으면 kubectl을 새로 띄우지 않는다(응답을 받기 전에 상한이 지난다).
const MIN_CALL_MS = 50;
// 자물쇠 풀기: resourceVersion 충돌 뒤 다시 읽어 판정하는 횟수. quota 컨트롤러가 status.used를 고칠 때마다 버전이 바뀐다.
const CLEAR_ATTEMPTS = 3;

// ns·Deployment·Application 모두 DNS label 꼴로 좁힌다(점 없음, 63자).
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
// key=value를 쉼표로 이은 꼴만(있음·없음·집합 셀렉터는 받지 않는다).
const SELECTOR = /^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+(,[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+)*$/;
export const POD_UID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const K8S_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const RV = /^[0-9]{1,20}$/;
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
const present = <T>(v: T): v is NonNullable<T> => v !== undefined && v !== null;

export function stopLockManifest(ns: string): Record<string, unknown> {
  checkLabel("namespace", ns);
  return {
    apiVersion: "v1",
    kind: "ResourceQuota",
    metadata: { name: STOP_LOCK_NAME, namespace: ns, labels: { [STOP_LOCK_LABEL]: STOP_LOCK_LABEL_VALUE } },
    spec: { hard: { pods: "0" } },
  };
}

// 자물쇠로 쓸 수 있는지. 범위(scopes·scopeSelector)가 붙으면 일부 파드만 막으므로 다르다.
// 삭제 시각이 붙은 quota는 모양이 같아도 곧 사라지고 삭제를 취소할 수 없어(finalizer가 풀리면 끝) deleting이다.
export function lockState(doc: any): Exclude<StopLockState, "absent"> {
  if (present(doc?.metadata?.deletionTimestamp)) return "deleting";
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
  if (doc?.kind !== "ResourceQuota" || doc?.metadata?.name !== STOP_LOCK_NAME || doc?.metadata?.namespace !== ns) throw new Error(`자물쇠 ${ns}: 응답이 그 ResourceQuota가 아니다`);
  return doc;
}

// Application 동기화 진행. 없으면 null. timeoutMs는 holdZero가 남은 시간을 건다.
function readApp(exec: Exec, app: string, timeoutMs?: number): AppOperation | null {
  checkLabel("Application", app);
  const r = run(exec, ["-n", ARGO_NS, "get", "applications.argoproj.io", app, "-o", "json"], timeoutMs === undefined ? {} : { timeoutMs });
  if (r.errKind === "timeout") throw new ExecTimeout(`Application ${app}: 시간 초과(결과 미상)`);
  if (r.code !== 0 && r.notFound) return null;
  must(r, `Application ${app}`);
  const doc = jsonParse(r.stdout);
  if (doc?.kind !== "Application" || doc?.metadata?.name !== app || doc?.metadata?.namespace !== ARGO_NS) throw new Error(`Application ${app}: 응답이 그 Application이 아니다`);
  const phase = doc?.status?.operationState?.phase;
  if (present(phase) && !PHASES.has(phase)) throw new Error(`Application ${app}: 모르는 동기화 단계다`);
  const op = doc?.operation;
  if (present(op) && (typeof op !== "object" || isArray(op))) throw new Error(`Application ${app}: operation 형식이 아니다`);
  // Argo CD는 operation을 요청하면 .operation을 두고, 끝나면 지우며 operationState.phase를 끝 단계로 바꾼다.
  // 요청만 있고 아직 시작 전(phase가 옛 끝 단계)인 것도 진행 중으로 본다.
  return { inProgress: present(op) || phase === "Running" || phase === "Terminating", phase: phase ?? null };
}

// Deployment의 spec.replicas. 응답이 그 ns·이름의 Deployment가 아니거나 값이 없으면 unread(0으로 보지 않는다).
function readReplicas(exec: Exec, ns: string, deployment: string, timeoutMs: number): number | "absent" | "unread" {
  const r = run(exec, ["-n", ns, "get", "deployments.apps", deployment, "-o", "json"], { timeoutMs });
  if (r.errKind) return "unread";
  if (r.code !== 0) return r.notFound ? "absent" : "unread";
  let d: any;
  try {
    d = jsonParse(r.stdout);
  } catch {
    return "unread";
  }
  if (d?.kind !== "Deployment" || d?.metadata?.namespace !== ns || d?.metadata?.name !== deployment) return "unread";
  const n = d?.spec?.replicas;
  return typeof n === "number" && Number.isInteger(n) && n >= 0 ? n : "unread";
}

function parsePod(p: any, ns: string, bareItems: boolean): RunPod {
  const name = p?.metadata?.name;
  const uid = p?.metadata?.uid;
  if (typeof name !== "string" || !name) throw new Error("파드 목록: 이름이 없는 항목이 있다");
  // kubectl의 List는 항목마다 kind를 붙인다. API의 PodList 원문만 항목에 kind가 없다.
  if (!(p?.kind === "Pod" || (bareItems && p?.kind === undefined))) throw new Error(`파드 ${name}: 항목이 Pod가 아니다`);
  if (p?.metadata?.namespace !== ns) throw new Error(`파드 ${name}: 다른 ns의 항목이다`);
  if (typeof uid !== "string" || !POD_UID.test(uid)) throw new Error(`파드 ${name}: uid 형식이 아니다`);
  const str = (v: unknown, what: string): string | null => {
    if (!present(v)) return null;
    if (typeof v !== "string") throw new Error(`파드 ${name}: ${what} 형식이 아니다`);
    return v;
  };
  const int = (v: unknown, what: string): number | null => {
    if (!present(v)) return null;
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
      return doc === null ? "absent" : lockState(doc);
    },
    appOperation: (app) => readApp(exec, app),
    runPods(ns, selector) {
      checkLabel("namespace", ns);
      if (typeof selector !== "string" || !SELECTOR.test(selector)) throw new Error("파드 selector는 key=value(쉼표로 여럿) 꼴만");
      const r = run(exec, ["-n", ns, "get", "pods", "-l", selector, "-o", "json"]);
      must(r, `파드 목록 ${ns}`);
      const doc = jsonParse(r.stdout);
      // 다른 종류의 빈 목록이나 남은 페이지가 있는 부분 목록을 받으면 "파드 0개"를 지어낸다.
      if (doc?.kind !== "List" && doc?.kind !== "PodList") throw new Error(`파드 목록 ${ns}: 파드 목록 응답이 아니다`);
      const cont = doc?.metadata?.continue;
      if (present(cont) && cont !== "") throw new Error(`파드 목록 ${ns}: 남은 페이지가 있는 부분 목록이다`);
      if (!isArray(doc?.items)) throw new Error(`파드 목록 ${ns}: items가 없는 응답이다`);
      return doc.items.map((p: any) => parsePod(p, ns, doc.kind === "PodList"));
    },
  };
}

export function oliveWrite(exec: Exec, readExec: Exec, opts: { pollMs?: number } = {}): OliveWrite {
  const pollMs = opts.pollMs ?? POLL_MS;
  const scale = (ns: string, deployment: string, replicas: 0 | 1, timeoutMs?: number): void => {
    checkLabel("namespace", ns);
    checkLabel("Deployment", deployment);
    if (replicas !== 0 && replicas !== 1) throw new Error("replicas는 0·1만");
    must(run(exec, ["-n", ns, "scale", "deployments.apps", deployment, REPLICAS_FLAG[replicas]], timeoutMs === undefined ? {} : { timeoutMs }), `replicas ${ns}/${deployment}`);
  };
  return {
    setReplicas: (ns, deployment, replicas) => scale(ns, deployment, replicas),
    stopLockSet(ns) {
      const cur = readLock(readExec, ns);
      if (cur !== null) return lockState(cur);
      const x = run(exec, ["-n", ns, "create", "-f", "-"], { input: jsonStringify(stopLockManifest(ns)) });
      if (x.errKind === "timeout") throw new ExecTimeout(`자물쇠 ${ns} 걸기: 시간 초과(결과 미상)`);
      // 읽은 뒤 누가 먼저 만들었으면 그것을 본다(같으면 same, 다르면 different, 지우는 중이면 deleting).
      const raced = x.code !== 0 && /AlreadyExists/.test(x.stderr);
      if (x.code !== 0 && !raced) throw new Error(`자물쇠 ${ns} 걸기: ${why(x)}`);
      const back = readLock(readExec, ns);
      if (back === null) throw new Error(`자물쇠 ${ns}: 만든 뒤 다시 읽었더니 없다`);
      const state = lockState(back);
      if (raced) return state;
      if (state !== "same") throw new Error(`자물쇠 ${ns}: 만든 뒤 다시 읽었더니 걸린 자물쇠가 아니다(${state})`);
      return "created";
    },
    stopLockClear(ns) {
      for (let attempt = 1; ; attempt++) {
        const cur = readLock(readExec, ns);
        if (cur === null) return "absent";
        const state = lockState(cur);
        if (state !== "same") return state;
        const uid = cur?.metadata?.uid;
        const resourceVersion = cur?.metadata?.resourceVersion;
        if (typeof uid !== "string" || !/^[0-9a-f-]{8,64}$/.test(uid)) throw new Error(`자물쇠 ${ns}: uid를 읽지 못했다`);
        if (typeof resourceVersion !== "string" || !RV.test(resourceVersion)) throw new Error(`자물쇠 ${ns}: resourceVersion을 읽지 못했다`);
        // 확인한 그 버전만 지운다. uid만 걸면 같은 객체가 다른 모양으로 고쳐져도(라벨·hard 변경) 지워진다.
        // kubectl delete는 precondition을 넣지 않아 DeleteOptions를 --raw 본문으로 보낸다(kubectl.ts deleteRestoreObject와 같은 방식).
        const body = jsonStringify({ kind: "DeleteOptions", apiVersion: "v1", preconditions: { uid, resourceVersion } });
        const x = run(exec, ["delete", "--raw", `/api/v1/namespaces/${ns}/resourcequotas/${STOP_LOCK_NAME}`, "-f", "-"], { input: body, secretStdout: true, signals: { conflict: /Precondition failed|\(Conflict\)/ } });
        if (x.errKind === "timeout") throw new ExecTimeout(`자물쇠 ${ns} 풀기: 시간 초과(결과 미상)`);
        if (x.signals?.includes("conflict")) {
          // 확인 뒤 바뀌었다. 다시 읽어 모양부터 다시 판정한다.
          if (attempt < CLEAR_ATTEMPTS) continue;
          throw new Error(`자물쇠 ${ns}: 확인할 때마다 다른 버전으로 바뀌었다. 지우지 않았다`);
        }
        if (x.code !== 0 && !x.notFound) throw new Error(`자물쇠 ${ns} 풀기: ${why(x)}`);
        const back = readLock(readExec, ns);
        if (back === null) return "deleted";
        // finalizer가 남아 삭제가 끝나지 않은 그 객체다.
        if (back?.metadata?.uid === uid && lockState(back) === "deleting") return "deleting";
        throw new Error(`자물쇠 ${ns}: 지운 뒤에도 있다`);
      }
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
      // 모든 외부 호출은 남은 시간 안에서만 시작하고 끝난다. 상한 뒤에는 새 쓰기를 시작하지 않는다.
      const left = () => deadline - Date.now();
      const budget = () => Math.max(1, Math.floor(left()));
      let syncing: string[] = [];
      let unreadApps: string[] = [];
      let missingApps: string[] = [];
      const snapshot = (result: HoldZero["result"]): HoldZero => ({ result, targets: state.map((t) => ({ ...t })), syncing, unreadApps, missingApps });
      // 회차 중간에 상한이 오면 이 회차에 아직 못 본 것은 읽지 못함으로 남긴다(앞 회차 값을 지금 값처럼 내지 않는다).
      const stop = (appsFrom: number, targetsFrom: number): HoldZero => {
        unreadApps.push(...o.apps.slice(appsFrom));
        for (const t of state.slice(targetsFrom)) t.last = "unread";
        return snapshot("unconfirmed");
      };
      for (;;) {
        // 새 회차를 시작할 시간이 없으면 앞 회차의 관측을 그대로 낸다.
        if (left() < MIN_CALL_MS) return snapshot("unconfirmed");
        syncing = [];
        unreadApps = [];
        missingApps = [];
        // 동기화를 먼저 읽고 대상을 나중에 읽는다. 동기화가 끝난 뒤 쓴 1을 같은 회차에서 놓치지 않게.
        for (let i = 0; i < o.apps.length; i++) {
          if (i > 0 && left() < MIN_CALL_MS) return stop(i, 0);
          const app = o.apps[i];
          try {
            const op = readApp(readExec, app, budget());
            // 넘겨받은 Application이 없으면 그 동기화가 끝났다는 증거가 아니다.
            if (op === null) missingApps.push(app);
            else if (op.inProgress) syncing.push(app);
          } catch {
            unreadApps.push(app);
          }
        }
        for (let i = 0; i < state.length; i++) {
          if (left() < MIN_CALL_MS) return stop(o.apps.length, i);
          const t = state[i];
          const r = readReplicas(readExec, t.ns, t.deployment, budget());
          t.last = r;
          if (r === 0 || typeof r !== "number") continue;
          // 1(또는 그 밖의 값)로 돌아왔으면 기다리지 않고 바로 0을 쓴다. 0 쓰기는 몇 번 해도 같아 다시 써도 안전하다.
          // 성공 여부는 다음 회차의 읽기로만 판정한다(이 회차의 last는 읽은 값 그대로 둔다).
          if (left() < MIN_CALL_MS) return stop(o.apps.length, i + 1);
          try {
            scale(t.ns, t.deployment, 0, budget());
            t.rezeroed++;
          } catch {
            t.writeFailed++;
          }
        }
        // 상한을 넘겨 받은 응답으로는 성공을 주장하지 않는다.
        if (left() <= 0) return snapshot("unconfirmed");
        const zero = state.every((t) => t.last === 0);
        if (zero && syncing.length === 0 && unreadApps.length === 0 && missingApps.length === 0) return snapshot("zero");
        // 다음 회차가 상한 안에 들도록 남은 시간의 절반까지만 잔다(짧은 상한에서도 0 쓰기 뒤 한 번은 다시 본다).
        Bun.sleepSync(Math.min(pollMs, Math.floor(left() / 2)));
      }
    },
  };
}
