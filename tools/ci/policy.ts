// 렌더 결과 정책 검사(설계 C.4.6 "렌더 결과 정책"). 입력은 render.ts의 Doc 목록이고, 위반 목록을 돌려준다.
// 규칙마다 "대상 0건이면 실패"는 main.ts가 아니라 여기서 센다(L40). 앱이 없는 저장소처럼 대상이 0일 수 있는 규칙은
// 세지 않는다.
import { type Doc, type Violation, effectiveSources, gitFiles, readText, sameRepo } from "./lib";

// 렌더에 나오는 상류 매니페스트의 예외. Argo CD는 공식 install.yaml을 그대로 쓴다(설계 C.3.3).
// 이미지는 URL의 버전 태그로 고정되고(digest 아님), 자원 상한이 없고, 빈 Secret 둘을 낸다. 값은 저장소에 없다.
// 예외는 platform/argocd 렌더 안의 알려진 상류 리소스와 상류 이미지에만 건다. 같은 kustomization에 로컬 워크로드를
// 더하거나 patch로 이미지를 바꾸면 예외가 적용되지 않는다.
const UPSTREAM_ARGOCD_ORIGIN = /:platform\/argocd$/;
// 상류 워크로드와 그 컨테이너(initContainers / containers 이름, 순서 그대로). 예외는 이 집합과 정확히 같을 때만이다.
// patch로 sidecar·initContainer를 더하면(허용된 상류 이미지를 써도) 예외가 사라지고 일반 검사를 받는다.
const UPSTREAM_ARGOCD_WORKLOADS: Record<string, { init: string[]; containers: string[] }> = {
  "Deployment/argocd-applicationset-controller": { init: [], containers: ["argocd-applicationset-controller"] },
  "Deployment/argocd-dex-server": { init: ["copyutil"], containers: ["dex"] },
  "Deployment/argocd-notifications-controller": { init: [], containers: ["argocd-notifications-controller"] },
  "Deployment/argocd-redis": { init: ["secret-init"], containers: ["redis"] },
  "Deployment/argocd-repo-server": { init: ["copyutil"], containers: ["argocd-repo-server"] },
  "Deployment/argocd-server": { init: [], containers: ["argocd-server"] },
  "StatefulSet/argocd-application-controller": { init: [], containers: ["argocd-application-controller"] },
};
const UPSTREAM_ARGOCD_IMAGES = new Set([
  "quay.io/argoproj/argocd:v3.5.5",
  "ghcr.io/dexidp/dex:v2.45.1",
  "public.ecr.aws/docker/library/redis:8.2.3-alpine",
]);
const UPSTREAM_ARGOCD_SECRETS = new Set(["argocd-secret", "argocd-notifications-secret"]);

function upstreamArgocdWorkload(d: Doc, spec: any): boolean {
  const want = UPSTREAM_ARGOCD_WORKLOADS[`${d.obj.kind}/${d.obj.metadata?.name}`];
  if (!UPSTREAM_ARGOCD_ORIGIN.test(d.origin) || !want) return false;
  const init: any[] = spec.initContainers ?? [];
  const main: any[] = spec.containers ?? [];
  const names = (cs: any[]) => JSON.stringify(cs.map((c) => c.name));
  return (
    names(init) === JSON.stringify(want.init) &&
    names(main) === JSON.stringify(want.containers) &&
    [...init, ...main].every((c) => UPSTREAM_ARGOCD_IMAGES.has(String(c.image)))
  );
}

export const WORKLOAD_KINDS = new Set(["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job", "CronJob", "Pod"]);
const DIGEST_IMAGE = /^[a-z0-9][a-z0-9._\-/:]*@sha256:[0-9a-f]{64}$/;
const PUBLIC_HOST = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.ukyi\.app$/;
// Tailscale 기기 이름: 문자로 시작하고 끝나는 DNS 라벨(tailscale.com custom-machine-names).
const TAILNET_NAME = /^[a-z]([a-z0-9-]{0,61}[a-z])?$/;
// Ingress가 아닌 tailnet 기기 이름. 같은 이름의 Ingress 프록시가 생기면 뒤에 붙은 쪽 이름이 바뀐다.
// go·vm-go는 D-30 리다이렉터, tailscale-operator는 operator(platform/root/templates/tailscale.yaml),
// 노드(NUC는 tailnet 기기)는 host/clusters/*.env의 TAILNET_DEVICE_NAME이고, 비면 NODE_NAME이다. 둘 다 예약한다.
const RESERVED_TAILNET_NAMES = new Set(["go", "vm-go", "tailscale-operator", "vm-tailscale-operator", ...nodeNames()]);

function nodeNames(): string[] {
  return gitFiles("host/clusters/*.env").flatMap((f) =>
    readText(f)
      .split("\n")
      .map((l) => l.match(/^(?:NODE_NAME|TAILNET_DEVICE_NAME)=["']?([a-z0-9-]+)["']?\s*$/)?.[1])
      .filter((x): x is string => !!x),
  );
}

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
// kind: List를 펼친다. 항목은 List와 같은 Application에서 렌더됐으므로 부모의 유효 ns(destination)를 물려받는다.
export function expand(docs: Doc[]): Doc[] {
  return docs.flatMap((d) =>
    d.obj?.kind === "List" && Array.isArray(d.obj.items) ? expand(d.obj.items.map((obj: any) => ({ origin: d.origin, obj, ns: d.ns }))) : [d],
  );
}

export function podSpec(obj: any): any | undefined {
  switch (obj.kind) {
    case "Pod":
      return obj.spec;
    case "CronJob":
      return obj.spec?.jobTemplate?.spec?.template?.spec;
    default:
      return obj.spec?.template?.spec;
  }
}

export function id(d: Doc): string {
  const ns = d.obj.metadata?.namespace ? `${d.obj.metadata.namespace}/` : "";
  return `${d.origin} ${d.obj.kind}/${ns}${d.obj.metadata?.name}`;
}

// kind: Secret 0건(설계 C.6.2). 시크릿 값은 Infisical에만 있고 Kubernetes Secret은 ESO가 만든다.
export function checkNoSecrets(docs: Doc[]): Violation[] {
  docs = expand(docs);
  return docs
    .filter((d) => d.obj.kind === "Secret" && d.obj.apiVersion === "v1")
    // 값 필드(data, stringData, binaryData 등)가 하나도 없는 상류 Secret만 예외다. 허용 키 밖이 있으면 걸린다.
    .filter(
      (d) =>
        !(
          UPSTREAM_ARGOCD_ORIGIN.test(d.origin) &&
          UPSTREAM_ARGOCD_SECRETS.has(d.obj.metadata?.name) &&
          Object.keys(d.obj).every((k) => ["apiVersion", "kind", "metadata", "type"].includes(k))
        ),
    )
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
    // image volume(Kubernetes 1.36 stable)도 OCI 참조를 끌어온다. 상류 예외보다 먼저, 모든 워크로드에 본다.
    for (const v of spec.volumes ?? []) {
      if (v?.image !== undefined && !(typeof v.image.reference === "string" && DIGEST_IMAGE.test(v.image.reference))) {
        out.push({ rule: "image-digest", where: `${id(d)} volume ${v.name}`, message: `image volume이 digest 고정이 아니다: ${v.image?.reference} (L27)` });
      }
    }
    if (upstreamArgocdWorkload(d, spec)) continue;
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
// semver.org의 권장 정규식(선행 0·빈 식별자 거부)에 v 접두를 더해 둔다. build 메타데이터(+...)는 받지 않는다.
const EXACT_SEMVER =
  /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-((0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?$/;

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
      for (const s of effectiveSources(d.obj.spec)) checkRevision(where, s, out);
    }
    if (d.obj.kind === "ApplicationSet" && d.obj.apiVersion?.startsWith("argoproj.io/")) {
      seen++;
      for (const s of effectiveSources(d.obj.spec?.template?.spec)) checkRevision(where, s, out);
      walkGenerators(d.obj.spec?.generators, where, out);
    }
  }
  if (seen === 0) out.push({ rule: "revision", where: "render", message: "검사한 Argo CD Application이 0개다(L40)" });
  return out;
}

// L30 읽기 전용 역할의 verb·자원과 roleRef. 라벨을 떼면 첫 검사를 피하므로, bot-reader 바인딩과 이름 homelab-readonly도 본다.
// 렌더 맥락(클러스터). 역할과 바인딩은 같은 맥락 안에서만 잇는다. 클러스터마다 같은 이름의 역할이 렌더되므로
// 하나의 맵에 넣으면 한쪽이 다른 쪽을 덮어 위반을 놓친다.
export function context(origin: string): string {
  return origin.match(/\[([a-z0-9-]+)\]/)?.[1] ?? origin;
}

export function checkReadonlyRbac(docs: Doc[]): Violation[] {
  docs = expand(docs);
  const out: Violation[] = [];
  const roles: Doc[] = docs.filter(
    (d) => (d.obj.kind === "ClusterRole" || d.obj.kind === "Role") && d.obj.apiVersion === "rbac.authorization.k8s.io/v1",
  );
  const isReadonly = (d: Doc) => d.obj.metadata?.labels?.[READONLY_LABEL] !== undefined;
  // Role·RoleBinding의 ns는 렌더한 Application의 유효 destination namespace까지 본다(metadata.namespace가 없을 때).
  const nsOf = (d: Doc) => d.obj.metadata?.namespace ?? d.ns;
  const find = (ctx: string, kind: string, name: string, ns?: string) =>
    roles.find((r) => context(r.origin) === ctx && r.obj.kind === kind && r.obj.metadata?.name === name && (kind === "ClusterRole" || (ns !== undefined && nsOf(r) === ns)));

  // 같은 맥락에 같은 역할이 둘이면 어느 쪽이 적용될지 렌더만으로 알 수 없다(Argo CD 다중 source는 뒤가 이긴다).
  // roleRef 판정이 앞의 것을 보고 통과하지 않게 중복 자체를 막는다.
  const seenRoles = new Set<string>();
  for (const d of roles) {
    const key = `${context(d.origin)}|${d.obj.kind}|${d.obj.kind === "ClusterRole" ? "" : (nsOf(d) ?? "")}|${d.obj.metadata?.name}`;
    if (seenRoles.has(key)) out.push({ rule: "readonly-rbac", where: id(d), message: "같은 렌더 맥락에 같은 kind·이름의 역할이 둘 있다" });
    seenRoles.add(key);
  }

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
    const target = find(context(d.origin), ref.kind, ref.name, nsOf(d));
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
  // 같은 클러스터 안에서 host는 하나의 Ingress만 갖는다. tailnet은 같은 이름의 기기가 있으면 새 기기 이름을 바꿔
  // 선언한 주소(와 go/<이름>)로 닿지 않고, 공개 host는 Traefik이 두 Ingress를 섞는다.
  const owners = new Map<string, string>();
  // tailnet은 운영과 VM이 함께 쓴다(접두 ""와 "vm-"). 그래서 클러스터 렌더의 tailscale 이름은 클러스터를 넘어 비교한다
  // (앱 A의 foo가 VM에서 vm-foo, 앱 B의 vm-foo가 운영에서 vm-foo). 차트 시험 values 같은 비배포 렌더는 제 맥락 안에서만.
  const claim = (d: Doc, cls: string, host: string, where: string) => {
    const ctx = context(d.origin);
    const scope = cls === "tailscale" && ctx !== d.origin ? "tailnet" : ctx;
    const key = `${scope}|${cls}|${host}`;
    const prev = owners.get(key);
    if (prev && prev !== where) out.push({ rule: "ingress", where, message: `${cls} host ${host}를 ${prev}도 쓴다` });
    else owners.set(key, where);
  };
  for (const d of docs) {
    if (d.obj.kind !== "Ingress") continue;
    const cls = d.obj.spec?.ingressClassName;
    const where = id(d);
    if (cls === "traefik") {
      const rules: any[] = d.obj.spec?.rules ?? [];
      if (rules.length === 0) out.push({ rule: "ingress", where, message: "traefik Ingress에 host 규칙이 없다" });
      for (const r of rules) {
        if (typeof r.host !== "string" || !PUBLIC_HOST.test(r.host)) out.push({ rule: "ingress", where, message: `공개 host는 <이름>.ukyi.app 한 단계만: ${r.host}` });
        else claim(d, "traefik", r.host, where);
      }
      if (d.obj.spec?.defaultBackend) out.push({ rule: "ingress", where, message: "traefik Ingress에 defaultBackend를 두지 않는다(모르는 host는 404)" });
    } else if (cls === "tailscale") {
      // 이름은 tls.hosts가 정한다. rules의 host를 쓰면 tls.hosts의 이름과 같아야 한다.
      const tlsHosts: unknown[] = (d.obj.spec?.tls ?? []).flatMap((t: any) => t.hosts ?? []);
      if (tlsHosts.length === 0) out.push({ rule: "ingress", where, message: "tailscale Ingress에 tls.hosts가 없다" });
      for (const h of tlsHosts) {
        if (typeof h !== "string" || !TAILNET_NAME.test(h)) out.push({ rule: "ingress", where, message: `tailnet 이름은 문자로 시작·끝나는 DNS 라벨 하나: ${h}` });
        else if (RESERVED_TAILNET_NAMES.has(h)) out.push({ rule: "ingress", where, message: `${h}는 Ingress가 아닌 tailnet 기기(리다이렉터 D-30, operator, 노드)의 이름이라 예약돼 있다` });
        else claim(d, "tailscale", h, where);
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

// 격리 작업 공간(설계 C.8 격리 행). sandbox ns 워크로드의 자격·권한과 작업자의 프록시 주소를 본다.
// 방화벽 init(egress-firewall)은 첫 init으로 꼭 있어야 한다. 없으면 netpol 적용 전 공백과 노드 로컬 경로가 열린다.
// NET_ADMIN은 그 컨테이너에만. 다른 init·본 컨테이너가 가지면 출력 차단 규칙을 지우고 노드 로컬 경로로 나간다.
// automount만 끄면 projected serviceAccountToken 볼륨으로 여전히 토큰을 받을 수 있다.
// RoleBinding은 다른 ns에 있어도 subject로 sandbox SA를 묶을 수 있어 바인딩 ns와 subject를 둘 다 본다.
// SA는 kind: User(system:serviceaccount:sandbox:<이름>)로도 묶인다. API 서버가 SA 토큰을 그 사용자 이름으로 인증한다.
// 방화벽 init은 이름·capability만 보면 기본 DROP을 빼거나 허용 주소를 바꿔도 통과한다. 그래서 명령과 규칙 줄을
// 고정본과 맞추고(빈 줄·주석 줄은 뺀다), PROXY_IP·PROXY_PORT env도 egress-proxy Service와 맞춘다.
// 규칙이 실제로 걸리게 이미지·env·마운트도 고정한다. 아니면 PATH나 마운트로 no-op iptables를 앞세워 통과한다.
// args는 문자열 하나다. sh -c는 첫 원소만 스크립트로 돌리고 나머지는 $0·$1이 된다.
// 같은 이름의 env가 둘이면 kubelet은 뒤의 값을 쓰는데 검사가 앞의 값을 보면 어긋난다. 그래서 중복 이름을 거부한다.
// HTTPS_PROXY는 같은 렌더 맥락의 egress/egress-proxy Service clusterIP·포트여야 한다. 어긋나면 init 규칙이 허용한 주소와
// 작업자가 쓰는 주소가 달라 모든 외부 연결이 끊기거나, 다른 주소를 허용하게 된다. Service가 없으면 비교할 기준이 없어 실패로 본다.
// sandbox 구성 요소를 끄면 대상이 0이라 세지 않는다.
//
// 작업 레인 보안 조합(봇 DECISIONS "(2) 파드 실측 결과와 대가 수용"). hostUsers: false·procMount: Unmasked·Localhost 프로필은
// bwrap을 돌리려고 연 권한이고 전용 프로필은 containerd 기본의 복사본이다. worker-task의 worker 컨테이너 밖으로 번지면 그 파드의
// seccomp·AppArmor 경계가 조용히 넓어진다. 그래서 모든 ns의 워크로드를 본다. 켠 렌더는 platform/sandbox/ci/task-enabled.yaml이다.
// 옛 AppArmor 주석도 같은 효과라 함께 막는다.
// shareProcessNamespace는 pause를 PID 1로 두어 좀비를 회수하게 하려고 worker-task에 꼭 있어야 한다. 다른 파드에서는 컨테이너끼리
// 프로세스와 그 환경이 보이므로 허용하지 않는다. 정리 sweep이 PID 1과 작업자 밖을 모두 끝내므로 exec probe·lifecycle을 막는다.
// 저장 공간은 호스트 고정 크기 볼륨의 정적 PV에 묶는다. local 볼륨은 크기를 강제하지 않아 상한은 그 파일시스템에서만 온다.
// 라벨·자격·PVC도 나눈다. app: worker를 함께 달면 Service worker가 대화·리뷰 요청을 작업 파드로 보내고, 자격을 함께 붙이면
// 한 레인의 토큰만 철회한다는 분리가 사라진다.
const SANDBOX_NS = "sandbox";
const SANDBOX_TASK = "worker-task";
const SANDBOX_TASK_CONTAINER = "worker";
const SANDBOX_TASK_LABELS = { app: SANDBOX_TASK };
const SANDBOX_TASK_SECRET = "worker-task-credential-claude-subscription";
const SANDBOX_TASK_PVC = "worker-task-state";
// host/lib.sh SANDBOX_SECCOMP_DIR(kubelet seccomp 아래 homelab/)와 host/sandbox-profiles/의 정식 이름.
const SANDBOX_TASK_SECCOMP = "homelab/sandbox-worker-v1.json";
const SANDBOX_TASK_APPARMOR = "homelab-sandbox-worker-v1";
// host/lib.sh TASK_STATE_*와 같은 값. 2GiB 고정 크기 볼륨의 마운트 지점이다.
const SANDBOX_TASK_VOLUME_MOUNT = "/var/lib/taskstate/mnt";
const SANDBOX_TASK_VOLUME_SIZE = "2Gi";
// 작업 레인 밖의 Localhost 프로필 예외는 하나다. node-exporter의 systemd 수집기는 containerd 기본 AppArmor가 시스템 버스를
// 막아 실패해서, 기본값에 유닛 읽기 호출만 더한 AppArmor를 쓴다(host/sandbox-profiles/). seccomp Localhost는 받지 않는다.
const NODE_EXPORTER = { ns: "observability", kind: "DaemonSet", name: "node-exporter", container: "node-exporter" };
const NODE_EXPORTER_APPARMOR = /^homelab-sandbox-node-exporter-v\d+$/;
const SANDBOX_TASK_VOLUME_BYTES = 2147483648;
const LEGACY_PROFILE_ANNOTATION = /^(container\.apparmor\.security\.beta\.kubernetes\.io|container\.seccomp\.security\.alpha\.kubernetes\.io|seccomp\.security\.alpha\.kubernetes\.io)\//;
const podTemplateMeta = (obj: any): any => (obj.kind === "Pod" ? obj.metadata : obj.kind === "CronJob" ? obj.spec?.jobTemplate?.spec?.template?.metadata : obj.spec?.template?.metadata);

// 커밋한 프로필과 이름이 어긋나면 노드에 없는 프로필을 참조해 파드가 뜨지 않는다.
function sandboxTaskProfileFiles(): Violation[] {
  const where = "host/sandbox-profiles";
  const out: Violation[] = [];
  const seccomp = SANDBOX_TASK_SECCOMP.replace(/^homelab\//, "");
  if (!gitFiles(`host/sandbox-profiles/seccomp/${seccomp}`).length) out.push({ rule: "sandbox", where, message: `seccomp 프로필 ${seccomp}이 없다` });
  if (!readText("host/lib.sh").includes('/seccomp/homelab"')) out.push({ rule: "sandbox", where: "host/lib.sh", message: "SANDBOX_SECCOMP_DIR가 kubelet seccomp 아래 homelab이 아니다" });
  const apparmor = `host/sandbox-profiles/apparmor/${SANDBOX_TASK_APPARMOR}`;
  if (!gitFiles(apparmor).length || !readText(apparmor).includes(`\nprofile ${SANDBOX_TASK_APPARMOR} `)) out.push({ rule: "sandbox", where, message: `AppArmor 프로필 ${SANDBOX_TASK_APPARMOR}이 없다` });
  const lib = readText("host/lib.sh");
  if (!lib.includes(`TASK_STATE_MOUNT=${SANDBOX_TASK_VOLUME_MOUNT}\n`) || !lib.includes(`TASK_STATE_BYTES=${SANDBOX_TASK_VOLUME_BYTES}\n`) || !lib.includes('TASK_STATE_DATA="${TASK_STATE_MOUNT}/data"\n')) {
    out.push({ rule: "sandbox", where: "host/lib.sh", message: `TASK_STATE_* 값이 PV ${SANDBOX_TASK_PVC}와 다르다(${SANDBOX_TASK_VOLUME_MOUNT}/data, ${SANDBOX_TASK_VOLUME_BYTES}바이트)` });
  }
  return out;
}

// 저장 공간이 고정 크기 볼륨 안에 있는지. 동적 local-retain으로 돌아가거나 경로가 어긋나면 비신뢰 코드가 노드 루트 디스크를 채운다.
function checkSandboxTaskVolume(d: Doc): Violation[] {
  const out: Violation[] = [];
  const bad = (message: string) => out.push({ rule: "sandbox", where: id(d), message: `저장 공간: ${message}` });
  const s = d.obj.spec ?? {};
  if (d.obj.kind === "PersistentVolumeClaim") {
    if (s.storageClassName !== "" || s.volumeName !== SANDBOX_TASK_PVC) bad(`PVC는 storageClassName ""와 volumeName ${SANDBOX_TASK_PVC}로 정적 PV에 묶는다(지금 ${JSON.stringify(s.storageClassName)}, ${s.volumeName})`);
    if (s.resources?.requests?.storage !== SANDBOX_TASK_VOLUME_SIZE) bad(`PVC 요청이 ${SANDBOX_TASK_VOLUME_SIZE}가 아니다`);
    return out;
  }
  if (s.local?.path !== `${SANDBOX_TASK_VOLUME_MOUNT}/data` || s.hostPath !== undefined) bad(`PV는 local ${SANDBOX_TASK_VOLUME_MOUNT}/data여야 한다(마운트 지점 자체면 마운트가 빠질 때 루트 디스크로 샌다)`);
  if (s.persistentVolumeReclaimPolicy !== "Retain" || s.storageClassName !== "" || s.capacity?.storage !== SANDBOX_TASK_VOLUME_SIZE) bad(`PV는 Retain, storageClassName "", 용량 ${SANDBOX_TASK_VOLUME_SIZE}다`);
  const ref = s.claimRef ?? {};
  if (Object.keys(ref).sort().join() !== "name,namespace" || ref.name !== SANDBOX_TASK_PVC || ref.namespace !== SANDBOX_NS) bad(`claimRef는 ${SANDBOX_NS}/${SANDBOX_TASK_PVC}의 이름·ns만 적는다(uid를 적으면 재구축 때 묶이지 않는다)`);
  const terms: any[] = s.nodeAffinity?.required?.nodeSelectorTerms ?? [];
  const e = terms[0]?.matchExpressions?.[0];
  if (terms.length !== 1 || terms[0]?.matchExpressions?.length !== 1 || e?.key !== "kubernetes.io/hostname" || e?.operator !== "In" || e?.values?.length !== 1 || !e.values[0]) bad("nodeAffinity는 kubernetes.io/hostname In [노드 하나] 하나다");
  return out;
}

// 조합이 worker-task의 worker 컨테이너에만 있는지. 모든 ns의 워크로드에 적용한다.
function checkSandboxTaskScope(d: Doc, isTask: boolean, spec: any, inSandbox: boolean): Violation[] {
  const out: Violation[] = [];
  const where = id(d);
  const push = (w: string, message: string) => out.push({ rule: "sandbox", where: w, message });
  if (spec.hostUsers === false && !isTask) push(where, `hostUsers: false는 ${SANDBOX_TASK}에만 쓴다`);
  if (spec.shareProcessNamespace === true && !isTask) push(where, `shareProcessNamespace: true는 ${SANDBOX_TASK}에만 쓴다`);
  const podSc = spec.securityContext ?? {};
  // 파드 수준 값은 NET_ADMIN을 든 init 방화벽까지 받는다.
  if (podSc.seccompProfile?.type === "Localhost" || podSc.appArmorProfile?.type === "Localhost") push(where, `Localhost 프로필은 파드 수준에 두지 않는다(${SANDBOX_TASK}의 ${SANDBOX_TASK_CONTAINER} 컨테이너만)`);
  if (inSandbox && (podSc.seccompProfile?.type === "Unconfined" || podSc.appArmorProfile?.type === "Unconfined")) push(where, "Unconfined 프로필을 쓰지 않는다");
  for (const k of Object.keys(podTemplateMeta(d.obj)?.annotations ?? {})) {
    if (LEGACY_PROFILE_ANNOTATION.test(k)) push(where, `프로필 주석 ${k}을 쓰지 않는다(securityContext로만 고른다)`);
  }
  const others: any[] = [...(spec.initContainers ?? []), ...(spec.ephemeralContainers ?? [])];
  for (const c of [...others, ...(spec.containers ?? [])]) {
    const allowed = isTask && !others.includes(c) && c.name === SANDBOX_TASK_CONTAINER;
    const sc = c.securityContext ?? {};
    const cw = `${where} container ${c.name}`;
    if (sc.procMount !== undefined && sc.procMount !== "Default" && !allowed) push(cw, `procMount: ${sc.procMount}는 ${SANDBOX_TASK}의 ${SANDBOX_TASK_CONTAINER} 컨테이너만 쓴다`);
    const nodeExporterAppArmor = (d.obj.metadata?.namespace ?? d.ns) === NODE_EXPORTER.ns && d.obj.kind === NODE_EXPORTER.kind && d.obj.metadata?.name === NODE_EXPORTER.name
      && !others.includes(c) && c.name === NODE_EXPORTER.container && sc.seccompProfile?.type !== "Localhost"
      && sc.appArmorProfile?.type === "Localhost" && NODE_EXPORTER_APPARMOR.test(sc.appArmorProfile?.localhostProfile ?? "");
    if ((sc.seccompProfile?.type === "Localhost" || sc.appArmorProfile?.type === "Localhost") && !allowed && !nodeExporterAppArmor) push(cw, `Localhost 프로필은 ${SANDBOX_TASK}의 ${SANDBOX_TASK_CONTAINER} 컨테이너(와 node-exporter AppArmor 하나)만 쓴다`);
    if (inSandbox && (sc.seccompProfile?.type === "Unconfined" || sc.appArmorProfile?.type === "Unconfined")) push(cw, "Unconfined 프로필을 쓰지 않는다");
  }
  return out;
}

// 작업 레인 Deployment가 있으면 조합이 다 있어야 한다. 하나라도 빠지면 작업 격리가 다른 것이 된다.
function checkSandboxTaskShape(d: Doc, spec: any): Violation[] {
  const out: Violation[] = [];
  const where = id(d);
  const bad = (message: string, w = where) => out.push({ rule: "sandbox", where: w, message: `${SANDBOX_TASK}: ${message}` });
  if (spec.hostUsers !== false) bad("hostUsers: false가 아니다");
  if (spec.shareProcessNamespace !== true) bad("shareProcessNamespace: true가 아니다(PID 1이 좀비를 회수하지 않는다)");
  if (d.obj.spec?.replicas !== 1 || d.obj.spec?.strategy?.type !== "Recreate") bad("replicas 1, Recreate가 아니다");
  const containers: any[] = spec.containers ?? [];
  if (containers.length !== 1 || containers[0]?.name !== SANDBOX_TASK_CONTAINER) bad(`본 컨테이너는 ${SANDBOX_TASK_CONTAINER} 하나여야 한다`);
  // 재시작형 init(사이드카)은 PID 공간을 함께 써 정리 sweep이 끝내고, 그동안 기준 상태 확인이 어긋난다.
  if ((spec.initContainers ?? []).length !== 1) bad(`init은 ${SANDBOX_FIREWALL} 하나여야 한다`);
  for (const c of [...(spec.initContainers ?? []), ...containers]) {
    const cw = `${where} container ${c.name}`;
    for (const p of ["readinessProbe", "livenessProbe", "startupProbe"]) if (c[p]?.exec) bad(`${p}에 exec를 쓰지 않는다(정리 sweep에 죽는다)`, cw);
    for (const h of ["postStart", "preStop"]) if (c.lifecycle?.[h]?.exec) bad(`lifecycle ${h}에 exec를 쓰지 않는다(정리 sweep에 죽는다)`, cw);
  }
  const c = containers.find((x) => x?.name === SANDBOX_TASK_CONTAINER);
  if (c) {
    const cw = `${where} container ${c.name}`;
    const sc = c.securityContext ?? {};
    if (sc.procMount !== "Unmasked") bad("procMount: Unmasked가 아니다", cw);
    if (sc.seccompProfile?.type !== "Localhost" || sc.seccompProfile?.localhostProfile !== SANDBOX_TASK_SECCOMP) bad(`seccomp가 Localhost ${SANDBOX_TASK_SECCOMP}가 아니다`, cw);
    if (sc.appArmorProfile?.type !== "Localhost" || sc.appArmorProfile?.localhostProfile !== SANDBOX_TASK_APPARMOR) bad(`AppArmor가 Localhost ${SANDBOX_TASK_APPARMOR}가 아니다`, cw);
    if (sc.runAsNonRoot !== true || sc.runAsUser !== 10001 || sc.runAsGroup !== 10001) bad("uid·gid 10001 비root가 아니다", cw);
    if (sc.readOnlyRootFilesystem !== true) bad("readOnlyRootFilesystem: true가 아니다", cw);
  }
  const labels = d.obj.spec?.template?.metadata?.labels ?? {};
  if (JSON.stringify(labels) !== JSON.stringify(SANDBOX_TASK_LABELS) || JSON.stringify(d.obj.spec?.selector?.matchLabels) !== JSON.stringify(SANDBOX_TASK_LABELS)) {
    bad(`파드 라벨·selector가 정확히 app: ${SANDBOX_TASK}가 아니다(Service worker에 섞인다)`);
  }
  return out;
}

// 레인 사이 공유 금지와 Service selector. 같은 렌더 맥락의 sandbox 문서를 함께 본다.
function checkSandboxLaneSplit(docs: Doc[], nsOf: (d: Doc) => string | undefined): Violation[] {
  const out: Violation[] = [];
  const inSandbox = docs.filter((d) => nsOf(d) === SANDBOX_NS);
  for (const d of inSandbox) {
    if (!WORKLOAD_KINDS.has(d.obj.kind)) continue;
    const isTask = d.obj.kind === "Deployment" && d.obj.metadata?.name === SANDBOX_TASK;
    const vols: any[] = podSpec(d.obj)?.volumes ?? [];
    const secrets = vols.flatMap((v) => [v?.secret?.secretName, ...(v?.projected?.sources ?? []).map((s: any) => s?.secret?.name)]).filter(Boolean);
    const claims = vols.map((v) => v?.persistentVolumeClaim?.claimName).filter(Boolean);
    const where = id(d);
    if (isTask) {
      if (secrets.join() !== SANDBOX_TASK_SECRET) out.push({ rule: "sandbox", where, message: `자격 분리: Secret은 ${SANDBOX_TASK_SECRET} 하나만 붙인다(지금 ${secrets.join(", ")})` });
      if (claims.join() !== SANDBOX_TASK_PVC) out.push({ rule: "sandbox", where, message: `자격 분리: PVC는 ${SANDBOX_TASK_PVC} 하나만 붙인다(지금 ${claims.join(", ")})` });
    } else if (secrets.includes(SANDBOX_TASK_SECRET) || claims.includes(SANDBOX_TASK_PVC)) {
      out.push({ rule: "sandbox", where, message: `자격 분리: ${SANDBOX_TASK}의 Secret·PVC를 다른 워크로드에 붙이지 않는다` });
    }
  }
  const tasks = inSandbox.filter((d) => d.obj.kind === "Deployment" && d.obj.metadata?.name === SANDBOX_TASK);
  for (const svc of inSandbox.filter((d) => d.obj.kind === "Service")) {
    const sel: Record<string, unknown> = svc.obj.spec?.selector ?? {};
    const name = svc.obj.metadata?.name;
    if (name === SANDBOX_TASK && JSON.stringify(sel) !== JSON.stringify(SANDBOX_TASK_LABELS)) {
      out.push({ rule: "sandbox", where: id(svc), message: `Service selector 분리: selector가 정확히 app: ${SANDBOX_TASK}가 아니다` });
    }
    for (const t of tasks) {
      if (context(t.origin) !== context(svc.origin) || name === SANDBOX_TASK) continue;
      const labels = t.obj.spec?.template?.metadata?.labels ?? {};
      if (Object.keys(sel).length > 0 && Object.entries(sel).every(([k, v]) => labels[k] === v)) {
        out.push({ rule: "sandbox", where: id(svc), message: `Service selector 분리: 이 Service가 ${SANDBOX_TASK} 파드를 고른다` });
      }
    }
  }
  return out;
}
const SANDBOX_FIREWALL = "egress-firewall";
const SANDBOX_FIREWALL_CAPS = new Set(["NET_ADMIN"]);
// sandbox SA를 담는 그룹. 바인딩 subject로 오면 sandbox:default에 권한이 생긴다.
const SANDBOX_GROUPS = new Set([`system:serviceaccounts:${SANDBOX_NS}`, "system:serviceaccounts", "system:authenticated"]);
// platform/sandbox/templates/_helpers.tpl의 sandbox.egressFirewall. 규칙을 바꾸면 같은 PR에서 이 고정본도 바꾼다.
const SANDBOX_FIREWALL_COMMAND = ["/bin/sh", "-euc"];
const SANDBOX_FIREWALL_IMAGE = "docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70";
// iptables 잠금 파일(/run/xtables.lock) 자리. 이름은 emptyDir 볼륨이어야 한다.
const SANDBOX_FIREWALL_MOUNT = { name: "firewall-run", mountPath: "/run" };
const SANDBOX_FIREWALL_SCRIPT = [
  "for t in iptables ip6tables; do",
  '"$t" -P OUTPUT DROP',
  '"$t" -F OUTPUT',
  '"$t" -A OUTPUT -o lo -j ACCEPT',
  '"$t" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
  "done",
  'iptables -A OUTPUT -d "$PROXY_IP/32" -p tcp --dport "$PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT',
  "iptables -A OUTPUT -j REJECT",
  "ip6tables -A OUTPUT -j REJECT",
  "iptables -S OUTPUT",
  "ip6tables -S OUTPUT",
];
const scriptLines = (args: unknown): string[] =>
  (Array.isArray(args) ? args : [])
    .join("\n")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("#"));
export function checkSandbox(docs: Doc[]): Violation[] {
  docs = expand(docs);
  const out: Violation[] = [];
  const nsOf = (d: Doc) => d.obj.metadata?.namespace ?? d.ns;
  const proxies = new Map<string, { ip: string; port: number; url: string }>();
  for (const d of docs) {
    if (d.obj.kind !== "Service" || nsOf(d) !== "egress" || d.obj.metadata?.name !== "egress-proxy") continue;
    const ip = d.obj.spec?.clusterIP;
    const port = (d.obj.spec?.ports ?? [])[0]?.port;
    // 고정 IPv4 clusterIP·숫자 포트여야 init 규칙에 쓸 수 있다(None·빈 값이면 Service가 없는 것과 같다).
    if (typeof ip === "string" && /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) && Number.isInteger(port)) proxies.set(context(d.origin), { ip, port, url: `http://${ip}:${port}` });
  }
  out.push(...checkSandboxLaneSplit(docs, nsOf));
  let taskSeen = false;
  for (const d of docs) {
    const k = d.obj.kind;
    if (d.obj.metadata?.name === SANDBOX_TASK_PVC && (k === "PersistentVolume" || (k === "PersistentVolumeClaim" && nsOf(d) === SANDBOX_NS))) out.push(...checkSandboxTaskVolume(d));
    if (WORKLOAD_KINDS.has(k)) {
      const isTask = k === "Deployment" && nsOf(d) === SANDBOX_NS && d.obj.metadata?.name === SANDBOX_TASK;
      const taskSpec = podSpec(d.obj) ?? {};
      out.push(...checkSandboxTaskScope(d, isTask, taskSpec, nsOf(d) === SANDBOX_NS));
      if (isTask) {
        taskSeen = true;
        out.push(...checkSandboxTaskShape(d, taskSpec));
      }
    }
    if (k === "RoleBinding" || k === "ClusterRoleBinding") {
      const bound = (d.obj.subjects ?? []).some(
        (s: any) =>
          (s?.kind === "ServiceAccount" && s.namespace === SANDBOX_NS) ||
          (s?.kind === "User" && String(s.name).startsWith(`system:serviceaccount:${SANDBOX_NS}:`)) ||
          (s?.kind === "Group" && SANDBOX_GROUPS.has(s.name)),
      );
      if ((k === "RoleBinding" && nsOf(d) === SANDBOX_NS) || bound) {
        out.push({ rule: "sandbox", where: id(d), message: "sandbox에 RBAC 바인딩을 두지 않는다(설계 C.8)" });
      }
    }
    if (!WORKLOAD_KINDS.has(k) || nsOf(d) !== SANDBOX_NS) continue;
    const spec = podSpec(d.obj) ?? {};
    const where = id(d);
    if (spec.automountServiceAccountToken !== false) out.push({ rule: "sandbox", where, message: "automountServiceAccountToken: false가 아니다" });
    if (spec.serviceAccountName && spec.serviceAccountName !== "default") out.push({ rule: "sandbox", where, message: `serviceAccountName ${spec.serviceAccountName}을 쓰지 않는다` });
    for (const f of ["hostNetwork", "hostPID", "hostIPC"]) if (spec[f] === true) out.push({ rule: "sandbox", where, message: `${f}를 쓰지 않는다` });
    for (const v of spec.volumes ?? []) {
      if (v?.hostPath) out.push({ rule: "sandbox", where, message: `hostPath 볼륨 ${v.name}을 쓰지 않는다` });
      if ((v?.projected?.sources ?? []).some((s: any) => s?.serviceAccountToken)) out.push({ rule: "sandbox", where, message: `projected 볼륨 ${v.name}에 serviceAccountToken을 넣지 않는다` });
    }
    const inits: any[] = spec.initContainers ?? [];
    if (inits[0]?.name !== SANDBOX_FIREWALL || inits.filter((c) => c?.name === SANDBOX_FIREWALL).length !== 1) {
      out.push({ rule: "sandbox", where, message: `첫 init 컨테이너가 ${SANDBOX_FIREWALL} 하나여야 한다(출력 차단 규칙)` });
    }
    const proxy = proxies.get(context(d.origin));
    if (!proxy) out.push({ rule: "sandbox", where, message: "같은 렌더 맥락에 egress/egress-proxy Service(IPv4 clusterIP·포트)가 없다" });
    const check = (c: any, init: boolean) => {
      const cw = `${where} container ${c.name}`;
      const sc = c.securityContext ?? {};
      if (sc.privileged === true) out.push({ rule: "sandbox", where: cw, message: "privileged를 쓰지 않는다" });
      if (sc.allowPrivilegeEscalation !== false) out.push({ rule: "sandbox", where: cw, message: "allowPrivilegeEscalation: false가 아니다" });
      const drop: string[] = sc.capabilities?.drop ?? [];
      if (!drop.includes("ALL")) out.push({ rule: "sandbox", where: cw, message: "capabilities.drop에 ALL이 없다" });
      const add: string[] = sc.capabilities?.add ?? [];
      const bad = add.filter((a) => !(init && c.name === SANDBOX_FIREWALL && SANDBOX_FIREWALL_CAPS.has(a)));
      if (bad.length) out.push({ rule: "sandbox", where: cw, message: `capability ${bad.join(", ")}를 더한다(NET_ADMIN은 ${SANDBOX_FIREWALL}만)` });
      const envNames: string[] = (c.env ?? []).map((e: any) => e?.name);
      const dup = [...new Set(envNames.filter((n, i) => envNames.indexOf(n) !== i))];
      if (dup.length) out.push({ rule: "sandbox", where: cw, message: `env 이름 ${dup.join(", ")}가 둘 이상이다(kubelet은 뒤의 값을 쓴다)` });
      const envOf = (name: string) => (c.env ?? []).find((e: any) => e.name === name)?.value;
      if (init && c.name === SANDBOX_FIREWALL) {
        const same = (a: unknown[], b: unknown[]) => a.length === b.length && a.every((x, i) => x === b[i]);
        const args = Array.isArray(c.args) && c.args.length === 1 && typeof c.args[0] === "string" ? c.args : null;
        if (!same(Array.isArray(c.command) ? c.command : [], SANDBOX_FIREWALL_COMMAND) || !args || !same(scriptLines(args), SANDBOX_FIREWALL_SCRIPT)) {
          out.push({ rule: "sandbox", where: cw, message: "방화벽 명령·규칙이 고정본(tools/ci/policy.ts SANDBOX_FIREWALL_SCRIPT)과 다르다" });
        }
        const mounts: any[] = c.volumeMounts ?? [];
        const vol = (spec.volumes ?? []).find((v: any) => v?.name === SANDBOX_FIREWALL_MOUNT.name);
        const envOk = c.envFrom === undefined && [...envNames].sort().join(",") === "PROXY_IP,PROXY_PORT";
        const mountOk =
          mounts.length === 1 &&
          Object.keys(mounts[0] ?? {}).sort().join(",") === "mountPath,name" &&
          mounts[0].name === SANDBOX_FIREWALL_MOUNT.name &&
          mounts[0].mountPath === SANDBOX_FIREWALL_MOUNT.mountPath &&
          vol?.emptyDir !== undefined;
        if (c.image !== SANDBOX_FIREWALL_IMAGE || !envOk || !mountOk || c.workingDir !== undefined) {
          out.push({ rule: "sandbox", where: cw, message: "방화벽 실행 환경(이미지·env·마운트)이 고정본과 다르다" });
        }
        if (proxy && (envOf("PROXY_IP") !== proxy.ip || envOf("PROXY_PORT") !== String(proxy.port))) {
          out.push({ rule: "sandbox", where: cw, message: `PROXY_IP·PROXY_PORT ${envOf("PROXY_IP")}:${envOf("PROXY_PORT")}가 egress-proxy Service ${proxy.ip}:${proxy.port}와 다르다` });
        }
      }
      if (init || !proxy) return;
      const env = envOf("HTTPS_PROXY");
      if (env !== proxy.url) out.push({ rule: "sandbox", where: cw, message: `HTTPS_PROXY ${env}가 egress-proxy Service 주소 ${proxy.url}와 다르다` });
    };
    for (const c of inits) check(c, true);
    for (const c of spec.containers ?? []) check(c, false);
  }
  if (taskSeen) out.push(...sandboxTaskProfileFiles());
  return out;
}

export function checkAll(docs: Doc[]): Violation[] {
  return [...checkNoSecrets(docs), ...checkWorkloads(docs), ...checkRevisions(docs), ...checkReadonlyRbac(docs), ...checkIngress(docs), ...checkSandbox(docs)];
}
