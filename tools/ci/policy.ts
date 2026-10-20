// 렌더 결과 정책 검사(설계 C.4.6 "렌더 결과 정책"). 입력은 render.ts의 Doc 목록이고, 위반 목록을 돌려준다.
// 규칙마다 "대상 0건이면 실패"는 main.ts가 아니라 여기서 센다(L40). 앱이 없는 저장소처럼 대상이 0일 수 있는 규칙은
// 세지 않는다.
import { type Doc, type Violation, sameRepo } from "./lib";

// 렌더에 나오는 상류 매니페스트의 예외. Argo CD는 공식 install.yaml을 그대로 쓴다(설계 C.3.3).
// 이미지는 URL의 버전 태그로 고정되고(digest 아님), 자원 상한이 없고, 빈 Secret 둘을 낸다. 값은 저장소에 없다.
// 예외는 platform/argocd 렌더 안의 알려진 상류 리소스와 상류 이미지에만 건다. 같은 kustomization에 로컬 워크로드를
// 더하거나 patch로 이미지를 바꾸면 예외가 적용되지 않는다.
const UPSTREAM_ARGOCD_ORIGIN = /:platform\/argocd$/;
const UPSTREAM_ARGOCD_WORKLOADS = new Set([
  "Deployment/argocd-applicationset-controller",
  "Deployment/argocd-dex-server",
  "Deployment/argocd-notifications-controller",
  "Deployment/argocd-redis",
  "Deployment/argocd-repo-server",
  "Deployment/argocd-server",
  "StatefulSet/argocd-application-controller",
]);
const UPSTREAM_ARGOCD_IMAGES = /^(quay\.io\/argoproj\/argocd|ghcr\.io\/dexidp\/dex|public\.ecr\.aws\/docker\/library\/redis):[\w.-]+$/;
const UPSTREAM_ARGOCD_SECRETS = new Set(["argocd-secret", "argocd-notifications-secret"]);

function upstreamArgocdWorkload(d: Doc, images: string[]): boolean {
  return (
    UPSTREAM_ARGOCD_ORIGIN.test(d.origin) &&
    UPSTREAM_ARGOCD_WORKLOADS.has(`${d.obj.kind}/${d.obj.metadata?.name}`) &&
    images.every((i) => UPSTREAM_ARGOCD_IMAGES.test(i))
  );
}

const WORKLOAD_KINDS = new Set(["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job", "CronJob", "Pod"]);
const DIGEST_IMAGE = /^[a-z0-9][a-z0-9._\-/:]*@sha256:[0-9a-f]{64}$/;
const PUBLIC_HOST = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.ukyi\.app$/;
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
// 봇 읽기 계정 SA. 이 SA를 포함하는 주체를 묶는 바인딩은 읽기 전용 라벨이 붙은 역할만 가리켜야 한다(roleRef 우회, L30).
// SA는 system:serviceaccounts, system:serviceaccounts:<ns>, system:authenticated 그룹에 자동으로 든다.
const READONLY_SUBJECTS = new Set(["bot-reader"]);
function coversReader(s: any): boolean {
  if (s?.kind === "ServiceAccount") return READONLY_SUBJECTS.has(s.name);
  if (s?.kind === "User") return /^system:serviceaccount:[^:]+:bot-reader$/.test(String(s.name));
  if (s?.kind === "Group") return /^system:(serviceaccounts(:.+)?|authenticated)$/.test(String(s.name));
  return false;
}

// kind: List의 items를 펼친다. kubectl·Argo CD는 List 안 리소스를 각각 적용한다.
function expand(docs: Doc[]): Doc[] {
  return docs.flatMap((d) =>
    d.obj?.kind === "List" && Array.isArray(d.obj.items) ? expand(d.obj.items.map((obj: any) => ({ origin: d.origin, obj }))) : [d],
  );
}

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
  docs = expand(docs);
  return docs
    .filter((d) => d.obj.kind === "Secret" && d.obj.apiVersion === "v1")
    .filter((d) => !(UPSTREAM_ARGOCD_ORIGIN.test(d.origin) && UPSTREAM_ARGOCD_SECRETS.has(d.obj.metadata?.name) && !d.obj.data && !d.obj.stringData))
    .map((d) => ({ rule: "no-secret", where: id(d), message: "kind: Secret을 렌더한다. 값은 Infisical, 사본은 ExternalSecret으로" }));
}

// L27 이미지는 digest로(sha256: + 64자. 접두만 재면 sha256:deadbeef가 통과한다), L28 requests와 memory limit.
export function checkWorkloads(docs: Doc[]): Violation[] {
  docs = expand(docs);
  const out: Violation[] = [];
  let seen = 0;
  for (const d of docs) {
    if (!WORKLOAD_KINDS.has(d.obj.kind)) continue;
    const spec = podSpec(d.obj) ?? {};
    const containers = [...(spec.initContainers ?? []), ...(spec.containers ?? [])];
    if (upstreamArgocdWorkload(d, containers.map((c: any) => String(c.image)))) continue;
    seen++;
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
// 정확한 릴리스 태그만. 접두만 보면 app-chart-v-dev 같은 움직이는 브랜치를 가리킬 수 있다.
// ApplicationSet 템플릿은 앱마다 고른 버전을 쓰므로 그 템플릿 식 하나만 더 받는다(값은 차트 schema가 semver로 묶는다).
const CHART_TAGS: Record<string, RegExp> = {
  "platform/charts/app": /^app-chart-v(\d+\.\d+\.\d+|\{\{ \.chartVersion \}\})$/,
  "platform/charts/app-data": /^data-chart-v(\d+\.\d+\.\d+|\{\{ \.chartVersion \}\})$/,
};

// 외부 source는 움직이지 않는 revision만: Helm 차트는 정확한 semver, 그 밖(git)은 40자 커밋 SHA.
// 외부 차트는 렌더하지 않으므로(외부 레지스트리 조회는 필수 검사 밖) 이 검사가 유일한 그물이다.
const EXACT_SEMVER = /^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;

function checkRevision(where: string, src: any, out: Violation[]): void {
  if (!src) return;
  if (!sameRepo(src.repoURL)) {
    const rev = src.targetRevision ?? src.revision;
    const ok = src.chart ? typeof rev === "string" && EXACT_SEMVER.test(rev) : typeof rev === "string" && /^[0-9a-f]{40}$/.test(rev);
    if (!ok) out.push({ rule: "revision", where, message: `외부 source의 revision이 고정값이 아니다(차트는 정확한 semver, git은 커밋 SHA): ${src.repoURL} ${rev}` });
    return;
  }
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
  docs = expand(docs);
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
// 렌더 맥락(클러스터). 역할과 바인딩은 같은 맥락 안에서만 잇는다. 클러스터마다 같은 이름의 역할이 렌더되므로
// 하나의 맵에 넣으면 한쪽이 다른 쪽을 덮어 위반을 놓친다.
function context(origin: string): string {
  return origin.match(/\[([a-z0-9-]+)\]/)?.[1] ?? origin;
}

export function checkReadonlyRbac(docs: Doc[]): Violation[] {
  docs = expand(docs);
  const out: Violation[] = [];
  const roles: Doc[] = docs.filter(
    (d) => (d.obj.kind === "ClusterRole" || d.obj.kind === "Role") && d.obj.apiVersion === "rbac.authorization.k8s.io/v1",
  );
  const isReadonly = (d: Doc) => d.obj.metadata?.labels?.[READONLY_LABEL] !== undefined;
  const find = (ctx: string, kind: string, name: string, ns?: string) =>
    roles.find(
      (r) => context(r.origin) === ctx && r.obj.kind === kind && r.obj.metadata?.name === name && (kind === "ClusterRole" || r.obj.metadata?.namespace === ns),
    );

  // 역할 문서는 하나도 빼지 않고 모두 본다.
  for (const d of roles) {
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
    const target = find(context(d.origin), ref.kind, ref.name, d.obj.metadata?.namespace);
    const refDesc = `${ref.kind}/${ref.name}`;
    const bindsReader = subjects.some(coversReader);
    if (bindsReader && !(target && isReadonly(target))) {
      out.push({ rule: "readonly-rbac", where: id(d), message: `bot-reader(또는 그 SA가 드는 그룹)를 같은 렌더의 읽기 전용 라벨 역할이 아닌 ${refDesc}에 묶는다` });
    }
    if (ref.name === "homelab-readonly" && !target) {
      out.push({ rule: "readonly-rbac", where: id(d), message: `읽기 전용 역할 ${refDesc}가 같은 렌더에 없다` });
    }
  }
  return out;
}

// Ingress host(설계 C.3.4 공개 host 한 단계, C.3.5·D-30 tailnet 이름).
export function checkIngress(docs: Doc[]): Violation[] {
  docs = expand(docs);
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
