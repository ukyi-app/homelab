// 올리브 감독 파드의 고정 관리 진입점 어댑터. 관리자의 Kubernetes 인증으로 kubectl exec해 감독 상태를 읽는 것까지가 결정(D-60)이고,
// 진입점 argv·schema·응답 칸은 CLI 쪽 제안이다. 감독의 진입점은 아직 없고 그쪽 작업이 이 상수에 맞춘다.
// exec는 쓰기로 판정되므로(writes.ts) 읽기 문맥은 대상 파드와 표시용 argv만 내고, 실행은 쓰기 문맥에서 한 번만 한다.
// ns·라벨·Deployment·컨테이너·진입점·schema는 여기 상수다. 명령이 넘기는 것은 동작 이름 하나라 다른 파드나 임의 argv로 갈 자리가 없다.
// 라벨은 같은 ns의 어느 파드든 붙일 수 있어 신원의 근거가 아니다. 파드 → ReplicaSet → Deployment의 제어 참조를 실제 객체의 UID로 대조한 파드만 대상이다.
// 진입점의 출력과 kubectl의 stderr 원문은 밖으로 내지 않는다. 오류 문구에는 종료 코드만 넣는다.
import type { OliveAdminAction, OliveAdminOutcome, OliveAdminRead, OliveAdminWrite, OliveSupervisorMissing, OliveSupervisorStatus } from "./command";
import { ExecTimeout, type Exec, type ExecResult } from "./exec";
import { entries, isArray, jsonParse } from "./intrinsics";
import { kubectlArgv } from "./kubectl";
import { POD_UID } from "./olive";

export const OLIVE_ADMIN_NS = "olive-control";
export const OLIVE_ADMIN_DEPLOYMENT = "supervisor";
export const OLIVE_ADMIN_CONTAINER = "supervisor";
export const OLIVE_ADMIN_LABELS: Readonly<Record<string, string>> = {
  "app.kubernetes.io/name": "olive",
  "app.kubernetes.io/component": "supervisor",
  "homelab.ukyi.app/olive-target": "supervisor",
};
export const OLIVE_ADMIN_SELECTOR = entries(OLIVE_ADMIN_LABELS).map(([k, v]) => `${k}=${v}`).join(",");
export const OLIVE_ADMIN_ENTRY = ["bun", "src/main/admin.ts"];
// 칸을 바꾸면 판을 올린다. 감독 이미지와 CLI는 따로 배포되므로 모르는 판은 해석하지 않고 거부한다.
export const OLIVE_ADMIN_STATUS_SCHEMA = "olive-supervisor-status/v1";
export const OLIVE_ADMIN_MAX_OUTPUT = 4_096;

const REQUEST_TIMEOUT = "--request-timeout=20s";
const EXEC_TIMEOUT_MS = 30_000;
const POD_NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const MAX_COUNT = 1_000_000;
const STATUS_FIELDS = ["schema", "alive", "queued", "running", "diagnosis", "stop", "stopGeneration", "intakeOpen"];
const ACTION_WORDS: Record<OliveAdminAction, string[]> = { status: ["status"] };
// kubectl이 API 서버에서 답을 받지 못해 끝난 경우의 stderr 마지막 줄. 진입점이 돌았는지 알 수 없으므로 실패가 아니라 결과 미상이다.
const KUBECTL_TIMEOUT = /^(?:Error from server \((?:Timeout|ServerTimeout)\):|(?:Unable to connect to the server|Error from server|error): .*(?:Client\.Timeout|context deadline exceeded|request canceled|i\/o timeout|TLS handshake timeout))/;
// exec.ts가 stderr를 앞에서부터 이 길이까지만 남긴다.
const STDERR_KEPT = 2_000;

// stdout과 stderr의 앞부분은 진입점이 쓸 수 있으므로 분류에 쓰지 않는다. kubectl은 자기 오류를 stderr 맨 끝에 쓰고, 원격 명령이 0이 아니게
// 끝나면 끝 줄이 "command terminated with exit code N"이라 진입점이 쓴 글이 끝 줄이 되지 못한다.
// 잘린 stderr는 끝 줄을 알 수 없다. 진입점이 잘리는 자리에 맞춰 kubectl 오류를 흉내 낼 수 있어 시간 초과로 치지 않는다.
function timedOut(r: ExecResult): boolean {
  if (r.errKind === "timeout") return true;
  if (r.code === 0 || r.stderr.length >= STDERR_KEPT) return false;
  return KUBECTL_TIMEOUT.test(r.stderr.slice(r.stderr.lastIndexOf("\n") + 1));
}

function wordsOf(action: OliveAdminAction): string[] {
  if (typeof action !== "string" || !Object.hasOwn(ACTION_WORDS, action)) throw new Error("감독 관리 동작은 status만");
  return ACTION_WORDS[action];
}

const failure = (r: ExecResult) => (r.errKind === "not-found" ? "kubectl이 없다" : r.errKind ?? r.signal ?? `exit ${r.code}`);
const present = (v: unknown) => v !== undefined && v !== null;
const isName = (v: unknown): v is string => typeof v === "string" && v.length <= 253 && POD_NAME.test(v);
const isUid = (v: unknown): v is string => typeof v === "string" && POD_UID.test(v);
const isReady = (p: any) => isArray(p?.status?.conditions) && p.status.conditions.some((c: any) => c?.type === "Ready" && c?.status === "True");
// 쫓겨나거나 끝난 파드는 Deployment가 지우기 전까지 목록에 남는다. 지금 도는 감독으로 세지 않는다.
const finished = (p: any) => p?.status?.phase === "Succeeded" || p?.status?.phase === "Failed";

// 요청한 ns·셀렉터의 파드 응답인지만 본다. 감독의 것인지는 ownedBySupervisor가 실제 객체로 가른다.
function isSupervisorPod(p: any, bareItems: boolean): boolean {
  const labels = p?.metadata?.labels;
  const containers = p?.spec?.containers;
  return (
    (p?.kind === "Pod" || (bareItems && p?.kind === undefined)) &&
    isName(p?.metadata?.name) &&
    p?.metadata?.namespace === OLIVE_ADMIN_NS &&
    entries(OLIVE_ADMIN_LABELS).every(([k, v]) => labels?.[k] === v) &&
    isArray(containers) &&
    containers.some((c: any) => c?.name === OLIVE_ADMIN_CONTAINER)
  );
}

function listPods(exec: Exec): any[] {
  const r = exec(kubectlArgv(["-n", OLIVE_ADMIN_NS, "get", "pods", "-l", OLIVE_ADMIN_SELECTOR, "-o", "json"]));
  if (timedOut(r)) throw new ExecTimeout("감독 파드 찾기: 시간 초과(결과 미상)");
  if (r.code !== 0) throw new Error(`감독 파드를 읽지 못했다(${failure(r)})`);
  let doc: any;
  try {
    doc = jsonParse(r.stdout);
  } catch {
    throw new Error("감독 파드를 읽지 못했다(응답이 JSON이 아니다)");
  }
  // 다른 종류의 빈 목록이나 남은 페이지가 있는 부분 목록을 받으면 "감독 없음"을 지어낸다.
  if ((doc?.kind !== "List" && doc?.kind !== "PodList") || !isArray(doc?.items)) throw new Error("감독 파드를 읽지 못했다(파드 목록 응답이 아니다)");
  if (present(doc?.metadata?.continue) && doc.metadata.continue !== "") throw new Error("감독 파드를 읽지 못했다(남은 페이지가 있는 부분 목록이다)");
  if (!doc.items.every((p: any) => isSupervisorPod(p, doc.kind === "PodList"))) throw new Error("감독 파드를 읽지 못했다(감독 파드 모양이 아닌 항목이 있다)");
  return doc.items;
}

// 소유 사슬의 한 객체. 없으면 null(대상 아님의 근거다), 읽지 못했거나 다른 객체가 오면 던진다.
function readOwner(exec: Exec, kind: "Deployment" | "ReplicaSet", name: string): any | null {
  const r = exec(kubectlArgv(["-n", OLIVE_ADMIN_NS, "get", kind === "Deployment" ? "deployments.apps" : "replicasets.apps", name, "-o", "json"]));
  if (timedOut(r)) throw new ExecTimeout(`감독 ${kind} 읽기: 시간 초과(결과 미상)`);
  if (r.code !== 0 && r.notFound) return null;
  if (r.code !== 0) throw new Error(`감독 파드를 읽지 못했다(${kind}: ${failure(r)})`);
  let doc: any;
  try {
    doc = jsonParse(r.stdout);
  } catch {
    throw new Error(`감독 파드를 읽지 못했다(${kind} 응답이 JSON이 아니다)`);
  }
  if (doc?.kind !== kind || doc?.metadata?.name !== name || doc?.metadata?.namespace !== OLIVE_ADMIN_NS || !isUid(doc?.metadata?.uid)) throw new Error(`감독 파드를 읽지 못했다(${kind} 응답이 그 객체가 아니다)`);
  return doc;
}

// 제어 참조는 객체마다 많아야 하나다. 이름은 다음 조회의 argv에 들어가므로 형식부터 본다.
function controllerOf(doc: any, kind: "Deployment" | "ReplicaSet"): { name: string; uid: string } | null {
  const owners = doc?.metadata?.ownerReferences;
  if (!isArray(owners)) return null;
  const controllers = owners.filter((o: any) => o?.controller === true);
  if (controllers.length !== 1) return null;
  const c = controllers[0];
  return c?.apiVersion === "apps/v1" && c?.kind === kind && isName(c?.name) && isUid(c?.uid) ? { name: c.name, uid: c.uid } : null;
}

// 목록의 모든 파드가 고정 Deployment의 것인지 파드 → ReplicaSet → Deployment 순으로 이름·UID를 대조한다.
function ownedBySupervisor(exec: Exec, pods: any[]): boolean {
  const refs = pods.map((p) => controllerOf(p, "ReplicaSet"));
  if (refs.some((ref) => ref === null)) return false;
  const deployment = readOwner(exec, "Deployment", OLIVE_ADMIN_DEPLOYMENT);
  if (deployment === null) return false;
  const replicaSets = new Map<string, any | null>();
  for (const ref of refs as { name: string; uid: string }[]) {
    if (!replicaSets.has(ref.name)) replicaSets.set(ref.name, readOwner(exec, "ReplicaSet", ref.name));
    const replicaSet = replicaSets.get(ref.name);
    if (replicaSet === null || replicaSet.metadata.uid !== ref.uid) return false;
    const parent = controllerOf(replicaSet, "Deployment");
    if (parent === null || parent.name !== OLIVE_ADMIN_DEPLOYMENT || parent.uid !== deployment.metadata.uid) return false;
  }
  return true;
}

function findPod(exec: Exec): { state: "ready"; pod: string } | OliveSupervisorMissing {
  const items = listPods(exec);
  if (items.length === 0) return { state: "absent", pods: 0 };
  if (!ownedBySupervisor(exec, items)) return { state: "not-owned", pods: items.length };
  const active = items.filter((p) => !finished(p));
  if (active.length === 0) return { state: "not-ready", pods: items.length };
  if (active.length > 1) return { state: "multiple", pods: active.length };
  const pod = active[0];
  if (present(pod.metadata.deletionTimestamp)) return { state: "terminating", pods: 1 };
  if (pod.status?.phase !== "Running" || !isReady(pod)) return { state: "not-ready", pods: items.length };
  return { state: "ready", pod: pod.metadata.name };
}

// pod는 findPod가 형식을 확인한 이름만 온다.
function adminArgv(pod: string, action: OliveAdminAction): string[] {
  // --request-timeout은 -- 앞에 둔다(뒤에 두면 진입점의 인자가 된다).
  return ["kubectl", "-n", OLIVE_ADMIN_NS, "exec", pod, "-c", OLIVE_ADMIN_CONTAINER, REQUEST_TIMEOUT, "--", ...OLIVE_ADMIN_ENTRY, ...wordsOf(action)];
}

const MEMBER = /[ \t\r]*("(?:[^"\\]|\\.)*")[ \t\r]*:[ \t\r]*(?:"(?:[^"\\]|\\.)*"|true|false|0|[1-9][0-9]*)[ \t\r]*([,}])/y;

// jsonParse는 같은 키의 앞 값을 버리고 수를 반올림한 뒤에 돌려주므로 그 전에 글자로 본다. 받는 문서는 중첩 없는 객체 하나이고 값은
// 문자열·불리언·부호 없는 십진 정수뿐이라 이 문법만 통과시킨다. 문자열 안쪽의 유효성과 키 이름의 디코딩은 jsonParse에 맡긴다.
function flatDocument(line: string): boolean {
  const open = /^[ \t\r]*\{/.exec(line);
  if (open === null) return false;
  const keys = new Set<string>();
  let at = open[0].length;
  for (;;) {
    MEMBER.lastIndex = at;
    const member = MEMBER.exec(line);
    if (member === null) return false;
    const key: string = jsonParse(member[1]);
    if (keys.has(key)) return false;
    keys.add(key);
    at = MEMBER.lastIndex;
    if (member[2] === "}") return /^[ \t\r]*$/.test(line.slice(at));
  }
}

// 정해진 칸만 타입 있는 값으로 옮긴다. 자유 문자열 칸이 없어 원문·자격 값이 실릴 자리가 없다.
// JSON 해석 오류의 문구에는 입력 조각이 들어가므로 그대로 던지지 않는다.
export function parseStatus(stdout: string): OliveSupervisorStatus {
  const fail = () => new Error("감독 관리 진입점 출력이 정해진 꼴이 아니다");
  if (Buffer.byteLength(stdout) > OLIVE_ADMIN_MAX_OUTPUT) throw fail();
  const line = stdout.endsWith("\n") ? stdout.slice(0, -1) : stdout;
  if (line === "" || line.includes("\n")) throw fail();
  let doc: any;
  try {
    if (!flatDocument(line)) throw fail();
    doc = jsonParse(line);
  } catch {
    throw fail();
  }
  const keys = Object.keys(doc);
  if (keys.length !== STATUS_FIELDS.length || !STATUS_FIELDS.every((k) => Object.hasOwn(doc, k))) throw fail();
  const count = (v: unknown) => Number.isInteger(v) && (v as number) >= 0 && (v as number) < MAX_COUNT;
  const valid =
    doc.schema === OLIVE_ADMIN_STATUS_SCHEMA &&
    typeof doc.alive === "boolean" &&
    count(doc.queued) &&
    count(doc.running) &&
    (doc.diagnosis === "active" || doc.diagnosis === "paused") &&
    (doc.stop === "none" || doc.stop === "stopping" || doc.stop === "stopped") &&
    Number.isSafeInteger(doc.stopGeneration) &&
    doc.stopGeneration >= 0 &&
    typeof doc.intakeOpen === "boolean";
  if (!valid) throw fail();
  return { alive: doc.alive, queued: doc.queued, running: doc.running, diagnosis: doc.diagnosis, stop: doc.stop, stopGeneration: doc.stopGeneration, intakeOpen: doc.intakeOpen };
}

export function oliveAdminRead(readExec: Exec): OliveAdminRead {
  return {
    target(action) {
      wordsOf(action);
      const found = findPod(readExec);
      return found.state === "ready" ? { ...found, argv: adminArgv(found.pod, action) } : found;
    },
  };
}

// alive: 끝난 apply의 쓰기 문맥이면 던진다. 쓰기 exec의 막기는 파드 조회 뒤에야 닿으므로 run 입구에서 먼저 본다.
export function oliveAdminWrite(exec: Exec, readExec: Exec, alive: () => void): OliveAdminWrite {
  return {
    ...oliveAdminRead(readExec),
    run(action): OliveAdminOutcome {
      alive();
      wordsOf(action);
      let target: ReturnType<typeof findPod>;
      try {
        target = findPod(readExec);
      } catch (e) {
        if (e instanceof ExecTimeout) return { state: "unknown" };
        throw e;
      }
      if (target.state !== "ready") return { state: "no-target", target };
      // 함정: kubectl exec에는 UID 조건이 없어 대조와 실행 사이에 같은 이름의 파드로 바뀌는 경쟁은 남는다.
      const r = exec(adminArgv(target.pod, action), { timeoutMs: EXEC_TIMEOUT_MS });
      if (timedOut(r)) return { state: "unknown" };
      if (r.code !== 0) throw new Error(`감독 관리 진입점이 실패했다(${failure(r)})`);
      return { state: "reported", pod: target.pod, status: parseStatus(r.stdout) };
    },
  };
}
