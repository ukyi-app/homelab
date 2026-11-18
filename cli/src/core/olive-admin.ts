// 올리브 감독 파드의 고정 관리 진입점 어댑터(D-60). 관리자의 Kubernetes 인증으로 kubectl exec해 감독 상태를 읽는다.
// exec는 쓰기로 판정되므로(writes.ts) 읽기 문맥은 대상 파드 찾기와 argv만 내고, 실행은 쓰기 문맥에서 한 번만 한다.
// ns·라벨·컨테이너·진입점·schema는 여기 상수다. 명령이 넘기는 것은 동작 이름 하나라 다른 파드나 임의 argv로 갈 자리가 없다.
// 진입점의 출력과 kubectl의 stderr 원문은 밖으로 내지 않는다. 오류 문구에는 종료 코드만 넣는다.
import type { OliveAdminAction, OliveAdminOutcome, OliveAdminRead, OliveAdminWrite, OliveSupervisorPod, OliveSupervisorStatus } from "./command";
import { ExecTimeout, type Exec, type ExecResult } from "./exec";
import { entries, isArray, jsonParse } from "./intrinsics";
import { kubectlArgv } from "./kubectl";

export const OLIVE_ADMIN_NS = "olive-control";
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
// kubectl이 API 서버에서 답을 받지 못해 끝난 경우. 진입점이 돌았는지 알 수 없으므로 실패가 아니라 결과 미상이다.
const KUBECTL_TIMEOUT = { timeout: /Client\.Timeout|context deadline exceeded|request canceled|i\/o timeout|TLS handshake timeout/ };
const timedOut = (r: ExecResult) => r.errKind === "timeout" || (r.code !== 0 && r.signals?.includes("timeout") === true);

function wordsOf(action: OliveAdminAction): string[] {
  if (typeof action !== "string" || !Object.hasOwn(ACTION_WORDS, action)) throw new Error("감독 관리 동작은 status만");
  return ACTION_WORDS[action];
}

const failure = (r: ExecResult) => (r.errKind === "not-found" ? "kubectl이 없다" : r.errKind ?? r.signal ?? `exit ${r.code}`);
const present = (v: unknown) => v !== undefined && v !== null;
const isReady = (p: any) => isArray(p?.status?.conditions) && p.status.conditions.some((c: any) => c?.type === "Ready" && c?.status === "True");
// 쫓겨나거나 끝난 파드는 Deployment가 지우기 전까지 목록에 남는다. 지금 도는 감독으로 세지 않는다.
const finished = (p: any) => p?.status?.phase === "Succeeded" || p?.status?.phase === "Failed";

// 셀렉터에 걸려도 Deployment가 만든 감독 파드 모양이 아니면 대상으로 삼지 않는다.
function isSupervisorPod(p: any, bareItems: boolean): boolean {
  const name = p?.metadata?.name;
  const labels = p?.metadata?.labels;
  const owners = p?.metadata?.ownerReferences;
  const containers = p?.spec?.containers;
  return (
    (p?.kind === "Pod" || (bareItems && p?.kind === undefined)) &&
    typeof name === "string" &&
    name.length <= 253 &&
    POD_NAME.test(name) &&
    p?.metadata?.namespace === OLIVE_ADMIN_NS &&
    entries(OLIVE_ADMIN_LABELS).every(([k, v]) => labels?.[k] === v) &&
    isArray(owners) &&
    owners.some((o: any) => o?.kind === "ReplicaSet") &&
    isArray(containers) &&
    containers.some((c: any) => c?.name === OLIVE_ADMIN_CONTAINER)
  );
}

function listPods(exec: Exec): any[] {
  const r = exec(kubectlArgv(["-n", OLIVE_ADMIN_NS, "get", "pods", "-l", OLIVE_ADMIN_SELECTOR, "-o", "json"]), { signals: KUBECTL_TIMEOUT });
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

function findPod(exec: Exec): OliveSupervisorPod {
  const items = listPods(exec);
  if (items.length === 0) return { state: "absent", pods: 0 };
  const active = items.filter((p) => !finished(p));
  if (active.length === 0) return { state: "not-ready", pods: items.length };
  if (active.length > 1) return { state: "multiple", pods: active.length };
  const pod = active[0];
  if (present(pod.metadata.deletionTimestamp)) return { state: "terminating", pods: 1 };
  if (pod.status?.phase !== "Running" || !isReady(pod)) return { state: "not-ready", pods: 1 };
  return { state: "ready", pod: pod.metadata.name };
}

function adminArgv(pod: string, action: OliveAdminAction): string[] {
  if (typeof pod !== "string" || pod.length > 253 || !POD_NAME.test(pod)) throw new Error("감독 파드 이름 형식이 아니다");
  // --request-timeout은 -- 앞에 둔다(뒤에 두면 진입점의 인자가 된다).
  return ["kubectl", "-n", OLIVE_ADMIN_NS, "exec", pod, "-c", OLIVE_ADMIN_CONTAINER, REQUEST_TIMEOUT, "--", ...OLIVE_ADMIN_ENTRY, ...wordsOf(action)];
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
    doc = jsonParse(line);
  } catch {
    throw fail();
  }
  if (doc === null || typeof doc !== "object" || isArray(doc)) throw fail();
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
  return { pod: () => findPod(readExec), argv: adminArgv };
}

export function oliveAdminWrite(exec: Exec, readExec: Exec): OliveAdminWrite {
  return {
    ...oliveAdminRead(readExec),
    run(action): OliveAdminOutcome {
      wordsOf(action);
      let target: OliveSupervisorPod;
      try {
        target = findPod(readExec);
      } catch (e) {
        if (e instanceof ExecTimeout) return { state: "unknown" };
        throw e;
      }
      if (target.state !== "ready") return { state: "no-target", target };
      const r = exec(adminArgv(target.pod, action), { timeoutMs: EXEC_TIMEOUT_MS, signals: KUBECTL_TIMEOUT });
      if (timedOut(r)) return { state: "unknown" };
      if (r.code !== 0) throw new Error(`감독 관리 진입점이 실패했다(${failure(r)})`);
      return { state: "reported", pod: target.pod, status: parseStatus(r.stdout) };
    },
  };
}
