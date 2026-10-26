// kubectl 어댑터. 사람의 kubeconfig와 현재 context를 그대로 쓴다(자격을 저장하지 않는다).
// argv는 여기서만 만든다. 리소스는 KINDS 표의 이름뿐이라 범용 조회로 Secret을 읽을 수 없고(#873 2라운드 P1),
// --raw·config view 같은 원문 출력 옵션은 쓰지 않는다. 모든 호출에 --request-timeout(서버가 멈추면 기본으로 오래 기다린다).
import { entries, isArray, jsonParse, jsonStringify, strIncludes } from "./intrinsics";
import type { KubeKind, KubeRead, KubeWrite, LogTarget, RestoreRecord, RestoreRecordName } from "./command";
import { ExecTimeout, must, why, type Exec, type ExecOpts } from "./exec";
import { findSecretPath } from "./guard";
import { hasControl } from "./names";
import { Secret, isSecret, revealSecret } from "./secret";

const REQUEST_TIMEOUT = "--request-timeout=20s";
const NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;
const SELECTOR = /^[A-Za-z0-9./_-]+(=[A-Za-z0-9._-]*)?(,[A-Za-z0-9./_-]+(=[A-Za-z0-9._-]*)?)*$/;

export const KINDS: Record<KubeKind, string> = {
  deployment: "deployments.apps",
  pod: "pods",
  statefulset: "statefulsets.apps",
  job: "jobs.batch",
  cronjob: "cronjobs.batch",
  service: "services",
  ingress: "ingresses.networking.k8s.io",
  pvc: "persistentvolumeclaims",
  pv: "persistentvolumes",
  namespace: "namespaces",
  networkpolicy: "networkpolicies.networking.k8s.io",
  externalsecret: "externalsecrets.external-secrets.io",
  application: "applications.argoproj.io",
  cluster: "clusters.postgresql.cnpg.io",
  backup: "backups.postgresql.cnpg.io",
  scheduledbackup: "scheduledbackups.postgresql.cnpg.io",
  database: "databases.postgresql.cnpg.io",
  databaserole: "databaseroles.postgresql.cnpg.io",
  event: "events",
  clustersecretstore: "clustersecretstores.external-secrets.io",
  node: "nodes",
  objectstore: "objectstores.barmancloud.cnpg.io",
};

// 기다림 간격. 시험은 HOMELAB_TEST_POLL_MS로 줄인다(runtime.ts).
export type KubeOpts = { pollMs?: number };
const POLL_MS = 2_000;
const SECRETS_RV = "homelab.ukyi.app/secrets-rv";
const RV = /^[0-9]{1,20}$/;
const RECORD_NAMES = new Set<RestoreRecordName>(["restore-pg", "restore-vk", "restore-check", "data-purge"]);
const RECORD_KEY = /^[a-z0-9][a-z0-9.-]{0,62}$/;
const RUN_ID = /^[a-z0-9]{1,22}$/;
const JSONPATH = /^\{\.status(\.[A-Za-z][A-Za-z0-9]*)+\}$/;
const WAIT_VALUE = /^[A-Za-z0-9._:-]{1,64}$/;

function checkTimeout(sec: number, max: number): void {
  if (!Number.isInteger(sec) || sec < 1 || sec > max) throw new Error(`기다림은 1~${max}초다`);
}

function checkRecord(name: string): void {
  if (!RECORD_NAMES.has(name as RestoreRecordName)) throw new Error("복원 기록 이름은 restore-pg·restore-vk·restore-check·data-purge만");
}

function checkRun(runId: string): void {
  if (!RUN_ID.test(runId)) throw new Error("복원 실행 id 형식이 아니다");
}

// 파드 템플릿이 참조하는 Secret 이름(env secretKeyRef·envFrom·volumes·projected). 정렬, 중복 없음.
export function referencedSecrets(template: any): string[] {
  const names = new Set<string>();
  const spec = template?.spec ?? {};
  for (const c of [...(spec.containers ?? []), ...(spec.initContainers ?? [])]) {
    for (const e of c.env ?? []) if (typeof e?.valueFrom?.secretKeyRef?.name === "string") names.add(e.valueFrom.secretKeyRef.name);
    for (const e of c.envFrom ?? []) if (typeof e?.secretRef?.name === "string") names.add(e.secretRef.name);
  }
  for (const v of spec.volumes ?? []) {
    if (typeof v?.secret?.secretName === "string") names.add(v.secret.secretName);
    for (const s of v?.projected?.sources ?? []) if (typeof s?.secret?.name === "string") names.add(s.secret.name);
  }
  for (const n of names) checkName("Secret", n);
  return [...names].sort();
}

// ESO가 동기화 때 status.syncedResourceVersion에 쓰는 값(v2.13.0 ctrlutil.GetResourceVersion):
// "<generation>-" + sha3-224(fmt.Sprintf("%+v", struct{annotations, labels})). Go는 map을 키 순서로 map[k:v k:v]로 찍는다.
// ESO 시험 벡터로 꼴을 맞췄다(adapters-t12.test.ts).
export function goStringMap(m: Record<string, string> | undefined | null): string {
  const keys = Object.keys(m ?? {}).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  return `map[${keys.map((k) => `${k}:${(m as Record<string, string>)[k]}`).join(" ")}]`;
}

export function esSyncVersion(meta: { generation?: number; annotations?: Record<string, string>; labels?: Record<string, string> }): string {
  const text = `{annotations:${goStringMap(meta.annotations)} labels:${goStringMap(meta.labels)}}`;
  return `${meta.generation ?? 0}-${new Bun.CryptoHasher("sha3-224").update(text).digest("hex")}`;
}

function secretsHash(pairs: string[]): string {
  return new Bun.CryptoHasher("sha256").update(pairs.join("\n")).digest("hex").slice(0, 16);
}

// 복원 객체로 만들 수 있는 종류(C.5.7: 임시 Cluster·Job과 그 PVC). 라벨이 있어야 지울 때 0개 확인이 된다.
const RESTORE_KINDS = new Set(["Cluster", "Job", "Pod", "PersistentVolumeClaim"]);
const RESTORE_LABEL = "homelab.ukyi.app/restore";
const RESTORE_RESOURCES = "clusters.postgresql.cnpg.io,jobs.batch,pods,persistentvolumeclaims";

function checkName(what: string, v: string): void {
  if (!NAME.test(v) || v.length > 253) throw new Error(`kubectl ${what} 이름 형식이 아니다`);
}

function resource(kind: KubeKind): string {
  const r = Object.hasOwn(KINDS, kind) ? KINDS[kind] : undefined;
  if (!r) throw new Error("kubectl 어댑터에 없는 리소스 종류다(Secret은 secretHash·secretExists로만)");
  return r;
}

export function kubectlArgv(args: string[]): string[] {
  return ["kubectl", ...args, REQUEST_TIMEOUT];
}

function run(exec: Exec, args: string[], opts: ExecOpts = {}) {
  return exec(kubectlArgv(args), opts);
}

const nsArgs = (ns: string | null) => (ns ? ["-n", ns] : []);

// 어디든 kind: Secret(List 포함)이 있으면 true. 중첩 항목까지 본다(#873 2라운드 P1: List 안의 Secret).
export function containsSecretManifest(x: unknown): boolean {
  if (Array.isArray(x)) return x.some(containsSecretManifest);
  if (x && typeof x === "object") {
    const kind = (x as { kind?: unknown }).kind;
    if (typeof kind === "string" && /^secret(list)?$/i.test(kind)) return true;
    return Object.values(x).some(containsSecretManifest);
  }
  return false;
}

// 복원 기록 ConfigMap 해석. 라벨과 data.run이 같아야 하고, 키·값 형식을 본다(값은 시크릿이 아니다, 03 2절).
export function parseRecord(doc: any, name: string): RestoreRecord {
  const data: Record<string, string> = doc?.data ?? {};
  const run = data.run;
  if (typeof run !== "string" || !RUN_ID.test(run)) throw new Error(`복원 기록 ${name}: data.run 형식이 아니다`);
  if (doc?.metadata?.labels?.[RESTORE_LABEL] !== run) throw new Error(`복원 기록 ${name}: 라벨과 data.run이 다르다`);
  for (const [k, v] of entries(data)) {
    if (!RECORD_KEY.test(k)) throw new Error(`복원 기록 ${name}: 키 형식이 아니다`);
    if (typeof v !== "string") throw new Error(`복원 기록 ${name}: 값이 문자열이 아니다`);
    // in.* 만 여러 줄(확장 목록·덤프 목록)이다. 그 밖의 제어 문자는 거부한다.
    const bad = k.startsWith("in.") ? /[\u0000-\u0009\u000b-\u001f\u007f]/ : /[\u0000-\u001f\u007f]/;
    if (bad.test(v)) throw new Error(`복원 기록 ${name}: ${k}에 제어 문자가 있다`);
  }
  const rv = doc?.metadata?.resourceVersion;
  if (typeof rv !== "string" || !RV.test(rv)) throw new Error(`복원 기록 ${name}: resourceVersion을 읽지 못했다`);
  // 만들기 전 검사(restoreRecordCreate)에는 uid가 없다. 지우기는 uid가 있어야 한다.
  const uid = doc?.metadata?.uid;
  if (uid !== undefined && (typeof uid !== "string" || !/^[0-9a-f-]{8,64}$/.test(uid))) throw new Error(`복원 기록 ${name}: uid 형식이 아니다`);
  const created = doc?.metadata?.creationTimestamp;
  if (created !== undefined && (typeof created !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(created))) throw new Error(`복원 기록 ${name}: creationTimestamp 형식이 아니다`);
  return { run, data: { ...data }, resourceVersion: rv, uid: uid ?? "", created: created ?? "" };
}

export function kubeRead(exec: Exec, opts: KubeOpts = {}): KubeRead {
  const pollMs = opts.pollMs ?? POLL_MS;
  // 값은 이 함수 안에서만 원문으로 비교하고 돌려주지 않는다.
  const embeds = (ns: string, name: string, key: string, needle: Secret): boolean | null => {
    checkName("namespace", ns);
    checkName("Secret", name);
    if (!/^[A-Za-z0-9_.-]+$/.test(key)) throw new Error("Secret 키 이름 형식이 아니다");
    if (!isSecret(needle)) throw new Error("needle은 Secret이다");
    const r = run(exec, ["-n", ns, "get", "secrets", name, "-o", "json"], { secretStdout: true });
    if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get secret ${name}: 시간 초과`);
    if (r.code !== 0 && r.notFound) return null;
    if (r.code !== 0 || !r.stdoutSecret) throw new Error(`kubectl get secret ${name}: ${why(r)}`);
    const encoded = jsonParse(revealSecret(r.stdoutSecret)).data?.[key];
    if (typeof encoded !== "string") return null;
    const value = Buffer.from(encoded, "base64").toString("utf8");
    const raw = revealSecret(needle);
    return strIncludes(value, raw) || strIncludes(value, encodeURIComponent(raw));
  };
  // kubectl wait: 0이면 됨, 시간 초과는 false. 대상이 없으면(NotFound) 기다릴 것이 없어 던진다.
  const waited = (r: ReturnType<Exec>, what: string): boolean => {
    if (r.code === 0) return true;
    if (r.notFound) throw new Error(`kubectl wait ${what}: 대상이 없다`);
    if (r.errKind === "timeout" || /timed out waiting/i.test(r.stderr)) return false;
    throw new Error(`kubectl wait ${what}: ${why(r)}`);
  };
  const podSecrets = (ns: string, deployment: string) => {
    checkName("namespace", ns);
    checkName("Deployment", deployment);
    const d = self.get("deployment", ns, deployment);
    if (!d) throw new Error(`Deployment ${deployment}이 없다`);
    const secrets = referencedSecrets(d.spec?.template);
    const pairs = secrets.map((name) => {
      const r = run(exec, ["-n", ns, "get", "secrets", name, "-o", "jsonpath={.metadata.resourceVersion}"], { secretStdout: true });
      if (r.errKind === "timeout") throw new ExecTimeout(`Secret ${name} 버전: 시간 초과`);
      if (r.code !== 0 && r.notFound) return `${name}@none`;
      if (r.code !== 0 || !r.stdoutSecret) throw new Error(`Secret ${name} 버전: ${why(r)}`);
      const rv = revealSecret(r.stdoutSecret).trim();
      if (!RV.test(rv)) throw new Error(`Secret ${name} 버전 형식이 아니다`);
      return `${name}@${rv}`;
    });
    const hash = secretsHash(pairs);
    const s = d.status ?? {};
    const want = d.spec?.replicas ?? 1;
    const rolledOut = (s.observedGeneration ?? 0) >= (d.metadata?.generation ?? 0) && (s.updatedReplicas ?? 0) === want && (s.availableReplicas ?? 0) === want && (s.replicas ?? 0) === want;
    return { hash, state: { current: d.spec?.template?.metadata?.annotations?.[SECRETS_RV] === hash, rolledOut, secrets } };
  };
  const self: KubeRead = {
    get(kind, ns, name) {
      if (ns) checkName("namespace", ns);
      checkName("리소스", name);
      const r = run(exec, [...nsArgs(ns), "get", resource(kind), name, "-o", "json"]);
      if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get ${kind} ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return null;
      must(r, `kubectl get ${kind} ${name}`);
      return jsonParse(r.stdout);
    },
    list(kind, ns, selector) {
      if (ns) checkName("namespace", ns);
      if (selector !== undefined && !SELECTOR.test(selector)) throw new Error("kubectl label selector 형식이 아니다");
      const r = run(exec, [...(ns ? ["-n", ns] : ["-A"]), "get", resource(kind), ...(selector ? ["-l", selector] : []), "-o", "json"]);
      must(r, `kubectl get ${kind}`);
      return jsonParse(r.stdout).items ?? [];
    },
    secretHash(ns, name, key) {
      checkName("namespace", ns);
      checkName("Secret", name);
      if (!/^[A-Za-z0-9_.-]+$/.test(key)) throw new Error("Secret 키 이름 형식이 아니다");
      const r = run(exec, ["-n", ns, "get", "secret", name, "-o", "json"], { secretStdout: true });
      if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get secret ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return null;
      if (r.code !== 0 || !r.stdoutSecret) throw new Error(`kubectl get secret ${name}: ${why(r)}`);
      // 요청한 키 하나만 Secret으로 만든다. 같은 Secret의 username(앱 이름 같은 공개 값)은 추적하지 않는다(#873 2라운드 P1).
      const encoded = jsonParse(revealSecret(r.stdoutSecret)).data?.[key];
      if (typeof encoded !== "string") return null;
      return new Secret(Buffer.from(encoded, "base64").toString("utf8")).sha256Prefix(12);
    },
    secretExists(ns, name) {
      checkName("namespace", ns);
      checkName("Secret", name);
      const r = run(exec, ["-n", ns, "get", "secret", name, "-o", "json"], { secretStdout: true });
      if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get secret ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return { exists: false, keys: [], resourceVersion: null };
      if (r.code !== 0 || !r.stdoutSecret) throw new Error(`kubectl get secret ${name}: ${why(r)}`);
      const doc = jsonParse(revealSecret(r.stdoutSecret));
      const rv = doc.metadata?.resourceVersion;
      return { exists: true, keys: Object.keys(doc.data ?? {}).sort(), resourceVersion: typeof rv === "string" && RV.test(rv) ? rv : null };
    },
    secretEmbeds(ns, name, key, needle) {
      return embeds(ns, name, key, needle);
    },
    waitSecret(ns, name, key, want, timeoutSec) {
      checkTimeout(timeoutSec, 300);
      if ("hash" in want && !/^[0-9a-f]{12}$/.test(want.hash)) throw new Error("기다릴 해시는 12자 16진이다");
      if ("embeds" in want && !isSecret(want.embeds)) throw new Error("embeds는 Secret이다");
      const deadline = Date.now() + timeoutSec * 1000;
      for (;;) {
        const ok = "hash" in want ? self.secretHash(ns, name, key) === want.hash : embeds(ns, name, key, want.embeds) === true;
        if (ok) return true;
        if (Date.now() + pollMs > deadline) return false;
        Bun.sleepSync(pollMs);
      }
    },
    waitFor(kind, ns, name, jsonpath, value, timeoutSec) {
      checkName("namespace", ns);
      checkName("리소스", name);
      if (!JSONPATH.test(jsonpath)) throw new Error("jsonpath는 {.status.x} 꼴만");
      if (!WAIT_VALUE.test(value)) throw new Error("기다릴 값 형식이 아니다");
      checkTimeout(timeoutSec, 600);
      return waited(run(exec, ["-n", ns, "wait", `${resource(kind)}/${name}`, `--for=jsonpath=${jsonpath}=${value}`, `--timeout=${timeoutSec}s`], { timeoutMs: (timeoutSec + 30) * 1000 }), `${kind} ${name}`);
    },
    waitCondition(kind, ns, target, cond, timeoutSec) {
      checkName("namespace", ns);
      if (!["Ready", "ready", "complete"].includes(cond)) throw new Error("기다릴 조건은 Ready·ready·complete만");
      checkTimeout(timeoutSec, 1800);
      let what: string[];
      if ("jobPods" in target) {
        checkName("Job", target.jobPods);
        what = ["pods", "-l", `job-name=${target.jobPods}`];
      } else {
        checkName("리소스", target.name);
        what = [`${resource(kind)}/${target.name}`];
      }
      // 함정(kubectl 1.36.5 pkg/cmd/wait): 셀렉터에 맞는 객체가 아직 없으면 기다리지 않고 "no matching resources found"로 끝난다.
      // Job을 만든 직후의 파드가 그렇다. 시간 안에서 다시 본다(#880 후속, 실제 출력 대조).
      const deadline = Date.now() + timeoutSec * 1000;
      for (;;) {
        const left = Math.max(1, Math.ceil((deadline - Date.now()) / 1000));
        const x = run(exec, ["-n", ns, "wait", ...what, `--for=condition=${cond}`, `--timeout=${left}s`], { timeoutMs: (left + 30) * 1000 });
        if (x.code !== 0 && /no matching resources found/.test(x.stderr)) {
          if (Date.now() + pollMs > deadline) return false;
          Bun.sleepSync(pollMs);
          continue;
        }
        return waited(x, what.join(" "));
      }
    },
    podSecretsCurrent(ns, deployment) {
      return podSecrets(ns, deployment).state;
    },
    restoreRecord(ns, name) {
      checkName("namespace", ns);
      checkRecord(name);
      const r = run(exec, ["-n", ns, "get", "configmaps", name, "-o", "json"]);
      if (r.errKind === "timeout") throw new ExecTimeout(`복원 기록 ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return null;
      must(r, `복원 기록 ${name}`);
      return parseRecord(jsonParse(r.stdout), name);
    },
    // 앱 로그를 그대로 돌려준다. 앱이 자격을 로그에 쓰지 않는 것은 앱 계약이다(설계 C.7, Connector 3라운드 판단).
    // CLI는 로그 속 임의 값이 시크릿인지 알 수 없고(추측 마스킹은 놓친 값을 가린 것처럼 보이게 한다), 같은 사람은
    // kubeconfig로 kubectl logs를 직접 볼 수 있다. 이 실행이 다룬 시크릿(16자 이상)이 섞이면 출력 계층이 결과 전체를 막는다.
    logs(ns, target: LogTarget, opts = {}) {
      checkName("namespace", ns);
      const ref = "job" in target ? (checkName("Job", target.job), `job/${target.job}`) : (checkName("Deployment", target.deployment), `deploy/${target.deployment}`);
      if (opts.container !== undefined) checkName("컨테이너", opts.container);
      // 명령은 일 단위(7d)도 받는다. kubectl은 Go duration이라 d가 없어 시간으로 바꾼다(Connector 4360754457).
      const m = opts.since === undefined ? null : /^([1-9][0-9]{0,5})([smhd])$/.exec(opts.since);
      if (opts.since !== undefined && !m) throw new Error("--since 형식이 아니다");
      const since = m ? (m[2] === "d" ? `${Number(m[1]) * 24}h` : opts.since) : undefined;
      const tail = opts.tail ?? 200;
      if (!Number.isInteger(tail) || tail < 1 || tail > 10_000) throw new Error("tail 범위가 아니다");
      const r = run(exec, ["-n", ns, "logs", ref, `--tail=${tail}`, ...(since ? [`--since=${since}`] : []), ...(opts.previous ? ["--previous"] : []), ...(opts.container ? ["-c", opts.container] : [])]);
      return must(r, `kubectl logs ${ref}`).stdout;
    },
    canI(verb, kind, ns) {
      checkName("namespace", ns);
      const r = run(exec, ["auth", "can-i", verb, resource(kind), "-n", ns]);
      if (r.errKind) throw new Error(`kubectl auth can-i: ${why(r)}`);
      return r.code === 0;
    },
    rolloutStatus(ns, deployment, timeoutSec = 180) {
      checkName("namespace", ns);
      checkName("Deployment", deployment);
      const r = run(exec, ["-n", ns, "rollout", "status", `deploy/${deployment}`, `--timeout=${timeoutSec}s`], { timeoutMs: (timeoutSec + 20) * 1000 });
      return r.code === 0;
    },
    currentContext() {
      // 서버 주소는 읽지 않는다(tailnet 이름일 수 있다, D-23).
      const r = exec(["kubectl", "config", "current-context"]);
      if (r.errKind === "not-found") throw new Error("kubectl이 없다");
      const name = r.stdout.trim();
      return r.code === 0 && name ? name : null;
    },
  };
  return self;
}

// 이 실행이 아닌 기록·객체를 건드리지 않게, 기록 키를 JSON pointer로 쓸 때 쓰는 꼴(키 형식에 ~·/가 없다).
const pointer = (key: string) => `/data/${key}`;
const RAW_PATH = { job: "/apis/batch/v1", cluster: "/apis/postgresql.cnpg.io/v1" } as const;
// core(pgrestore.ts)만 쓰는 기록 키: 4-2 입력, 파괴 단계 표시, 2단계에서 고정한 임시 주 파드, 되돌림 사본 버킷.
const CORE_KEYS = /^(in\.|dropped$|tmp$|bucket$)/;

// 복원 기록 고치기. 첫 op가 test /data/run = run이라 남의 실행 기록이면 API 서버가 거부한다. 값 null은 그 키를 지운다.
// allowCore는 pgrestore.ts만 true로 부른다(in.*·dropped).
export function updateRecord(exec: Exec, r: KubeRead, ns: string, name: RestoreRecordName, runId: string, set: Record<string, string | null>, allowCore: boolean): void {
  checkName("namespace", ns);
  checkRecord(name);
  checkRun(runId);
  const cur = r.restoreRecord(ns, name);
  if (!cur || cur.run !== runId) throw new Error(`복원 기록 ${name}이 이 실행(${runId})의 것이 아니다`);
  const ops: unknown[] = [{ op: "test", path: pointer("run"), value: runId }];
  for (const [k, v] of entries(set)) {
    if (!RECORD_KEY.test(k) || k === "run") throw new Error("복원 기록 키 형식이 아니다(run은 바꾸지 않는다)");
    if (!allowCore && CORE_KEYS.test(k)) throw new Error(`복원 기록 ${k}는 core만 쓴다`);
    if (v === null) {
      if (Object.hasOwn(cur.data, k)) ops.push({ op: "remove", path: pointer(k) });
    } else {
      if (typeof v !== "string" || isSecret(v)) throw new Error("복원 기록 값은 문자열이다");
      ops.push({ op: "add", path: pointer(k), value: v });
    }
  }
  parseRecord({ metadata: { labels: { [RESTORE_LABEL]: runId }, resourceVersion: "0" }, data: { ...cur.data, ...Object.fromEntries(entries(set).filter(([, v]) => v !== null)) } }, name);
  const x = run(exec, ["-n", ns, "patch", "configmaps", name, "--type=json", "--patch-file=/dev/stdin"], { input: jsonStringify(ops) });
  if (x.code !== 0 && /test operation|testing value|jsonpatch test/i.test(x.stderr)) throw new Error(`복원 기록 ${name}: 잠금이 이 실행의 것이 아니다(test 실패)`);
  must(x, `복원 기록 ${name} 고치기`);
}

export function kubeWrite(exec: Exec, opts: KubeOpts = {}): KubeWrite {
  const pollMs = opts.pollMs ?? POLL_MS;
  const r = kubeRead(exec, opts);
  // podSecretsCurrent와 같은 계산(해시까지). kubeRead 안의 함수를 다시 쓰려고 상태를 한 번 더 읽는다.
  const secretsHashOf = (ns: string, deployment: string): string => {
    const d = r.get("deployment", ns, deployment);
    if (!d) throw new Error(`Deployment ${deployment}이 없다`);
    const pairs = referencedSecrets(d.spec?.template).map((name) => {
      const x = run(exec, ["-n", ns, "get", "secrets", name, "-o", "jsonpath={.metadata.resourceVersion}"], { secretStdout: true });
      if (x.code !== 0 && x.notFound) return `${name}@none`;
      if (x.code !== 0 || !x.stdoutSecret) throw new Error(`Secret ${name} 버전: ${why(x)}`);
      const rv = revealSecret(x.stdoutSecret).trim();
      if (!RV.test(rv)) throw new Error(`Secret ${name} 버전 형식이 아니다`);
      return `${name}@${rv}`;
    });
    return secretsHash(pairs);
  };
  return {
    forceSync(ns, externalSecret, o = {}) {
      checkName("namespace", ns);
      checkName("ExternalSecret", externalSecret);
      if (o.waitSec !== undefined) checkTimeout(o.waitSec, 120);
      // 이번 요청의 동기화를 가르는 표지: ESO는 동기화를 마치면 status.syncedResourceVersion에 그때의 메타데이터 버전
      // (generation + annotation·label 해시, esSyncVersion)을 쓴다. 이번 annotation이 든 지금 메타데이터의 버전과 같아져야 끝이다.
      // "이전 값과 다름"만 보면 앞선 요청의 완료를 이번 것으로 인정한다(#880 2라운드). refreshTime은 초 단위라 쓰지 않는다.
      // 값은 ms+난수라 늘 바뀐다(같으면 해시가 안 바뀌어 ESO가 동기화하지 않는다).
      const stamp = `${Date.now()}-${[...crypto.getRandomValues(new Uint8Array(2))].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
      must(run(exec, ["-n", ns, "annotate", KINDS.externalsecret, externalSecret, `force-sync=${stamp}`, "--overwrite"]), `force-sync ${externalSecret}`);
      if (o.waitSec === undefined) return;
      const deadline = Date.now() + o.waitSec * 1000;
      for (;;) {
        const es = r.get("externalsecret", ns, externalSecret);
        if (!es) throw new Error(`ExternalSecret ${externalSecret}이 없다`);
        // 읽을 때마다 지금 메타데이터로 계산한다. 그사이 누가 더 annotate했으면 그 뒤의 동기화를 기다린다(그것도 이번 요청 뒤다).
        const want = esSyncVersion(es.metadata ?? {});
        const ready = (es.status?.conditions ?? []).some((c: any) => c?.type === "Ready" && c?.status === "True");
        if (ready && es.status?.syncedResourceVersion === want) return;
        if (Date.now() + pollMs > deadline) throw new ExecTimeout(`ExternalSecret ${externalSecret}: 동기화 대기 시간 초과`);
        Bun.sleepSync(pollMs);
      }
    },
    restartForSecrets(ns, deployment) {
      checkName("namespace", ns);
      checkName("Deployment", deployment);
      const hash = secretsHashOf(ns, deployment);
      const patch = jsonStringify({ spec: { template: { metadata: { annotations: { [SECRETS_RV]: hash } } } } });
      must(run(exec, ["-n", ns, "patch", KINDS.deployment, deployment, "--type=merge", "--patch-file=/dev/stdin"], { input: patch }), `재시작 ${deployment}`);
    },
    restoreRecordCreate(ns, name, runId, data) {
      checkName("namespace", ns);
      checkRecord(name);
      checkRun(runId);
      for (const k of Object.keys(data)) if (CORE_KEYS.test(k)) throw new Error(`복원 기록 ${k}는 core만 쓴다`);
      const body = { ...data, run: runId };
      for (const [k, v] of entries(body)) {
        if (!RECORD_KEY.test(k) || typeof v !== "string") throw new Error("복원 기록 키·값 형식이 아니다");
        if (isSecret(v)) throw new Error("복원 기록에 시크릿을 넣지 않는다");
      }
      const manifest = { apiVersion: "v1", kind: "ConfigMap", metadata: { name, namespace: ns, labels: { [RESTORE_LABEL]: runId } }, data: body };
      parseRecord({ ...manifest, metadata: { ...manifest.metadata, resourceVersion: "0" } }, name);
      const x = run(exec, ["-n", ns, "create", "-f", "-"], { input: jsonStringify(manifest) });
      if (x.code !== 0 && /AlreadyExists/.test(x.stderr)) return "exists";
      must(x, `복원 기록 ${name} 만들기`);
      return "created";
    },
    restoreRecordUpdate(ns, name, runId, set) {
      // in.*(4-2 산출물)와 dropped(파괴 단계 표시)는 core(pgrestore.ts)만 쓴다. 명령이 바꾸면 고정한 입력·되돌림 판단이 무너진다.
      for (const k of Object.keys(set)) if (CORE_KEYS.test(k)) throw new Error(`복원 기록 ${k}는 core만 쓴다`);
      updateRecord(exec, r, ns, name, runId, set, false);
    },
    restoreRecordDelete(ns, name, runId) {
      checkName("namespace", ns);
      checkRecord(name);
      checkRun(runId);
      // 이 실행의 기록인지 본 그 객체(uid)만 지운다(#880 2라운드 P2). 라벨 셀렉터 삭제는 kubectl이 목록을 본 뒤 이름으로 지워,
      // 그사이 같은 이름으로 생긴 다른 실행의 잠금을 지운다. 남의 기록이거나 없으면 아무것도 하지 않는다(전과 같음).
      const cur = r.restoreRecord(ns, name);
      if (!cur || cur.run !== runId) return;
      const uid = cur.uid;
      if (!uid) throw new Error(`복원 기록 ${name}의 uid를 읽지 못했다`);
      const body = jsonStringify({ kind: "DeleteOptions", apiVersion: "v1", preconditions: { uid } });
      const x = run(exec, ["delete", "--raw", `/api/v1/namespaces/${ns}/configmaps/${name}`, "-f", "-"], { input: body, secretStdout: true, signals: { conflict: /Precondition failed|\(Conflict\)/ } });
      if (x.errKind === "timeout") throw new ExecTimeout(`복원 기록 ${name} 지우기: 시간 초과(결과 미상)`);
      if (x.signals?.includes("conflict")) throw new Error(`복원 기록 ${name}이 확인 뒤 다른 실행의 것으로 바뀌었다. 지우지 않았다`);
      if (x.code !== 0 && !x.notFound) throw new Error(`복원 기록 ${name} 지우기: ${why(x)}`);
    },
    deleteRestoreObject(ns, kind, name, runId) {
      checkName("namespace", ns);
      checkName("리소스", name);
      checkRun(runId);
      if (kind !== "job" && kind !== "cluster") throw new Error("하나씩 지우는 복원 객체는 job·cluster만");
      const cur = r.get(kind, ns, name);
      if (!cur) return;
      if (cur.metadata?.labels?.[RESTORE_LABEL] !== runId) throw new Error(`${kind} ${name}은 이 실행(${runId})의 복원 객체가 아니다`);
      const uid = cur.metadata?.uid;
      if (typeof uid !== "string" || !/^[0-9a-f-]{8,64}$/.test(uid)) throw new Error(`${kind} ${name}의 uid를 읽지 못했다`);
      // 확인한 그 객체만 지운다(#880 리뷰 P2): 이름만으로 지우면 확인과 삭제 사이 같은 이름의 다른 실행 객체가 생겼을 때 그것을 지운다.
      // kubectl delete는 precondition을 넣지 않아 DeleteOptions를 --raw 본문으로 보낸다(kubectl 1.36.5 실측: -f - 본문을 그대로 보낸다).
      const body = jsonStringify({ kind: "DeleteOptions", apiVersion: "v1", propagationPolicy: "Foreground", preconditions: { uid } });
      const x = run(exec, ["delete", "--raw", `${RAW_PATH[kind]}/namespaces/${ns}/${kind === "job" ? "jobs" : "clusters"}/${name}`, "-f", "-"], { input: body, secretStdout: true, signals: { conflict: /Precondition failed|\(Conflict\)/ } });
      if (x.errKind === "timeout") throw new ExecTimeout(`${kind} ${name} 지우기: 시간 초과(결과 미상)`);
      if (x.signals?.includes("conflict")) throw new Error(`${kind} ${name}이 확인 뒤 다른 객체로 바뀌었다. 지우지 않았다`);
      if (x.code !== 0 && !x.notFound) throw new Error(`${kind} ${name} 지우기: ${why(x)}`);
      // foreground 삭제는 비동기다. 그 uid의 객체가 사라질 때까지 기다린다(같은 이름의 새 객체는 다른 uid라 기다리지 않는다).
      const deadline = Date.now() + 120_000;
      for (;;) {
        const now = r.get(kind, ns, name);
        if (!now || now.metadata?.uid !== uid) return;
        if (Date.now() + pollMs > deadline) throw new ExecTimeout(`${kind} ${name}: 삭제 대기 시간 초과`);
        Bun.sleepSync(pollMs);
      }
    },
    createJobFromCronJob(ns, cronjob, jobName, runId) {
      checkName("namespace", ns);
      checkName("CronJob", cronjob);
      checkRun(runId);
      if (!/^backup-[a-z0-9]{1,22}-[0-9a-f]{4}$/.test(jobName)) throw new Error("백업 Job 이름 형식이 아니다");
      const dry = must(run(exec, ["-n", ns, "create", "job", jobName, `--from=cronjob/${cronjob}`, "--dry-run=client", "-o", "json"]), `CronJob ${cronjob}에서 Job 만들기(dry-run)`);
      const job = jsonParse(dry.stdout);
      if (job?.kind !== "Job" || job?.metadata?.name !== jobName) throw new Error("dry-run 결과가 그 Job이 아니다");
      if (containsSecretManifest(job)) throw new Error("Job 매니페스트 안에 kind: Secret이 있다");
      // 라벨은 만드는 요청에 함께 둔다(restore.md 0단계: 뒤에 붙이면 그사이 정리가 못 찾는다).
      job.metadata.labels = { ...(job.metadata.labels ?? {}), [RESTORE_LABEL]: runId };
      must(run(exec, ["-n", ns, "create", "-f", "-"], { input: jsonStringify(job) }), `Job ${jobName} 만들기`);
    },
    setPvReclaimDelete(ns, pvc) {
      checkName("namespace", ns);
      checkName("PVC", pvc);
      const claim = r.get("pvc", ns, pvc);
      const pv = claim?.spec?.volumeName;
      if (typeof pv !== "string") throw new Error(`PVC ${pvc}에 묶인 PV가 없다`);
      checkName("PV", pv);
      const vol = r.get("pv", null, pv);
      if (vol?.spec?.storageClassName !== "local-retain") throw new Error(`PV ${pv}의 storageClass가 local-retain이 아니다`);
      if (vol?.spec?.claimRef?.namespace !== ns || vol?.spec?.claimRef?.name !== pvc) throw new Error(`PV ${pv}가 ${ns}/${pvc}에 묶여 있지 않다`);
      must(run(exec, ["patch", KINDS.pv, pv, "--type=merge", "--patch-file=/dev/stdin"], { input: jsonStringify({ spec: { persistentVolumeReclaimPolicy: "Delete" } }) }), `PV ${pv} reclaim`);
    },
    rolloutRestart(ns, deployment) {
      checkName("namespace", ns);
      checkName("Deployment", deployment);
      must(run(exec, ["-n", ns, "rollout", "restart", `deploy/${deployment}`]), `rollout restart ${deployment}`);
    },
    createRestoreObject(ns, manifest) {
      checkName("namespace", ns);
      const kind = manifest.kind;
      if (typeof kind !== "string" || !RESTORE_KINDS.has(kind)) throw new Error("복원 객체로 만들 수 없는 종류다(Cluster·Job·Pod·PersistentVolumeClaim만)");
      // Secret 매니페스트는 만들지 않는다(자격은 ExternalSecret, AGENTS.md).
      if (containsSecretManifest(manifest)) throw new Error("매니페스트 안에 kind: Secret이 있다");
      // Secret 객체는 JSON에서 "[secret]"이 되어 엉뚱한 값이 들어간다. 시크릿은 매니페스트로 넘기지 않는다.
      if (findSecretPath(manifest, "manifest")) throw new Error("매니페스트에 시크릿 객체가 있다");
      const labels = (manifest.metadata as { labels?: Record<string, unknown> } | undefined)?.labels;
      const runId = labels?.[RESTORE_LABEL];
      if (typeof runId !== "string" || !/^[a-z0-9]{1,22}$/.test(runId)) throw new Error(`복원 객체에 라벨 ${RESTORE_LABEL}=<실행 id>가 없다`);
      const text = jsonStringify(manifest);
      if (hasControl(text)) throw new Error("매니페스트에 제어 문자가 있다");
      must(run(exec, ["-n", ns, "create", "-f", "-"], { input: text }), `kubectl create ${kind}`);
    },
    deleteRestoreObjects(ns, runId) {
      checkName("namespace", ns);
      if (!/^[a-z0-9]{1,22}$/.test(runId)) throw new Error("복원 실행 id 형식이 아니다");
      // 실제로 사라질 때까지 기다린다(Connector 4360754447). 기다리지 않으면 finalizer가 있는 PVC·CNPG Cluster가 terminating으로
      // 남아 엔진의 실행 뒤 재조회가 성공한 삭제를 실패로 본다. [미검증] --request-timeout(20s)이 긴 대기의 watch를 끊어도
      // kubectl이 다시 watch해 이어 가는지는 T12-05 운영 실행에서 본다.
      must(run(exec, ["-n", ns, "delete", RESTORE_RESOURCES, "-l", `${RESTORE_LABEL}=${runId}`, "--ignore-not-found", "--wait=true", "--timeout=300s"], { timeoutMs: 330_000 }), "복원 객체 지우기");
    },
  };
}
