// 올리브 장부 초기화(D-110·D-176). 감독이 꺼진 것을 확인한 뒤 Argo CD 밖의 일회성 Job으로 감독 이미지의 초기화 진입점
// (bun src/main/ledger-init.ts, 인자 없음)을 한 번 돌리고, 파드의 종료 코드로 판정한 뒤 Job을 지운다.
// Job 모양은 여기 고정이다. 이미지·장부 경로·장부 PVC·서비스 계정·보안 칸·자원은 라이브 감독 Deployment에서 읽어 차트와 어긋나지 않게 한다.
// 함정: 이 Job은 차트 밖이라 렌더 CI가 보지 않는다. 모양은 CLI 시험(cli/test/commands/olive-ledger-init.test.ts)이 고정한다.
// 잠금은 둘이다. 쓰기 전 확인(감독 replicas 0·파드 0·정지 자물쇠 없음·olive-limits 사용량 0)과, limits를 감독과 같게 둬서
// olive-limits 쿼터(한도 = 감독 limits)가 감독 파드와 이 파드를 함께 띄우지 못하게 하는 것. 두 초기화 파드의 동시 실행도 같은 쿼터가 막는다.
// 감독 ns로 가는 다른 길(관리 진입점)은 olive-admin.ts에 있고, ns·Deployment·컨테이너 이름은 그 파일의 상수를 쓴다.
import type { OliveLedgerCheck, OliveLedgerCleanup, OliveLedgerInspection, OliveLedgerJob, OliveLedgerOutcome, OliveLedgerRead, OliveLedgerWrite } from "./command";
import { ExecTimeout, why, type Exec, type ExecResult } from "./exec";
import { entries, isArray, jsonParse, jsonStringify } from "./intrinsics";
import { kubeRead, kubectlArgv } from "./kubectl";
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

const NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const DIGEST_IMAGE = /^[a-z0-9][a-z0-9._\/:-]{0,200}@sha256:[0-9a-f]{64}$/;
// 절대 경로이고 . · .. 조각이 없다(감독의 settingsFromEnv는 상대 경로를 틀림으로 본다).
const ABS_PATH = /^(\/[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}){1,8}$/;
const QUANTITY = /^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|k|M|G|T)?$/;
const SHORT_WORD = /^[A-Za-z]{1,40}$/;
const POD_SC_KEYS = new Set(["runAsNonRoot", "runAsUser", "runAsGroup", "fsGroup", "seccompProfile"]);
const CONTAINER_SC_KEYS = new Set(["allowPrivilegeEscalation", "readOnlyRootFilesystem", "capabilities"]);
// 진입점이 0이 아닐 때 stderr에 쓰는 한 줄(olive src/main/ledger-init.ts의 say). 파드 상태의 message(FallbackToLogsOnError)에서 읽는다.
// 문구가 바뀌면 사유는 null이 되고 종료 코드만으로 말한다. 원문은 내지 않는다.
const INIT_LINE = /^olive ledger-init [0-9A-Za-z.+-]{1,40}: (.*)$/;
const INIT_REASONS: [RegExp, (m: RegExpExecArray) => string][] = [
  [/^장부를 만들지 못했다\(((?:open|close|deps):[a-z_]{1,40})\)$/, (m) => m[1] as string],
  [/^환경 OLIVE_LEDGER_DIR이\(가\) 없다$/, () => "env:missing"],
  [/^환경 OLIVE_LEDGER_DIR이\(가\) 틀렸다$/, () => "env:invalid"],
  [/^사용법: /, () => "usage"],
];

const present = (v: unknown) => v !== undefined && v !== null;
const isObj = (v: unknown): v is Record<string, any> => typeof v === "object" && v !== null && !isArray(v);
const isName = (v: unknown): v is string => typeof v === "string" && v.length <= 253 && NAME.test(v);
const posInt = (v: unknown, min: number) => Number.isSafeInteger(v) && (v as number) >= min;
const run = (exec: Exec, args: string[], opts: Parameters<Exec>[1] = {}) => exec(kubectlArgv(args), opts);

// 한 객체 읽기. 없으면 null, 시간 초과는 ExecTimeout, 그 밖의 실패와 다른 객체는 던진다.
function getDoc(exec: Exec, resource: string, name: string, kind: string): any | null {
  const r = run(exec, ["-n", OLIVE_ADMIN_NS, "get", resource, name, "-o", "json"]);
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
function listPods(exec: Exec, selector?: string): any[] {
  const r = run(exec, ["-n", OLIVE_ADMIN_NS, "get", "pods", ...(selector ? ["-l", selector] : []), "-o", "json"]);
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
  const quantities = (v: unknown, need: boolean) =>
    v === undefined ? !need : isObj(v) && Object.keys(v).every((k) => k === "cpu" || k === "memory") && (!need || (typeof v.cpu === "string" && typeof v.memory === "string")) && Object.values(v).every((q) => typeof q === "string" && QUANTITY.test(q));
  if (!isObj(res) || Object.keys(res).some((k) => k !== "limits" && k !== "requests") || !quantities(res.limits, true) || !quantities(res.requests, false)) return { problem: "resources" };
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

function inspect(exec: Exec): Inspected {
  const checks: OliveLedgerCheck[] = [];
  const add = (id: OliveLedgerCheck["id"], fail: string | null) => checks.push(fail === null ? { id, ok: true } : { id, ok: false, detail: fail });
  const context = kubeRead(exec).currentContext();
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
    const used = quota?.status?.used;
    const cpu = hard?.["limits.cpu"];
    const memory = hard?.["limits.memory"];
    // API 서버는 수량을 정규형으로 저장해 같은 값은 같은 글자다(500m·0.5 → 500m).
    if (job !== null && (cpu !== job.limits.cpu || memory !== job.limits.memory)) add("quota", "mismatch");
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

// 컨테이너 상태의 사유 낱말(kubelet이 정한 짧은 이름만, 예 ImagePullBackOff·OOMKilled). 모르는 꼴은 null.
const word = (v: unknown): string | null => (typeof v === "string" && SHORT_WORD.test(v) ? v : null);

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

function watchOnce(exec: Exec, uid: string): Watch {
  const j = getDoc(exec, "jobs.batch", LEDGER_INIT_JOB, "Job");
  if (j === null || j?.metadata?.uid !== uid) return { terminal: null, deadline: false, gone: true, pods: [], waiting: null };
  const failed = condition(j, "Failed");
  const terminal = condition(j, "Complete") ? "complete" : failed ? "failed" : null;
  const pods = listPods(exec, `batch.kubernetes.io/controller-uid=${uid}`);
  let waiting: string | null = null;
  for (const p of pods) {
    const cs = isArray(p?.status?.containerStatuses) ? p.status.containerStatuses.find((s: any) => s?.name === LEDGER_INIT_CONTAINER) : undefined;
    waiting = word(cs?.state?.waiting?.reason) ?? waiting;
  }
  return { terminal, deadline: failed?.reason === "DeadlineExceeded", gone: false, pods, waiting };
}

type Verdict = { state: "unknown"; why: string } | { state: "created" | "exists" } | { state: "failed"; code: number; reason: string | null; kubelet: string | null };

function judge(w: Watch): Verdict {
  if (w.deadline) return { state: "unknown", why: "deadline" };
  if (w.pods.length !== 1) return { state: "unknown", why: "pods" };
  const p = w.pods[0];
  const cs = isArray(p?.status?.containerStatuses) ? p.status.containerStatuses.filter((s: any) => s?.name === LEDGER_INIT_CONTAINER) : [];
  const t = cs.length === 1 ? cs[0]?.state?.terminated : undefined;
  const code = t?.exitCode;
  if (!Number.isInteger(code) || code < 0 || code > 255) return { state: "unknown", why: "no-exit" };
  // Job 상태와 종료 코드가 서로 맞을 때만 판정한다.
  if ((code === 0) !== (w.terminal === "complete")) return { state: "unknown", why: "mismatch" };
  if (code === 0) return { state: "created" };
  if (code === 90) return { state: "exists" };
  return { state: "failed", code, reason: initReason(t?.message), kubelet: word(t?.reason) };
}

export type OliveLedgerOpts = { pollMs?: number; capMs?: number };

export function oliveLedgerRead(readExec: Exec): OliveLedgerRead {
  return { inspect: () => publicView(inspect(readExec)) };
}

export function oliveLedgerWrite(exec: Exec, readExec: Exec, opts: OliveLedgerOpts = {}): OliveLedgerWrite {
  const pollMs = opts.pollMs ?? POLL_MS;
  const cap = (ms: number) => (opts.capMs !== undefined && opts.capMs > 0 ? Math.min(ms, opts.capMs) : ms);

  // 판정 뒤 Job을 지운다. 확인한 그 Job(uid)만, 파드까지 지우는 Foreground로 지우고 사라질 때까지 기다린다.
  // kubectl delete는 precondition을 넣지 않아 DeleteOptions를 --raw 본문으로 보낸다(kubectl.ts deleteRestoreObject와 같은 방식).
  const remove = (uid: string): OliveLedgerCleanup => {
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
    ...oliveLedgerRead(readExec),
    run(): OliveLedgerOutcome {
      const seen = inspect(readExec);
      if (seen.checks.some((c) => !c.ok) || seen.job === null || seen.manifest === null) return { state: "blocked", inspection: publicView(seen) };
      const job = seen.job;
      const x: ExecResult = run(exec, ["-n", OLIVE_ADMIN_NS, "create", "-f", "-", "-o", "json"], { input: jsonStringify(seen.manifest) });
      if (x.errKind === "timeout") return { state: "unknown", job, why: "create-timeout", waiting: null, cleanup: { state: "kept", why: "unknown" } };
      if (x.code !== 0) return { state: "not-created", job, why: /AlreadyExists/.test(x.stderr) ? "exists" : /Forbidden/.test(x.stderr) ? "forbidden" : `exit ${x.code}` };
      let created: any;
      try {
        created = jsonParse(x.stdout);
      } catch {
        created = null;
      }
      const uid = created?.metadata?.uid;
      if (created?.kind !== "Job" || created?.metadata?.name !== LEDGER_INIT_JOB || typeof uid !== "string" || !POD_UID.test(uid)) return { state: "unknown", job, why: "create-unread", waiting: null, cleanup: { state: "kept", why: "unknown" } };

      const until = Date.now() + cap(WAIT_MS);
      let w: Watch = { terminal: null, deadline: false, gone: false, pods: [], waiting: null };
      let unread = false;
      for (;;) {
        try {
          w = watchOnce(readExec, uid);
          unread = false;
        } catch {
          unread = true;
        }
        if (w.gone) return { state: "unknown", job, why: "gone", waiting: w.waiting, cleanup: { state: "deleted" } };
        if (!unread && w.terminal !== null) break;
        if (Date.now() + pollMs > until) {
          // 끝나지 않은 Job은 지우지 않는다(아직 쓰는 중일 수 있다). 기한이 끝내고 ttl이 치운다.
          return { state: "unknown", job, why: unread ? "unread" : "wait", waiting: w.waiting, cleanup: { state: "kept", why: unread ? "unread" : "running" } };
        }
        Bun.sleepSync(pollMs);
      }
      const verdict = judge(w);
      const cleanup = remove(uid);
      if (verdict.state === "unknown") return { state: "unknown", job, why: verdict.why, waiting: w.waiting, cleanup };
      if (verdict.state === "failed") return { state: "failed", job, code: verdict.code, reason: verdict.reason, kubelet: verdict.kubelet, cleanup };
      return verdict.state === "created" ? { state: "created", job, cleanup } : { state: "exists", job, cleanup };
    },
  };
}
