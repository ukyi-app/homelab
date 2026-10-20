// 렌더 결과 정책 검사(설계 C.4.6 "렌더 결과 정책"). 입력은 render.ts의 Doc 목록이고, 위반 목록을 돌려준다.
// 규칙마다 "대상 0건이면 실패"는 main.ts가 아니라 여기서 센다(L40). 앱이 없는 저장소처럼 대상이 0일 수 있는 규칙은
// 세지 않는다.
import { type Doc, type Violation, sameRepo } from "./lib";

// 렌더에 나오는 상류 매니페스트의 예외. 출처(render.ts의 origin)의 path 부분으로 고른다.
// Argo CD는 공식 install.yaml을 그대로 쓴다(설계 C.3.3). 이미지는 URL의 버전 태그로 고정되고(digest 아님),
// 자원 상한이 없고, 빈 Secret 둘(argocd-secret, argocd-notifications-secret)을 낸다. 값은 저장소에 없다.
// 이 예외를 넓히지 않는다. 다른 구성 요소는 digest·상한을 직접 적는다.
const UPSTREAM_ARGOCD = /:platform\/argocd$/;

const WORKLOAD_KINDS = new Set(["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"]);
const DIGEST_IMAGE = /^[a-z0-9][a-z0-9._\-/:]*@sha256:[0-9a-f]{64}$/;
const PUBLIC_HOST = /^[a-z0-9-]+\.ukyi\.app$/;
const DNS_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
// D-30 리다이렉터의 tailnet 이름. 다른 것이 이 이름을 가져가면 go/ 짧은 주소가 깨진다.
const RESERVED_TAILNET_NAMES = new Set(["go", "vm-go"]);

export const READONLY_LABEL = "homelab.ukyi.app/readonly";
const READONLY_VERBS = new Set(["get", "list", "watch"]);
// 읽기 전용 역할이 가지면 안 되는 자원. Secret·임의 ConfigMap·로그·exec는 봇 R05~R06과 같이 막는다(설계 C.8).
const READONLY_FORBIDDEN_RESOURCES = new Set([
  "secrets",
  "configmaps",
  "pods/log",
  "pods/exec",
  "pods/attach",
  "pods/portforward",
  "pods/proxy",
  "services/proxy",
  "nodes/proxy",
  "serviceaccounts/token",
]);
// 봇 읽기 계정 SA. 이 SA를 묶는 바인딩은 읽기 전용 라벨이 붙은 역할만 가리켜야 한다(roleRef 우회, L30).
const READONLY_SUBJECTS = new Set(["bot-reader"]);

function podSpec(obj: any): any | undefined {
  switch (obj.kind) {
    case "Pod":
      return obj.spec;
    case "CronJob":
      return obj.spec?.jobTemplate?.spec?.template?.spec;
    default:
      return obj.spec?.template?.spec;
  }
}

function id(d: Doc): string {
  const ns = d.obj.metadata?.namespace ? `${d.obj.metadata.namespace}/` : "";
  return `${d.origin} ${d.obj.kind}/${ns}${d.obj.metadata?.name}`;
}

// kind: Secret 0건(설계 C.6.2). 시크릿 값은 Infisical에만 있고 Kubernetes Secret은 ESO가 만든다.
export function checkNoSecrets(docs: Doc[]): Violation[] {
  return docs
    .filter((d) => d.obj.kind === "Secret" && d.obj.apiVersion === "v1")
    .filter((d) => !(UPSTREAM_ARGOCD.test(d.origin) && !d.obj.data && !d.obj.stringData))
    .map((d) => ({ rule: "no-secret", where: id(d), message: "kind: Secret을 렌더한다. 값은 Infisical, 사본은 ExternalSecret으로" }));
}

// L27 이미지는 digest로(sha256: + 64자. 접두만 재면 sha256:deadbeef가 통과한다), L28 requests와 memory limit.
export function checkWorkloads(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  let seen = 0;
  for (const d of docs) {
    if (!WORKLOAD_KINDS.has(d.obj.kind)) continue;
    if (UPSTREAM_ARGOCD.test(d.origin)) continue;
    seen++;
    const spec = podSpec(d.obj) ?? {};
    const containers = [...(spec.initContainers ?? []), ...(spec.containers ?? [])];
    if (containers.length === 0) out.push({ rule: "workload", where: id(d), message: "컨테이너가 없다" });
    for (const c of containers) {
      const where = `${id(d)} container ${c.name}`;
      if (typeof c.image !== "string" || !DIGEST_IMAGE.test(c.image)) {
        out.push({ rule: "image-digest", where, message: `이미지가 digest 고정이 아니다: ${c.image} (L27)` });
      }
      const r = c.resources ?? {};
      for (const [k, v] of [
        ["requests.cpu", r.requests?.cpu],
        ["requests.memory", r.requests?.memory],
        ["limits.memory", r.limits?.memory],
      ]) {
        if (v === undefined || v === null || v === "") out.push({ rule: "resources", where, message: `${k}가 없다 (L28)` });
      }
    }
  }
  if (seen === 0) out.push({ rule: "workload", where: "render", message: "검사한 워크로드가 0개다(L40)" });
  return out;
}

// L31 자기 저장소를 가리키는 Argo CD 참조는 main. 공유 차트만 자기 태그(app-chart-v*, data-chart-v*)다.
// ApplicationSet git 생성기의 키는 targetRevision이 아니라 revision이라 따로 본다.
const CHART_TAGS: Record<string, RegExp> = {
  "platform/charts/app": /^app-chart-v/,
  "platform/charts/app-data": /^data-chart-v/,
};

function checkRevision(where: string, src: any, out: Violation[]): void {
  if (!sameRepo(src?.repoURL)) return;
  const rev = src.targetRevision ?? src.revision;
  const tag = src.path ? CHART_TAGS[src.path] : undefined;
  if (tag) {
    if (typeof rev !== "string" || !tag.test(rev)) out.push({ rule: "revision", where, message: `공유 차트 ${src.path}는 자기 태그로 고정한다: ${rev}` });
    return;
  }
  if (rev !== "main") out.push({ rule: "revision", where, message: `자기 저장소 참조의 revision이 main이 아니다: ${rev} (L31)` });
}

function walkGenerators(gens: any[] | undefined, where: string, out: Violation[]): void {
  for (const g of gens ?? []) {
    if (g.git) checkRevision(`${where} generator.git`, g.git, out);
    walkGenerators(g.matrix?.generators, where, out);
    walkGenerators(g.merge?.generators, where, out);
  }
}

export function checkRevisions(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  let seen = 0;
  for (const d of docs) {
    const where = id(d);
    if (d.obj.kind === "Application" && d.obj.apiVersion?.startsWith("argoproj.io/")) {
      seen++;
      for (const s of d.obj.spec?.sources ?? [d.obj.spec?.source]) checkRevision(where, s, out);
    }
    if (d.obj.kind === "ApplicationSet" && d.obj.apiVersion?.startsWith("argoproj.io/")) {
      seen++;
      const spec = d.obj.spec?.template?.spec ?? {};
      for (const s of spec.sources ?? [spec.source]) checkRevision(where, s, out);
      walkGenerators(d.obj.spec?.generators, where, out);
    }
  }
  if (seen === 0) out.push({ rule: "revision", where: "render", message: "검사한 Argo CD Application이 0개다(L40)" });
  return out;
}

// L30 읽기 전용 역할의 verb·자원과 roleRef. 라벨을 떼면 첫 검사를 피하므로, bot-reader 바인딩과 이름 homelab-readonly도 본다.
export function checkReadonlyRbac(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  // 키는 "ClusterRole/<name>" 또는 "Role/<ns>/<name>". 역할과 바인딩이 다른 Application에 있어도 찾는다.
  const roles = new Map<string, Doc>();
  for (const d of docs) {
    const k = d.obj.kind;
    if ((k === "ClusterRole" || k === "Role") && d.obj.apiVersion === "rbac.authorization.k8s.io/v1") {
      const key = k === "ClusterRole" ? `ClusterRole/${d.obj.metadata?.name}` : `Role/${d.obj.metadata?.namespace}/${d.obj.metadata?.name}`;
      roles.set(key, d);
    }
  }
  const isReadonly = (d: Doc) => d.obj.metadata?.labels?.[READONLY_LABEL] !== undefined;

  for (const d of roles.values()) {
    if (d.obj.metadata?.name === "homelab-readonly" && !isReadonly(d)) {
      out.push({ rule: "readonly-rbac", where: id(d), message: `homelab-readonly에 라벨 ${READONLY_LABEL}이 없다` });
    }
    if (!isReadonly(d)) continue;
    if (d.obj.aggregationRule) out.push({ rule: "readonly-rbac", where: id(d), message: "aggregationRule은 다른 역할의 권한을 끌어온다" });
    (d.obj.rules ?? []).forEach((rule: any, i: number) => {
      const where = `${id(d)} rules[${i}]`;
      const verbs: string[] = rule.verbs ?? [];
      const bad = verbs.filter((v) => !READONLY_VERBS.has(v));
      if (bad.length) out.push({ rule: "readonly-rbac", where, message: `읽기 밖 verb: ${bad.join(", ")}` });
      if (rule.nonResourceURLs) out.push({ rule: "readonly-rbac", where, message: "nonResourceURLs를 쓰지 않는다" });
      for (const g of rule.apiGroups ?? []) if (g === "*") out.push({ rule: "readonly-rbac", where, message: "apiGroups에 *" });
      for (const r of rule.resources ?? []) {
        if (r === "*" || r.endsWith("/*")) out.push({ rule: "readonly-rbac", where, message: `resources에 와일드카드: ${r}` });
        if (READONLY_FORBIDDEN_RESOURCES.has(r)) out.push({ rule: "readonly-rbac", where, message: `읽기 전용 역할이 ${r}를 읽는다` });
      }
    });
  }

  for (const d of docs) {
    const k = d.obj.kind;
    if (k !== "ClusterRoleBinding" && k !== "RoleBinding") continue;
    const subjects: any[] = d.obj.subjects ?? [];
    const ref = d.obj.roleRef ?? {};
    const refKey = ref.kind === "ClusterRole" ? `ClusterRole/${ref.name}` : `Role/${d.obj.metadata?.namespace}/${ref.name}`;
    const target = roles.get(refKey);
    const bindsReader = subjects.some((s) => s.kind === "ServiceAccount" && READONLY_SUBJECTS.has(s.name));
    const refsReadonly = ref.name === "homelab-readonly" || (target !== undefined && isReadonly(target));
    if (bindsReader && !(target && isReadonly(target))) {
      out.push({ rule: "readonly-rbac", where: id(d), message: `bot-reader를 읽기 전용 라벨이 없는 역할(${refKey})에 묶는다` });
    }
    if (refsReadonly && !target) {
      out.push({ rule: "readonly-rbac", where: id(d), message: `읽기 전용 역할 ${refKey}가 같은 렌더에 없다` });
    }
  }
  return out;
}

// Ingress host(설계 C.3.4 공개 host 한 단계, C.3.5·D-30 tailnet 이름).
export function checkIngress(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  for (const d of docs) {
    if (d.obj.kind !== "Ingress") continue;
    const cls = d.obj.spec?.ingressClassName;
    const where = id(d);
    if (cls === "traefik") {
      const rules: any[] = d.obj.spec?.rules ?? [];
      if (rules.length === 0) out.push({ rule: "ingress", where, message: "traefik Ingress에 host 규칙이 없다" });
      for (const r of rules) {
        if (typeof r.host !== "string" || !PUBLIC_HOST.test(r.host)) out.push({ rule: "ingress", where, message: `공개 host는 <이름>.ukyi.app 한 단계만: ${r.host}` });
      }
      if (d.obj.spec?.defaultBackend) out.push({ rule: "ingress", where, message: "traefik Ingress에 defaultBackend를 두지 않는다(모르는 host는 404)" });
    } else if (cls === "tailscale") {
      // 이름은 tls.hosts가 정한다. rules의 host를 쓰면 tls.hosts의 이름과 같아야 한다.
      const tlsHosts: unknown[] = (d.obj.spec?.tls ?? []).flatMap((t: any) => t.hosts ?? []);
      if (tlsHosts.length === 0) out.push({ rule: "ingress", where, message: "tailscale Ingress에 tls.hosts가 없다" });
      for (const h of tlsHosts) {
        if (typeof h !== "string" || !DNS_LABEL.test(h)) out.push({ rule: "ingress", where, message: `tailnet 이름은 DNS 라벨 하나: ${h}` });
        else if (RESERVED_TAILNET_NAMES.has(h)) out.push({ rule: "ingress", where, message: `${h}는 짧은 주소 리다이렉터 이름이라 예약돼 있다(D-30)` });
      }
      for (const r of d.obj.spec?.rules ?? []) {
        if (r.host !== undefined && !tlsHosts.includes(r.host)) out.push({ rule: "ingress", where, message: `rules의 host ${r.host}가 tls.hosts에 없다` });
      }
    } else {
      out.push({ rule: "ingress", where, message: `ingressClassName은 traefik이나 tailscale: ${cls}` });
    }
  }
  return out;
}

export function checkAll(docs: Doc[]): Violation[] {
  return [...checkNoSecrets(docs), ...checkWorkloads(docs), ...checkRevisions(docs), ...checkReadonlyRbac(docs), ...checkIngress(docs)];
}
