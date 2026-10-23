// kubectl 어댑터. 사람의 kubeconfig와 현재 context를 그대로 쓴다(자격을 저장하지 않는다).
// argv는 여기서만 만든다. 리소스는 KINDS 표의 이름뿐이라 범용 조회로 Secret을 읽을 수 없고(#873 2라운드 P1),
// --raw·config view 같은 원문 출력 옵션은 쓰지 않는다. 모든 호출에 --request-timeout(서버가 멈추면 기본으로 오래 기다린다).
import type { KubeKind, KubeRead, KubeWrite } from "./command";
import { ExecTimeout, must, why, type Exec, type ExecOpts } from "./exec";
import { hasControl } from "./names";
import { Secret } from "./secret";

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
};

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

export function kubeRead(exec: Exec): KubeRead {
  return {
    get(kind, ns, name) {
      if (ns) checkName("namespace", ns);
      checkName("리소스", name);
      const r = run(exec, [...nsArgs(ns), "get", resource(kind), name, "-o", "json"]);
      if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get ${kind} ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return null;
      must(r, `kubectl get ${kind} ${name}`);
      return JSON.parse(r.stdout);
    },
    list(kind, ns, selector) {
      if (ns) checkName("namespace", ns);
      if (selector !== undefined && !SELECTOR.test(selector)) throw new Error("kubectl label selector 형식이 아니다");
      const r = run(exec, [...(ns ? ["-n", ns] : ["-A"]), "get", resource(kind), ...(selector ? ["-l", selector] : []), "-o", "json"]);
      must(r, `kubectl get ${kind}`);
      return JSON.parse(r.stdout).items ?? [];
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
      const encoded = JSON.parse(r.stdoutSecret.reveal()).data?.[key];
      if (typeof encoded !== "string") return null;
      return new Secret(Buffer.from(encoded, "base64").toString("utf8")).sha256Prefix(12);
    },
    secretExists(ns, name) {
      checkName("namespace", ns);
      checkName("Secret", name);
      const r = run(exec, ["-n", ns, "get", "secret", name, "-o", "json"], { secretStdout: true });
      if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get secret ${name}: 시간 초과`);
      if (r.code !== 0 && r.notFound) return { exists: false, keys: [] };
      if (r.code !== 0 || !r.stdoutSecret) throw new Error(`kubectl get secret ${name}: ${why(r)}`);
      return { exists: true, keys: Object.keys(JSON.parse(r.stdoutSecret.reveal()).data ?? {}).sort() };
    },
    logs(ns, deployment, opts = {}) {
      checkName("namespace", ns);
      checkName("Deployment", deployment);
      if (opts.since !== undefined && !/^[1-9][0-9]*[smh]$/.test(opts.since)) throw new Error("--since 형식이 아니다");
      const tail = opts.tail ?? 200;
      if (!Number.isInteger(tail) || tail < 1 || tail > 10_000) throw new Error("tail 범위가 아니다");
      const r = run(exec, ["-n", ns, "logs", `deploy/${deployment}`, `--tail=${tail}`, ...(opts.since ? [`--since=${opts.since}`] : [])]);
      return must(r, `kubectl logs ${deployment}`).stdout;
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
}

export function kubeWrite(exec: Exec): KubeWrite {
  return {
    forceSync(ns, externalSecret) {
      checkName("namespace", ns);
      checkName("ExternalSecret", externalSecret);
      must(run(exec, ["-n", ns, "annotate", KINDS.externalsecret, externalSecret, `force-sync=${Math.floor(Date.now() / 1000)}`, "--overwrite"]), `force-sync ${externalSecret}`);
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
      const labels = (manifest.metadata as { labels?: Record<string, unknown> } | undefined)?.labels;
      const runId = labels?.[RESTORE_LABEL];
      if (typeof runId !== "string" || !/^[a-z0-9]{1,22}$/.test(runId)) throw new Error(`복원 객체에 라벨 ${RESTORE_LABEL}=<실행 id>가 없다`);
      const text = JSON.stringify(manifest);
      if (hasControl(text)) throw new Error("매니페스트에 제어 문자가 있다");
      must(run(exec, ["-n", ns, "create", "-f", "-"], { input: text }), `kubectl create ${kind}`);
    },
    deleteRestoreObjects(ns, runId) {
      checkName("namespace", ns);
      if (!/^[a-z0-9]{1,22}$/.test(runId)) throw new Error("복원 실행 id 형식이 아니다");
      must(run(exec, ["-n", ns, "delete", RESTORE_RESOURCES, "-l", `${RESTORE_LABEL}=${runId}`, "--ignore-not-found", "--wait=false"]), "복원 객체 지우기");
    },
  };
}
