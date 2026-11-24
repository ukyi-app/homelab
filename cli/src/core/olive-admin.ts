// 올리브 감독 파드의 고정 관리 진입점 어댑터. 관리자의 Kubernetes 인증으로 kubectl exec해 감독 상태를 읽는 것까지가 결정(D-60)이고,
// 같은 길로 시험 작업 한 줄을 넣는다(D-98·D-101). 진입점 argv·schema·응답 칸·stderr 사유 꼴은 감독 쪽(olive
// src/supervisor/admin/protocol.ts·client.ts)과 같아야 한다. 감독 이미지와 CLI는 따로 배포되므로 모르는 꼴은 해석하지 않는다.
// exec는 쓰기로 판정되므로(writes.ts) 읽기 문맥은 대상 파드와 표시용 argv만 내고, 실행은 쓰기 문맥에서 한 번만 한다.
// ns·라벨·Deployment·컨테이너·진입점·schema는 여기 상수다. 명령이 넘기는 것은 동작 이름과 시험 작업의 값 여섯뿐이라 다른 파드나 임의
// kubectl 인자로 갈 자리가 없다(값은 꼴을 본 뒤 `--` 뒤에 진입점의 인자로만 들어간다).
// 라벨은 같은 ns의 어느 파드든 붙일 수 있어 신원의 근거가 아니다. 파드 → ReplicaSet → Deployment의 제어 참조를 실제 객체의 UID로 대조한 파드만 대상이다.
// 진입점의 출력과 kubectl의 stderr 원문은 밖으로 내지 않는다. 오류 문구에는 종료 코드만, 결과에는 닫힌 목록의 사유 낱말만 넣는다.
import type { OliveAdminAction, OliveAdminExit, OliveAdminOutcome, OliveAdminRead, OliveAdminReason, OliveAdminWrite, OliveSupervisorMissing, OliveSupervisorStatus, OliveSupervisorTarget, OliveTestJob, OliveTestJobOutcome } from "./command";
import { ExecTimeout, type Exec, type ExecResult } from "./exec";
import { entries, isArray, jsonParse } from "./intrinsics";
import { kubectlArgv } from "./kubectl";
import { OLIVE_TEST_JOB_FIELDS, oliveTestJobFits } from "./names";
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
export const OLIVE_ADMIN_TEST_JOB_SCHEMA = "olive-test-job/v1";
export const OLIVE_ADMIN_MAX_OUTPUT = 4_096;

const REQUEST_TIMEOUT = "--request-timeout=20s";
const EXEC_TIMEOUT_MS = 30_000;
const POD_NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const MAX_COUNT = 1_000_000;
const STATUS_FIELDS = ["schema", "alive", "queued", "running", "diagnosis", "stop", "stopGeneration", "intakeOpen"];
const TEST_JOB_FIELDS = ["schema", "outcome", "ref"];
const REF = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ACTION_WORDS: Record<OliveAdminAction, string[]> = { status: ["status"], "test-job": ["test-job"] };
// 진입점의 사유 낱말(olive protocol.ts의 REFUSED_REASONS·UNKNOWN_REASONS, client.ts의 AskOutcome). malformed는 두 갈래에 있어
// 낱말만으로는 거절인지 답을 받지 못한 것인지 모른다. 그래서 갈래는 stderr 줄의 머리로 가른다.
const REASON_WORDS: Record<OliveAdminReason["kind"], readonly string[]> = {
  refused: ["malformed", "unknown_command", "busy", "disabled", "not_alive", "stopped", "intake_closed", "owner_inactive", "limit", "late", "conflict", "invariant_violation", "ledger_refused"],
  unreached: ["no_socket", "not_listening", "connect_failed"],
  "no-reply": ["timeout", "closed", "too_long", "malformed", "write_failed", "clock"],
  unknown: ["restore_not_done", "ledger_unreadable", "stop_unrecorded", "clock_unavailable", "out_of_range", "read_threw", "random_unavailable", "write_unknown"],
};
// 진입점(olive client.ts exitFor)이 0이 아닐 때 stderr에 쓰는 한 줄. 문구가 바뀌면 사유는 null이 되고 종료 코드만으로 말한다.
const REFUSED_LINE = /^olive admin: 감독이 요청을 거절했다\(([a-z_]+)\)$/;
const UNKNOWN_LINE = /^olive admin: (?:상태|시험 작업) 모름: ([^()]*)\(([a-z_]+)\)$/;
const UNREACHED_HEAD = "감독에 닿지 못했다";
const NO_REPLY_HEAD = "감독의 답을 받지 못했다";
// 진입점의 종료 코드: 0 완료, 1 실패, 3 복원 전(모름), 64 사용법. 3은 restore_not_done만 낸다.
const WAITING_EXIT = 3;
// kubectl이 API 서버에서 답을 받지 못해 끝난 경우의 stderr 마지막 줄. 진입점이 돌았는지 알 수 없으므로 실패가 아니라 결과 미상이다.
const KUBECTL_TIMEOUT = /^(?:Error from server \((?:Timeout|ServerTimeout)\):|(?:Unable to connect to the server|Error from server|error): .*(?:Client\.Timeout|context deadline exceeded|request canceled|i\/o timeout|TLS handshake timeout))/;
// exec.ts가 stderr를 앞에서부터 이 길이까지만 남긴다.
const STDERR_KEPT = 2_000;

// kubectl은 자기 오류를 stderr 맨 끝에 쓴다. 잘린 stderr는 끝 줄을 알 수 없어 null이다.
const endLine = (r: ExecResult) => (r.stderr.length >= STDERR_KEPT ? null : r.stderr.slice(r.stderr.lastIndexOf("\n") + 1));

// stdout과 stderr의 앞부분은 진입점이 쓸 수 있으므로 분류에 쓰지 않는다. 원격 명령이 0이 아니게 끝나면 kubectl이 stderr 맨 끝에
// "command terminated with exit code N"을 붙인다. 진입점의 stderr에 마지막 줄바꿈이 없으면 그 문구가 같은 줄에 이어지므로 줄 시작이 아니라
// 줄 끝을 실제 종료 코드와 대조한다.
// 잘린 stderr는 진입점이 잘리는 자리에 맞춰 kubectl 오류를 흉내 낼 수 있어 시간 초과로 치지 않는다.
function timedOut(r: ExecResult): boolean {
  if (r.errKind === "timeout") return true;
  if (r.code === 0) return false;
  const end = endLine(r);
  if (end === null || end.endsWith(`command terminated with exit code ${r.code}`)) return false;
  return KUBECTL_TIMEOUT.test(end);
}

function wordsOf(action: OliveAdminAction): string[] {
  if (typeof action !== "string" || !Object.hasOwn(ACTION_WORDS, action)) throw new Error("감독 관리 동작은 status, test-job만");
  return ACTION_WORDS[action];
}

// 진입점 뒤의 인자. status는 인자가 없고 test-job은 값 여섯을 정해진 차례로 옮긴다(받은 객체를 펼치지 않는다).
// 꼴이 아니면 값을 되찍지 않고 던진다. 명령의 인자 검사를 지난 값만 오지만, argv는 이 파일이 만들므로 여기서도 본다.
function entryArgs(action: OliveAdminAction, job: unknown): string[] {
  const words = wordsOf(action);
  if (action === "status") return words;
  const values = typeof job === "object" && job !== null ? OLIVE_TEST_JOB_FIELDS.map((f) => (Object.hasOwn(job, f) ? (job as Record<string, unknown>)[f] : undefined)) : [];
  if (!oliveTestJobFits(values as string[])) throw new Error("시험 작업 값이 정해진 꼴이 아니다");
  return [...words, ...(values as string[])];
}

const failure = (r: ExecResult) => (r.errKind === "not-found" ? "kubectl이 없다" : r.errKind ?? r.signal ?? `exit ${r.code}`);
const present = (v: unknown) => v !== undefined && v !== null;
const isName = (v: unknown): v is string => typeof v === "string" && v.length <= 253 && POD_NAME.test(v);
const isUid = (v: unknown): v is string => typeof v === "string" && POD_UID.test(v);
// 목록의 항목은 타입 정보를 생략할 수 있다. 적혀 있으면 기대한 값이어야 한다.
const versionFits = (doc: any, want: string) => doc?.apiVersion === undefined || doc.apiVersion === want;
const isReady = (p: any) => isArray(p?.status?.conditions) && p.status.conditions.some((c: any) => c?.type === "Ready" && c?.status === "True");
// 쫓겨나거나 끝난 파드는 Deployment가 지우기 전까지 목록에 남는다. 지금 도는 감독으로 세지 않는다.
const finished = (p: any) => p?.status?.phase === "Succeeded" || p?.status?.phase === "Failed";

// 요청한 ns·셀렉터의 파드 응답인지만 본다. 감독의 것인지는 ownedBySupervisor가 실제 객체로 가른다.
function isSupervisorPod(p: any, bareItems: boolean): boolean {
  const labels = p?.metadata?.labels;
  const containers = p?.spec?.containers;
  return (
    (p?.kind === "Pod" || (bareItems && p?.kind === undefined)) &&
    versionFits(p, "v1") &&
    isName(p?.metadata?.name) &&
    isUid(p?.metadata?.uid) &&
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
  if ((doc?.kind !== "List" && doc?.kind !== "PodList") || !versionFits(doc, "v1") || !isArray(doc?.items)) throw new Error("감독 파드를 읽지 못했다(파드 목록 응답이 아니다)");
  if (present(doc?.metadata?.continue) && doc.metadata.continue !== "") throw new Error("감독 파드를 읽지 못했다(남은 페이지가 있는 부분 목록이다)");
  if (!doc.items.every((p: any) => isSupervisorPod(p, doc.kind === "PodList"))) throw new Error("감독 파드를 읽지 못했다(감독 파드 모양이 아닌 항목이 있다)");
  return doc.items;
}

// 소유 사슬의 한 객체. 없으면 null(대상 아님의 근거다), 읽지 못했거나 다른 객체가 오면 던진다.
// 없다는 근거는 이 호출이 읽은 객체를 가리키는 kubectl의 끝 줄뿐이다. ExecResult.notFound는 stderr 어느 줄이든 맞아서 다른 오류를 가린다.
function readOwner(exec: Exec, kind: "Deployment" | "ReplicaSet", name: string): any | null {
  const resource = kind === "Deployment" ? "deployments.apps" : "replicasets.apps";
  const r = exec(kubectlArgv(["-n", OLIVE_ADMIN_NS, "get", resource, name, "-o", "json"]));
  if (timedOut(r)) throw new ExecTimeout(`감독 ${kind} 읽기: 시간 초과(결과 미상)`);
  if (r.code === 1 && endLine(r) === `Error from server (NotFound): ${resource} "${name}" not found`) return null;
  if (r.code !== 0) throw new Error(`감독 파드를 읽지 못했다(${kind}: ${failure(r)})`);
  let doc: any;
  try {
    doc = jsonParse(r.stdout);
  } catch {
    throw new Error(`감독 파드를 읽지 못했다(${kind} 응답이 JSON이 아니다)`);
  }
  if (doc?.apiVersion !== "apps/v1" || doc?.kind !== kind || doc?.metadata?.name !== name || doc?.metadata?.namespace !== OLIVE_ADMIN_NS || !isUid(doc?.metadata?.uid)) throw new Error(`감독 파드를 읽지 못했다(${kind} 응답이 그 객체가 아니다)`);
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

// pod는 findPod가 형식을 확인한 이름만, args는 entryArgs가 만든 것만 온다.
function adminArgv(pod: string, args: string[]): string[] {
  // --request-timeout은 -- 앞에 둔다(뒤에 두면 진입점의 인자가 된다).
  return ["kubectl", "-n", OLIVE_ADMIN_NS, "exec", pod, "-c", OLIVE_ADMIN_CONTAINER, REQUEST_TIMEOUT, "--", ...OLIVE_ADMIN_ENTRY, ...args];
}

// 원격 명령이 0이 아닌 코드로 끝난 것을 kubectl의 끝 줄로 확인했을 때만 그 코드다. 시간 초과 판정은 timedOut이 먼저 한다.
function remoteCode(r: ExecResult): number | null {
  if (r.code === null || r.code === 0 || r.errKind !== undefined || r.signal) return null;
  const end = endLine(r);
  return end !== null && end.endsWith(`command terminated with exit code ${r.code}`) ? r.code : null;
}

// 사유는 stderr가 진입점의 한 줄과 kubectl의 끝 줄, 꼭 두 줄일 때만 읽는다. 앞에 다른 줄이 있거나 잘렸으면 null이다.
// 낱말은 그 갈래의 닫힌 목록에 있고 코드와 맞아야 한다(3은 restore_not_done뿐, 나머지는 1).
function reasonOf(r: ExecResult, code: number): OliveAdminReason | null {
  const lines = r.stderr.split("\n");
  if (lines.length !== 2 || lines[1] !== `command terminated with exit code ${code}`) return null;
  const line = lines[0] as string;
  let reason: OliveAdminReason | null = null;
  const refused = REFUSED_LINE.exec(line);
  const unknown = UNKNOWN_LINE.exec(line);
  if (refused) reason = { kind: "refused", word: refused[1] as string };
  else if (unknown) {
    const head = (unknown[1] as string).trim();
    const kind = head === UNREACHED_HEAD ? "unreached" : head === NO_REPLY_HEAD ? "no-reply" : "unknown";
    reason = { kind, word: unknown[2] as string };
  }
  if (reason === null || !REASON_WORDS[reason.kind].includes(reason.word)) return null;
  const wants = reason.word === "restore_not_done" ? WAITING_EXIT : 1;
  return wants === code ? reason : null;
}

const exitOf = (pod: string, r: ExecResult, code: number): OliveAdminExit => ({ state: "exit", pod, code, reason: reasonOf(r, code) });

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

// 시험 작업 한 줄(olive-test-job/v1). 칸 셋만, ref는 감독이 만든 소문자 UUID만 받는다.
export function parseTestJob(stdout: string): { outcome: "created" | "existing"; ref: string } {
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
  if (keys.length !== TEST_JOB_FIELDS.length || !TEST_JOB_FIELDS.every((k) => Object.hasOwn(doc, k))) throw fail();
  if (doc.schema !== OLIVE_ADMIN_TEST_JOB_SCHEMA || (doc.outcome !== "created" && doc.outcome !== "existing") || typeof doc.ref !== "string" || !REF.test(doc.ref)) throw fail();
  return { outcome: doc.outcome, ref: doc.ref };
}

function targetOf(readExec: Exec, action: OliveAdminAction, job: unknown): OliveSupervisorTarget {
  const args = entryArgs(action, job);
  const found = findPod(readExec);
  return found.state === "ready" ? { ...found, argv: adminArgv(found.pod, args) } : found;
}

export function oliveAdminRead(readExec: Exec): OliveAdminRead {
  return {
    target: (action: OliveAdminAction, job?: OliveTestJob) => targetOf(readExec, action, job),
  };
}

// alive: 끝난 apply의 쓰기 문맥이면 던진다. target은 읽기 exec만 쓰고 run도 파드 조회 뒤에야 쓰기 exec의 막기에 닿으므로 두 입구에서 먼저 본다.
export function oliveAdminWrite(exec: Exec, readExec: Exec, alive: () => void): OliveAdminWrite {
  return {
    target(action: OliveAdminAction, job?: OliveTestJob) {
      alive();
      return targetOf(readExec, action, job);
    },
    run(action): OliveAdminOutcome {
      alive();
      if (wordsOf(action) !== ACTION_WORDS.status) throw new Error("감독 관리 동작 run은 status만");
      const args = entryArgs(action, undefined);
      let target: ReturnType<typeof findPod>;
      try {
        target = findPod(readExec);
      } catch (e) {
        if (e instanceof ExecTimeout) return { state: "unknown" };
        throw e;
      }
      if (target.state !== "ready") return { state: "no-target", target };
      // 함정: kubectl exec에는 UID 조건이 없어 대조와 실행 사이에 같은 이름의 파드로 바뀌는 경쟁은 남는다.
      const r = exec(adminArgv(target.pod, args), { timeoutMs: EXEC_TIMEOUT_MS });
      if (timedOut(r)) return { state: "unknown" };
      const code = remoteCode(r);
      if (code !== null) return exitOf(target.pod, r, code);
      if (r.code !== 0) throw new Error(`감독 관리 진입점이 실패했다(${failure(r)})`);
      return { state: "reported", pod: target.pod, status: parseStatus(r.stdout) };
    },
    // 실행 전 실패(파드 목록·소유 사슬을 읽지 못함, 그 시간 초과)는 던진다: 아무것도 보내지 않았다.
    // 실행 뒤 결과를 확인하지 못하면 unknown이다: 감독이 장부에 적었을 수 있다.
    testJob(job: OliveTestJob): OliveTestJobOutcome {
      alive();
      const args = entryArgs("test-job", job);
      const target = findPod(readExec);
      if (target.state !== "ready") return { state: "no-target", target };
      // 함정: kubectl exec에는 UID 조건이 없어 대조와 실행 사이에 같은 이름의 파드로 바뀌는 경쟁은 남는다.
      const r = exec(adminArgv(target.pod, args), { timeoutMs: EXEC_TIMEOUT_MS });
      if (timedOut(r)) return { state: "unknown", pod: target.pod };
      const code = remoteCode(r);
      if (code !== null) return exitOf(target.pod, r, code);
      if (r.code !== 0) return { state: "unknown", pod: target.pod };
      try {
        return { state: "accepted", pod: target.pod, ...parseTestJob(r.stdout) };
      } catch {
        return { state: "unknown", pod: target.pod };
      }
    },
  };
}
