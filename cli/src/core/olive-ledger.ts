// 올리브 장부 초기화(D-110·D-176). 감독이 꺼진 것을 확인한 뒤 Argo CD 밖의 일회성 Job으로 감독 이미지의 초기화 진입점
// (bun src/main/ledger-init.ts, 인자 없음)을 한 번 돌리고, 파드의 종료 코드로 판정한 뒤 Job을 지운다.
// Job 모양은 여기 고정이다. 이미지·장부 경로·장부 PVC·서비스 계정·보안 칸·자원은 라이브 감독 Deployment에서 읽어 차트와 어긋나지 않게 한다.
// 함정: 이 Job은 차트 밖이라 렌더 CI가 보지 않는다. 모양은 CLI 시험(cli/test/commands/olive-ledger-init.test.ts)이 고정한다.
// 잠금은 둘이다. 쓰기 전 확인(감독 replicas 0·파드 0·정지 자물쇠 없음·olive-limits 사용량 0)과, limits를 감독과 같게 둬서
// olive-limits 쿼터(한도 = 감독 limits)가 감독 파드와 이 파드를 함께 띄우지 못하게 하는 것. 두 초기화 파드의 동시 실행도 같은 쿼터가 막는다.
// 함정: API 서버가 파드 생성을 심사하는 한도는 spec.hard가 아니라 쿼터 컨트롤러가 옮겨 적은 status.hard이고, 적용 범위(scopes·
// scopeSelector)가 붙은 쿼터는 맞는 파드만 센다. 그래서 두 번째 잠금은 status.hard = 감독 limits이고 범위가 없을 때만 믿는다.
// 감독 ns로 가는 다른 길(관리 진입점)은 olive-admin.ts에 있고, ns·Deployment·컨테이너 이름은 그 파일의 상수를 쓴다.
// 한 실행의 kubectl 호출은 시작에 한 번 읽은 문맥을 --context로 모두 받는다. 기본 문맥을 쓰면 확인한 클러스터와 Job을 만드는
// 클러스터가 그사이 바뀐 기본 문맥 때문에 달라질 수 있고, 같은 이름의 PVC가 있으면 확인하지 않은 장부를 초기화한다.
import type { OliveLedgerCheck, OliveLedgerCleanup, OliveLedgerInspection, OliveLedgerJob, OliveLedgerOutcome, OliveLedgerRead, OliveLedgerWrite } from "./command";
import { ExecTimeout, why, type Exec, type ExecResult } from "./exec";
import { entries, isArray, jsonParse, jsonStringify } from "./intrinsics";
import { kubectlArgv } from "./kubectl";
import { OLIVE_ADMIN_CONTAINER, OLIVE_ADMIN_DEPLOYMENT, OLIVE_ADMIN_NS } from "./olive-admin";
import { oliveRead, POD_UID } from "./olive";

export const LEDGER_INIT_JOB = "olive-ledger-init";
export const LEDGER_INIT_CONTAINER = "ledger-init";
export const LEDGER_INIT_ENTRY = ["bun", "src/main/ledger-init.ts"];
// 함정: app.kubernetes.io/component: supervisor와 app.kubernetes.io/instance를 쓰지 않는다. 앞의 것은 감독 Deployment 선택자·
// NetworkPolicy supervisor-from-clients와 겹치고, 뒤의 것은 Argo CD가 이 Job을 자기 리소스로 셀 수 있다.
export const LEDGER_INIT_LABELS: Readonly<Record<string, string>> = {
  "app.kubernetes.io/name": "olive",
  "app.kubernetes.io/component": "ledger-init",
  "app.kubernetes.io/part-of": "olive",
};
// 기한은 이미지 내려받기까지 넉넉히 둔다(초기화 자체는 몇 초). CLI는 기한보다 조금 더 기다려 Job 컨트롤러가 먼저 끝내게 한다:
// CLI가 먼저 포기하면 아직 쓰는 중일 수 있는 파드를 지우지 않고 남긴다.
export const LEDGER_INIT_DEADLINE_SEC = 300;
// CLI가 판정 전에 죽으면 끝난 Job을 이 시간 뒤 컨트롤러가 지운다(Argo CD 밖이라 ttl을 써도 다시 만들어지지 않는다).
export const LEDGER_INIT_TTL_SEC = 600;
const WAIT_MS = (LEDGER_INIT_DEADLINE_SEC + 30) * 1_000;
const DELETE_WAIT_MS = 60_000;
const POLL_MS = 2_000;
const LEDGER_ENV = "OLIVE_LEDGER_DIR";
const QUOTA = "olive-limits";
// 만들기 요청을 API 서버가 받지 않았다는 응답. 꼴은 kubectl 1.36.6의 cmd/util/helpers.go(checkErr·StandardErrorMessage)가 정한다:
// Invalid는 "The Job "이름" is invalid"(세부가 없으면 "The request is invalid"), Unauthorized는 "error: You must be logged in
// to the server (…)"로 나오고 "Error from server (이유)"로는 나오지 않는다. 이 밖의 실패는 만들었는지 모른다.
// 함정: 이 꼴은 stderr 첫 줄(kubectl이 고른 최상위 오류)에만 맞춘다. 뒤 줄은 서버가 붙인 세부라, InternalError·Timeout·
// 전송 오류 뒤에 Invalid 꼴이 와도 거절이 아니다(서버가 Job을 저장한 뒤 응답만 잃었을 수 있다). 첫 줄이 경고(Warning: …)여도
// 거절로 읽지 않아 결과 모름 쪽으로 기운다.
const REFUSED: [RegExp, "exists" | "forbidden" | "refused"][] = [
  [/^Error from server \(AlreadyExists\)/, "exists"],
  [/^Error from server \(Forbidden\)/, "forbidden"],
  [/^Error from server \((BadRequest|NotFound)\)/, "refused"],
  [new RegExp(`^The Job "${LEDGER_INIT_JOB}" is invalid(:|$)`), "refused"],
  [/^The request is invalid(:|$)/, "refused"],
  [/^error: You must be logged in to the server \(/, "refused"],
];
const topError = (stderr: string) => stderr.split("\n").find((l) => l.trim() !== "") ?? "";

const NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const DIGEST_IMAGE = /^[a-z0-9][a-z0-9._\/:-]{0,200}@sha256:[0-9a-f]{64}$/;
// 절대 경로이고 . · .. 조각이 없다(감독의 settingsFromEnv는 상대 경로를 틀림으로 본다).
const ABS_PATH = /^(\/[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}){1,8}$/;
const QUANTITY = /^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|k|M|G|T)?$/;
const POD_SC_KEYS = new Set(["runAsNonRoot", "runAsUser", "runAsGroup", "fsGroup", "seccompProfile"]);
const CONTAINER_SC_KEYS = new Set(["allowPrivilegeEscalation", "readOnlyRootFilesystem", "capabilities"]);
// 진입점이 0이 아닐 때 stderr에 쓰는 한 줄(olive src/main/ledger-init.ts의 say). 파드 상태의 message(FallbackToLogsOnError)에서 읽는다.
// 문구가 바뀌면 사유는 null이 되고 종료 코드만으로 말한다. 원문은 내지 않는다.
const INIT_LINE = /^olive ledger-init [0-9A-Za-z.+-]{1,40}: (.*)$/;
// 94의 사유는 진입점이 실제로 내는 것만 받는다(olive src/main/ledger-init.ts의 failed 호출과 src/ledger/errors.ts의 UNAVAILABLE_REASONS).
// already_initialized는 90이라 없다. 목록 밖 낱말은 null(사유를 읽지 못함)이다: 출력에 실을 낱말을 진입점 문구가 정하지 않게 한다.
const OPEN_REASONS = ["locked", "corrupt", "full", "io", "too_new", "migration_mismatch", "migration_failed", "not_initialized", "foreign_data", "interrupted_install", "closed", "db_error", "threw", "unreadable"];
const INIT_FAILURES = new Set([...OPEN_REASONS.map((r) => `open:${r}`), "close:threw", "deps:threw"]);
// 표시할 kubelet 사유(컨테이너 상태의 terminated.reason·waiting.reason). 목록 밖은 null이다.
const TERMINATED_REASONS = new Set(["Completed", "Error", "OOMKilled", "ContainerCannotRun", "DeadlineExceeded", "StartError"]);
const WAITING_REASONS = new Set(["ContainerCreating", "PodInitializing", "ErrImagePull", "ImagePullBackOff", "ErrImageNeverPull", "InvalidImageName", "ImageInspectError", "RegistryUnavailable", "SignatureValidationFailed", "CreateContainerConfigError", "CreateContainerError", "PreStartHookError", "PostStartHookError", "RunContainerError", "CrashLoopBackOff"]);
const INIT_REASONS: [RegExp, (m: RegExpExecArray) => string | null][] = [
  [/^장부를 만들지 못했다\(((?:open|close|deps):[a-z_]{1,40})\)$/, (m) => (INIT_FAILURES.has(m[1] as string) ? (m[1] as string) : null)],
  [/^환경 OLIVE_LEDGER_DIR이\(가\) 없다$/, () => "env:missing"],
  [/^환경 OLIVE_LEDGER_DIR이\(가\) 틀렸다$/, () => "env:invalid"],
  [/^사용법: /, () => "usage"],
];

const present = (v: unknown) => v !== undefined && v !== null;
const isObj = (v: unknown): v is Record<string, any> => typeof v === "object" && v !== null && !isArray(v);
const isName = (v: unknown): v is string => typeof v === "string" && v.length <= 253 && NAME.test(v);
const posInt = (v: unknown, min: number) => Number.isSafeInteger(v) && (v as number) >= min;
const run = (exec: Exec, args: string[], opts: Parameters<Exec>[1] = {}) => exec(kubectlArgv(args), opts);
// 문맥 이름은 kubeconfig 맵의 키라 한글·공백도 그대로 이름이다. 다듬으면(trim 등) 다른 문맥을 고를 수 있다.
// 제어 문자(줄바꿈 포함)와 U+FFFD(UTF-8로 읽지 못한 바이트)가 있으면 그 이름을 그대로 옮겼다고 볼 수 없어 받지 않는다.
const BAD_CONTEXT = /[\p{Cc}\uFFFD]/u;

// kubectl config current-context는 이름 뒤에 줄바꿈 하나를 붙여 낸다. 그 하나만 떼고, 줄바꿈이 없으면 잘린 출력일 수 있어 받지 않는다.
function currentContext(exec: Exec): string | null {
  const r = exec(["kubectl", "config", "current-context"]);
  if (r.errKind === "not-found") throw new Error("kubectl이 없다");
  if (r.code !== 0 || !r.stdout.endsWith("\n")) return null;
  const name = r.stdout.slice(0, -1);
  return name !== "" && !BAD_CONTEXT.test(name) ? name : null;
}

// 받은 exec의 kubectl 호출마다 같은 문맥을 붙인다. olive.ts의 자물쇠 조회도 이 exec를 받아 같은 문맥으로 간다.
function pinned(exec: Exec, context: string): Exec {
  return (argv, opts) => {
    if (argv[0] !== "kubectl") throw new Error("장부 초기화는 kubectl만 부른다");
    return exec(["kubectl", `--context=${context}`, ...argv.slice(1)], opts);
  };
}

// 한 객체 읽기. 없으면 null, 시간 초과는 ExecTimeout, 그 밖의 실패와 다른 객체는 던진다.
function getDoc(exec: Exec, resource: string, name: string, kind: string, opts: Parameters<Exec>[1] = {}): any | null {
  const r = run(exec, ["-n", OLIVE_ADMIN_NS, "get", resource, name, "-o", "json"], opts);
  if (r.errKind === "timeout") throw new ExecTimeout(`${kind} ${name}: 시간 초과(결과 미상)`);
  if (r.code !== 0 && r.notFound) return null;
  if (r.code !== 0) throw new Error(`${kind} ${name}을 읽지 못했다(${why(r)})`);
  let doc: any;
  try {
    doc = jsonParse(r.stdout);
  } catch {
    throw new Error(`${kind} ${name}을 읽지 못했다(응답이 JSON이 아니다)`);
  }
  if (doc?.kind !== kind || doc?.metadata?.name !== name || doc?.metadata?.namespace !== OLIVE_ADMIN_NS) throw new Error(`${kind} ${name}: 응답이 그 객체가 아니다`);
  return doc;
}

// 파드 목록. 다른 종류의 빈 목록이나 남은 페이지가 있는 부분 목록을 "파드 0개"로 읽지 않는다.
function listPods(exec: Exec, selector?: string, opts: Parameters<Exec>[1] = {}): any[] {
  const r = run(exec, ["-n", OLIVE_ADMIN_NS, "get", "pods", ...(selector ? ["-l", selector] : []), "-o", "json"], opts);
  if (r.errKind === "timeout") throw new ExecTimeout("파드 목록: 시간 초과(결과 미상)");
  if (r.code !== 0) throw new Error(`파드 목록을 읽지 못했다(${why(r)})`);
  let doc: any;
  try {
    doc = jsonParse(r.stdout);
  } catch {
    throw new Error("파드 목록을 읽지 못했다(응답이 JSON이 아니다)");
  }
  if ((doc?.kind !== "List" && doc?.kind !== "PodList") || !isArray(doc?.items)) throw new Error("파드 목록을 읽지 못했다(파드 목록 응답이 아니다)");
  if (present(doc?.metadata?.continue) && doc.metadata.continue !== "") throw new Error("파드 목록을 읽지 못했다(남은 페이지가 있는 부분 목록이다)");
  for (const p of doc.items) {
    if (!(p?.kind === "Pod" || (doc.kind === "PodList" && p?.kind === undefined)) || !isName(p?.metadata?.name) || p?.metadata?.namespace !== OLIVE_ADMIN_NS) throw new Error("파드 목록을 읽지 못했다(파드가 아닌 항목이 있다)");
  }
  return doc.items;
}

const finished = (p: any) => (p?.status?.phase === "Succeeded" || p?.status?.phase === "Failed") && !present(p?.metadata?.deletionTimestamp);
const labelsMatch = (p: any, want: Record<string, string>) => entries(want).every(([k, v]) => p?.metadata?.labels?.[k] === v);
const mountsClaim = (p: any, claim: string) => isArray(p?.spec?.volumes) && p.spec.volumes.some((v: any) => v?.persistentVolumeClaim?.claimName === claim);

type Shape = { job: OliveLedgerJob; manifest: Record<string, unknown> } | { problem: string };

// 감독 Deployment의 파드 템플릿에서 초기화 Job을 만든다. 모르는 칸이 있으면 빼고 만들지 않고 어긋남으로 낸다
// (보안 칸을 말없이 떨어뜨린 파드를 띄우지 않게).
function shapeFrom(d: any): Shape {
  const spec = d?.spec?.template?.spec;
  if (!isObj(spec) || !isArray(spec.containers)) return { problem: "파드 템플릿" };
  const c = spec.containers.find((x: any) => x?.name === OLIVE_ADMIN_CONTAINER);
  if (!isObj(c)) return { problem: "감독 컨테이너" };
  const image = c.image;
  if (typeof image !== "string" || !DIGEST_IMAGE.test(image)) return { problem: "image" };
  const env = isArray(c.env) ? c.env.filter((e: any) => e?.name === LEDGER_ENV) : [];
  if (env.length !== 1 || present(env[0].valueFrom) || typeof env[0].value !== "string" || !ABS_PATH.test(env[0].value)) return { problem: LEDGER_ENV };
  const ledgerDir: string = env[0].value;
  const mounts = isArray(c.volumeMounts) ? c.volumeMounts : [];
  const ledgerMount = mounts.filter((m: any) => m?.mountPath === ledgerDir && !present(m?.subPath) && !present(m?.subPathExpr));
  if (ledgerMount.length !== 1 || ledgerMount[0].readOnly === true) return { problem: "장부 마운트" };
  const volumes = isArray(spec.volumes) ? spec.volumes : [];
  const ledgerVolume = volumes.find((v: any) => v?.name === ledgerMount[0].name);
  const pvc = ledgerVolume?.persistentVolumeClaim?.claimName;
  if (!isName(pvc) || ledgerVolume.persistentVolumeClaim.readOnly === true) return { problem: "장부 PVC" };
  const tmpMount = mounts.filter((m: any) => m?.mountPath === "/tmp" && !present(m?.subPath));
  const tmpVolume = tmpMount.length === 1 ? volumes.find((v: any) => v?.name === tmpMount[0].name) : undefined;
  const emptyDir = tmpVolume?.emptyDir;
  if (!isObj(emptyDir) || Object.keys(emptyDir).some((k) => k !== "sizeLimit" && k !== "medium")) return { problem: "/tmp 볼륨" };
  const psc = spec.securityContext;
  if (!isObj(psc) || Object.keys(psc).some((k) => !POD_SC_KEYS.has(k))) return { problem: "파드 securityContext" };
  const podOk =
    psc.runAsNonRoot === true &&
    posInt(psc.runAsUser, 1) &&
    posInt(psc.runAsGroup, 1) &&
    (psc.fsGroup === undefined || posInt(psc.fsGroup, 1)) &&
    isObj(psc.seccompProfile) &&
    Object.keys(psc.seccompProfile).length === 1 &&
    psc.seccompProfile.type === "RuntimeDefault";
  if (!podOk) return { problem: "파드 securityContext" };
  const csc = c.securityContext;
  if (!isObj(csc) || Object.keys(csc).some((k) => !CONTAINER_SC_KEYS.has(k))) return { problem: "컨테이너 securityContext" };
  const caps = csc.capabilities;
  const containerOk =
    csc.allowPrivilegeEscalation === false &&
    csc.readOnlyRootFilesystem === true &&
    isObj(caps) &&
    Object.keys(caps).length === 1 &&
    isArray(caps.drop) &&
    caps.drop.length === 1 &&
    caps.drop[0] === "ALL";
  if (!containerOk) return { problem: "컨테이너 securityContext" };
  const res = c.resources;
  const zero = (q: unknown) => typeof q === "string" && /^0+(\.0+)?[A-Za-z]*$/.test(q);
  const quantities = (v: unknown, need: boolean) =>
    v === undefined ? !need : isObj(v) && Object.keys(v).every((k) => k === "cpu" || k === "memory") && (!need || (typeof v.cpu === "string" && typeof v.memory === "string")) && Object.values(v).every((q) => typeof q === "string" && QUANTITY.test(q));
  if (!isObj(res) || Object.keys(res).some((k) => k !== "limits" && k !== "requests") || !quantities(res.limits, true) || !quantities(res.requests, false)) return { problem: "resources" };
  // 초기화는 CPU와 메모리 둘 다 양수 한도를 요구한다. 쿼터는 증가분에서 수량 0인 자원을 빼고 남은 자원만 한도와 비교하고,
  // 이 차트의 olive-limits는 파드 수를 세지 않는다. 둘 다 0이면 아무것도 세지 않아 감독과 초기화 파드가 함께 떠도 막지 못한다.
  // 하나만 0이면 남은 자원으로는 막지만, 두 번째 잠금이 가정하는 한도(두 자원 모두 감독 limits)와 다르다.
  if (zero(res.limits.cpu) || zero(res.limits.memory)) return { problem: "zero-limits" };
  const sa = spec.serviceAccountName;
  if (sa !== undefined && !isName(sa)) return { problem: "serviceAccountName" };
  const job: OliveLedgerJob = {
    namespace: OLIVE_ADMIN_NS,
    name: LEDGER_INIT_JOB,
    image,
    ledgerDir,
    pvc,
    limits: { cpu: res.limits.cpu, memory: res.limits.memory },
    deadlineSec: LEDGER_INIT_DEADLINE_SEC,
    ttlSec: LEDGER_INIT_TTL_SEC,
  };
  const manifest = {
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: { name: LEDGER_INIT_JOB, namespace: OLIVE_ADMIN_NS, labels: { ...LEDGER_INIT_LABELS } },
    spec: {
      // 한 번만 돈다. 0·90 밖의 코드에서 다시 돌지 않게 해 사람이 사유를 읽게 한다(94를 자동으로 다시 돌리지 않는다).
      backoffLimit: 0,
      parallelism: 1,
      completions: 1,
      activeDeadlineSeconds: LEDGER_INIT_DEADLINE_SEC,
      ttlSecondsAfterFinished: LEDGER_INIT_TTL_SEC,
      template: {
        metadata: { labels: { ...LEDGER_INIT_LABELS } },
        spec: {
          restartPolicy: "Never",
          ...(sa === undefined ? {} : { serviceAccountName: sa }),
          automountServiceAccountToken: false,
          enableServiceLinks: false,
          securityContext: { ...psc, seccompProfile: { type: "RuntimeDefault" } },
          containers: [
            {
              name: LEDGER_INIT_CONTAINER,
              image,
              command: [...LEDGER_INIT_ENTRY],
              env: [{ name: LEDGER_ENV, value: ledgerDir }],
              securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } },
              resources: { limits: { ...res.limits }, ...(res.requests === undefined ? {} : { requests: { ...res.requests } }) },
              // 실패 때 진입점의 stderr 한 줄이 파드 상태의 message로 온다. Job을 지운 뒤에는 로그가 없어 판정 때 여기서 읽는다.
              terminationMessagePolicy: "FallbackToLogsOnError",
              volumeMounts: [
                { name: "ledger", mountPath: ledgerDir },
                { name: "tmp", mountPath: "/tmp" },
              ],
            },
          ],
          volumes: [
            // WaitForFirstConsumer면 이 파드가 PVC를 노드에 묶는다. 단일 노드라 감독도 같은 노드다.
            { name: "ledger", persistentVolumeClaim: { claimName: pvc } },
            { name: "tmp", emptyDir: { ...emptyDir } },
          ],
        },
      },
    },
  };
  return { job, manifest };
}

type Inspected = OliveLedgerInspection & { manifest: Record<string, unknown> | null };

// 쿼터 비교에 쓰는 감독 limits. Job 모양과 따로 읽어, 모양을 거절한 경우(한도 0 등)에도 쿼터 한도를 비교한다.
function supervisorLimits(d: any): { cpu: string; memory: string } | null {
  const c = isArray(d?.spec?.template?.spec?.containers) ? d.spec.template.spec.containers.find((x: any) => x?.name === OLIVE_ADMIN_CONTAINER) : undefined;
  const l = c?.resources?.limits;
  return isObj(l) && typeof l.cpu === "string" && typeof l.memory === "string" && QUANTITY.test(l.cpu) && QUANTITY.test(l.memory) ? { cpu: l.cpu, memory: l.memory } : null;
}

// 문맥을 정하지 못하면 다른 것을 읽지 않는다(context null, 확인 없음, job 없음). 명령은 이것을 만들지 않음으로 말한다.
function inspect(readExec: Exec): Inspected {
  const checks: OliveLedgerCheck[] = [];
  const add = (id: OliveLedgerCheck["id"], fail: string | null) => checks.push(fail === null ? { id, ok: true } : { id, ok: false, detail: fail });
  const context = currentContext(readExec);
  if (context === null) return { context: null, namespace: OLIVE_ADMIN_NS, deployment: OLIVE_ADMIN_DEPLOYMENT, checks, job: null, manifest: null };
  const exec = pinned(readExec, context);
  const d = getDoc(exec, "deployments.apps", OLIVE_ADMIN_DEPLOYMENT, "Deployment");
  const pods = listPods(exec);
  const lock = oliveRead(exec).stopLock(OLIVE_ADMIN_NS);
  const leftJob = getDoc(exec, "jobs.batch", LEDGER_INIT_JOB, "Job");
  const quota = getDoc(exec, "resourcequotas", QUOTA, "ResourceQuota");
  let job: OliveLedgerJob | null = null;
  let manifest: Record<string, unknown> | null = null;

  add("deployment", d === null ? "absent" : null);
  if (d !== null) {
    const want = d?.spec?.replicas;
    add("replicas", want === 0 ? null : String(want ?? "unread"));
    // status.replicas는 0이면 응답에서 빠진다. 컨트롤러가 지금 spec을 본 뒤의 status만 믿는다.
    const observed = posInt(d?.status?.observedGeneration, 0) && posInt(d?.metadata?.generation, 0) && d.status.observedGeneration >= d.metadata.generation;
    const live = d?.status?.replicas ?? 0;
    add("rollout", observed && live === 0 ? null : observed ? String(live) : "unobserved");
    const selector = d?.spec?.selector?.matchLabels;
    // 내려가는 중인 감독 파드도 센다(장부를 쥐고 있을 수 있다). 끝난 파드(쫓겨남 등)는 프로세스가 없고 쿼터도 세지 않는데,
    // Deployment를 0으로 내려도 지워지지 않고 남아 세면 영영 대기가 된다.
    const sup = isObj(selector) && Object.keys(selector).length > 0 ? pods.filter((p) => labelsMatch(p, selector) && !finished(p)) : null;
    add("supervisor-pods", sup === null ? "selector" : sup.length === 0 ? null : String(sup.length));
    const shape = shapeFrom(d);
    if ("problem" in shape) add("shape", shape.problem);
    else {
      add("shape", null);
      job = shape.job;
      manifest = shape.manifest;
      const others = pods.filter((p) => !finished(p) && mountsClaim(p, shape.job.pvc) && !(sup ?? []).includes(p));
      add("ledger-users", others.length === 0 ? null : String(others.length));
      const pvc = getDoc(exec, "persistentvolumeclaims", shape.job.pvc, "PersistentVolumeClaim");
      add("pvc", pvc === null ? "absent" : present(pvc?.metadata?.deletionTimestamp) ? "deleting" : null);
    }
  }
  add("stop-lock", lock === "absent" ? null : lock);
  // 손으로 띄운 일회성 초기화 파드도 같은 이름·라벨을 쓴다.
  const leftPods = pods.filter((p) => labelsMatch(p, LEDGER_INIT_LABELS) || p.metadata.name === LEDGER_INIT_JOB || p.metadata.name.startsWith(`${LEDGER_INIT_JOB}-`));
  add("leftover", leftJob !== null ? "job" : leftPods.length > 0 ? `pods ${leftPods.length}` : null);
  if (quota === null) add("quota", "absent");
  else {
    const hard = quota?.spec?.hard;
    const enforced = quota?.status?.hard;
    const used = quota?.status?.used;
    const scopes = quota?.spec?.scopes;
    // 차트의 olive-limits에는 범위가 없다. 범위가 붙으면 감독·초기화 파드를 세지 않을 수 있다(olive.ts lockState와 같은 판정).
    const scoped = !(scopes === undefined || (isArray(scopes) && scopes.length === 0)) || present(quota?.spec?.scopeSelector);
    const limits = d === null ? null : supervisorLimits(d);
    const same = (h: any) => limits !== null && isObj(h) && h["limits.cpu"] === limits.cpu && h["limits.memory"] === limits.memory;
    // 지워지는 쿼터는 곧 사라지고 되살릴 수 없다. API 서버는 수량을 정규형으로 저장해 같은 값은 같은 글자다(500m·0.5 → 500m).
    if (present(quota?.metadata?.deletionTimestamp)) add("quota", "deleting");
    else if (scoped) add("quota", "scoped");
    // 감독 limits를 읽지 못하면 비교하지 못한 것이다. 맞음으로 세지 않는다.
    else if (limits === null) add("quota", "unchecked");
    else if (!same(hard)) add("quota", "mismatch");
    // status.hard는 컨트롤러가 spec을 반영한 뒤에 바뀐다. 반영 전에는 옛 한도로 심사하므로 기다린다.
    else if (!same(enforced)) add("quota", "enforcing");
    else if (!isObj(used) || !present(used["limits.cpu"]) || !present(used["limits.memory"])) add("quota", "unread");
    else add("quota", used["limits.cpu"] === "0" && used["limits.memory"] === "0" ? null : "used");
  }
  return { context, namespace: OLIVE_ADMIN_NS, deployment: OLIVE_ADMIN_DEPLOYMENT, checks, job, manifest };
}

const publicView = (x: Inspected): OliveLedgerInspection => ({ context: x.context, namespace: x.namespace, deployment: x.deployment, checks: x.checks, job: x.job });

function condition(job: any, type: string): any | null {
  const list = job?.status?.conditions;
  return isArray(list) ? (list.find((c: any) => c?.type === type && c?.status === "True") ?? null) : null;
}

const word = (v: unknown, known: Set<string>): string | null => (typeof v === "string" && known.has(v) ? v : null);

// 종료 코드를 읽을 파드는 만든 그 Job이 제어하는 파드뿐이다. 컨트롤러 uid 라벨은 누구나 붙일 수 있어 제어 참조로 대조한다(olive-admin.ts와 같은 방식).
function ownedBy(p: any, uid: string): boolean {
  const refs = p?.metadata?.ownerReferences;
  const ctl = isArray(refs) ? refs.filter((r: any) => r?.controller === true) : [];
  if (ctl.length !== 1) return false;
  const r = ctl[0];
  return r?.apiVersion === "batch/v1" && r?.kind === "Job" && r?.name === LEDGER_INIT_JOB && r?.uid === uid;
}

function initReason(message: unknown): string | null {
  if (typeof message !== "string" || message.length > 4_096) return null;
  const lines = message.split("\n").map((l) => l.trim()).filter((l) => l !== "");
  const m = INIT_LINE.exec(lines.at(-1) ?? "");
  if (m === null) return null;
  for (const [re, pick] of INIT_REASONS) {
    const hit = re.exec(m[1] as string);
    if (hit) return pick(hit);
  }
  return null;
}

type Watch = { terminal: "complete" | "failed" | null; deadline: boolean; gone: boolean; pods: any[]; waiting: string | null };

// left는 조회마다의 남은 시간(ms)이다. 조회 자체도 기다림 상한 안에 끝나게 실행 제한으로 넘긴다.
// ended는 같은 UID의 Job이 끝났다고 읽은 관측을 받는다. 뒤의 파드 조회가 끊겨 이 조회의 Watch가 돌아오지 않아도 그 사실은 남긴다.
function watchOnce(exec: Exec, uid: string, left: () => number, ended: { terminal: "complete" | "failed" | null }): Watch {
  const j = getDoc(exec, "jobs.batch", LEDGER_INIT_JOB, "Job", { timeoutMs: Math.max(1, left()) });
  if (j === null || j?.metadata?.uid !== uid) return { terminal: null, deadline: false, gone: true, pods: [], waiting: null };
  const failed = condition(j, "Failed");
  const terminal = condition(j, "Complete") ? "complete" : failed ? "failed" : null;
  if (terminal !== null) ended.terminal = terminal;
  const pods = listPods(exec, `batch.kubernetes.io/controller-uid=${uid}`, { timeoutMs: Math.max(1, left()) });
  let waiting: string | null = null;
  for (const p of pods) {
    if (!ownedBy(p, uid)) continue;
    const cs = isArray(p?.status?.containerStatuses) ? p.status.containerStatuses.find((s: any) => s?.name === LEDGER_INIT_CONTAINER) : undefined;
    waiting = word(cs?.state?.waiting?.reason, WAITING_REASONS) ?? waiting;
  }
  return { terminal, deadline: failed?.reason === "DeadlineExceeded", gone: false, pods, waiting };
}

type Verdict = { state: "unknown"; why: string } | { state: "created" | "exists" } | { state: "failed"; code: number; reason: string | null; kubelet: string | null };

function judge(w: Watch, uid: string): Verdict {
  if (w.deadline) return { state: "unknown", why: "deadline" };
  if (w.pods.length !== 1) return { state: "unknown", why: "pods" };
  const p = w.pods[0];
  if (!ownedBy(p, uid)) return { state: "unknown", why: "not-owned" };
  const cs = isArray(p?.status?.containerStatuses) ? p.status.containerStatuses.filter((s: any) => s?.name === LEDGER_INIT_CONTAINER) : [];
  const t = cs.length === 1 ? cs[0]?.state?.terminated : undefined;
  const code = t?.exitCode;
  if (!Number.isInteger(code) || code < 0 || code > 255) return { state: "unknown", why: "no-exit" };
  // Job 상태와 종료 코드가 서로 맞을 때만 판정한다.
  if ((code === 0) !== (w.terminal === "complete")) return { state: "unknown", why: "mismatch" };
  if (code === 0) return { state: "created" };
  if (code === 90) return { state: "exists" };
  return { state: "failed", code, reason: initReason(t?.message), kubelet: word(t?.reason, TERMINATED_REASONS) };
}

export type OliveLedgerOpts = { pollMs?: number; capMs?: number };

export function oliveLedgerRead(readExec: Exec): OliveLedgerRead {
  return { inspect: () => publicView(inspect(readExec)) };
}

export function oliveLedgerWrite(writeExec: Exec, baseReadExec: Exec, opts: OliveLedgerOpts = {}): OliveLedgerWrite {
  const pollMs = opts.pollMs ?? POLL_MS;
  const cap = (ms: number) => (opts.capMs !== undefined && opts.capMs > 0 ? Math.min(ms, opts.capMs) : ms);

  // 판정 뒤 Job을 지운다. 확인한 그 Job(uid)만, 파드까지 지우는 Foreground로 지우고 사라질 때까지 기다린다.
  // kubectl delete는 precondition을 넣지 않아 DeleteOptions를 --raw 본문으로 보낸다(kubectl.ts deleteRestoreObject와 같은 방식).
  const remove = (exec: Exec, readExec: Exec, uid: string): OliveLedgerCleanup => {
    const body = jsonStringify({ kind: "DeleteOptions", apiVersion: "v1", propagationPolicy: "Foreground", preconditions: { uid } });
    const x = run(exec, ["delete", "--raw", `/apis/batch/v1/namespaces/${OLIVE_ADMIN_NS}/jobs/${LEDGER_INIT_JOB}`, "-f", "-"], { input: body, secretStdout: true, signals: { conflict: /Precondition failed|\(Conflict\)/ } });
    if (x.errKind === "timeout") return { state: "failed", why: "timeout" };
    if (x.signals?.includes("conflict")) return { state: "failed", why: "changed" };
    if (x.code !== 0 && !x.notFound) return { state: "failed", why: `exit ${x.code}` };
    const until = Date.now() + cap(DELETE_WAIT_MS);
    for (;;) {
      let now: any;
      try {
        now = getDoc(readExec, "jobs.batch", LEDGER_INIT_JOB, "Job");
      } catch {
        return { state: "failed", why: "unread" };
      }
      if (now === null || now?.metadata?.uid !== uid) return { state: "deleted" };
      if (Date.now() + pollMs > until) return { state: "failed", why: "still-there" };
      Bun.sleepSync(pollMs);
    }
  };

  return {
    ...oliveLedgerRead(baseReadExec),
    run(): OliveLedgerOutcome {
      const seen = inspect(baseReadExec);
      if (seen.context === null || seen.checks.some((c) => !c.ok) || seen.job === null || seen.manifest === null) return { state: "blocked", inspection: publicView(seen) };
      const job = seen.job;
      // 확인에 쓴 그 문맥으로만 만들고, 기다리고, 지운다.
      const exec = pinned(writeExec, seen.context);
      const readExec = pinned(baseReadExec, seen.context);
      const x: ExecResult = run(exec, ["-n", OLIVE_ADMIN_NS, "create", "-f", "-", "-o", "json"], { input: jsonStringify(seen.manifest) });
      if (x.errKind === "timeout") return { state: "unknown", job, why: "create-timeout", waiting: null, cleanup: { state: "kept", why: "unknown" } };
      // kubectl을 띄우지 못했으면 요청이 나가지 않았다.
      if (x.errKind === "not-found" || x.errKind === "spawn") return { state: "not-created", job, why: "not-run" };
      if (x.code !== 0) {
        // 만들지 않았다고 말할 수 있는 것은 API 서버가 요청을 거절했다는 응답뿐이다. 응답 기한·EOF·연결 끊김·서버 오류는
        // 서버가 Job을 저장한 뒤 응답만 잃었을 수 있어 결과 모름이고, uid가 없으니 지우거나 다시 만들지 않는다.
        const top = topError(x.stderr);
        const refused = REFUSED.find(([re]) => re.test(top))?.[1];
        if (refused === undefined) return { state: "unknown", job, why: "create-lost", waiting: null, cleanup: { state: "kept", why: "unknown" } };
        return { state: "not-created", job, why: refused };
      }
      let created: any;
      try {
        created = jsonParse(x.stdout);
      } catch {
        created = null;
      }
      const uid = created?.metadata?.uid;
      if (created?.kind !== "Job" || created?.metadata?.name !== LEDGER_INIT_JOB || typeof uid !== "string" || !POD_UID.test(uid)) return { state: "unknown", job, why: "create-unread", waiting: null, cleanup: { state: "kept", why: "unknown" } };

      const until = Date.now() + cap(WAIT_MS);
      const left = () => until - Date.now();
      let w: Watch = { terminal: null, deadline: false, gone: false, pods: [], waiting: null };
      // 아직 한 번도 끝까지 읽지 못한 처음 상태다. 첫 조회가 상한에 끊겨도 "끝나지 않았다"로 읽지 않게 읽지 못함에서 시작한다.
      let unread = true;
      const ended: { terminal: "complete" | "failed" | null } = { terminal: null };
      for (;;) {
        try {
          w = watchOnce(readExec, uid, left, ended);
          unread = false;
        } catch (e) {
          // 남은 시간을 다 써서 끊긴 조회는 새 관측이 아니다. 그 앞 조회의 결과(읽음·읽지 못함·아직 못 읽음)를 그대로 둔다.
          if (!(e instanceof ExecTimeout && left() <= 0)) unread = true;
        }
        if (w.gone) return { state: "unknown", job, why: "gone", waiting: w.waiting, cleanup: { state: "deleted" } };
        if (!unread && w.terminal !== null) break;
        if (Date.now() + pollMs > until) {
          // Job이 끝난 것은 읽었는데 파드 종료 코드를 끝내 읽지 못했다. "아직 끝나지 않았다"가 아니다. 지우면 파드까지 사라져
          // 사람이 종료 코드를 확인할 수 없어 남긴다(ttl이 치운다).
          if (ended.terminal !== null) return { state: "unknown", job, why: `${ended.terminal}-unread`, waiting: w.waiting, cleanup: { state: "kept", why: "exit-unread" } };
          // 끝나지 않은 Job은 지우지 않는다(아직 쓰는 중일 수 있다). 기한이 끝내고 ttl이 치운다.
          return { state: "unknown", job, why: unread ? "unread" : "wait", waiting: w.waiting, cleanup: { state: "kept", why: unread ? "unread" : "running" } };
        }
        Bun.sleepSync(pollMs);
      }
      // 상한 뒤에 끝난 관측은 판정에 쓰지 않는다(상한은 조회 시간까지 센다). 끝난 Job이라 지우기는 하고, 그 기다림은 따로 센다.
      const verdict: Verdict = left() < 0 ? { state: "unknown", why: "wait" } : judge(w, uid);
      const cleanup = remove(exec, readExec, uid);
      if (verdict.state === "unknown") return { state: "unknown", job, why: verdict.why, waiting: w.waiting, cleanup };
      if (verdict.state === "failed") return { state: "failed", job, code: verdict.code, reason: verdict.reason, kubelet: verdict.kubelet, cleanup };
      return verdict.state === "created" ? { state: "created", job, cleanup } : { state: "exists", job, cleanup };
    },
  };
}
