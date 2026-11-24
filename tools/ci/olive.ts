// 올리브 실행 대상 검사(D-38·D-39, docs/plans/2026-11-13-olive/supervisor.md §1.1·§7.1·§7.2, AC-29).
// 비상 정지는 실행 대상 목록 하나(platform/olive/targets.yaml)를 믿는다. 차트가 만드는 Deployment, Argo CD 예외(ignoreDifferences),
// CLI가 내리고 올리는 대상이 이 목록과 어긋나면 정지가 덮지 못하는 파드가 생긴다. 규칙 이름은 OLIVE_RULES, 각 함수 머리 주석이 이유다.
// 구성 요소를 root에서 꺼 둬도 돈다. 차트의 ci/*.yaml 렌더, 지금 root와 대상 차트를 켠 root의 실제 Application 값 렌더,
// 호스트가 설치하는 매니페스트(host/k3s-manifests)를 함께 본다.
// CLI의 올리브 명령은 아직 없다. 생기면 대상을 이 파일에서 읽어야 하고, 손으로 적은 목록을 두면 이 검사가 그 목록을 보지 못한다.
import { existsSync, writeFileSync } from "node:fs";
import { basename, dirname, join, posix, relative } from "node:path";
import { type Doc, type Violation, ROOT, effectiveSources, fmt, gitFiles, parseAll, readText, sameRepo, tempDir } from "./lib";
import { WORKLOAD_KINDS, context, expand, id, podSpec } from "./policy";
import { fillEmpty, filledValuesObject, helmTemplate, listShapeErrors, listedArgoApps, parseRendered, renderAll } from "./render";

export const OLIVE_TARGETS_FILE = "platform/olive/targets.yaml";
const OLIVE_CHART = "platform/olive";
const TARGET_KEYS = ["id", "kind", "namespace", "deployment", "declaredBy", "stop", "start"];
// platform/olive가 만드는 모양(templates/_helpers.tpl olive.targets). 나머지는 다른 차트가 선언하거나 아직 선언되지 않았다.
const OLIVE_KINDS = new Set(["supervisor", "executor"]);
const TARGET_KINDS = new Set([...OLIVE_KINDS, "session", "writer"]);
// ns·Deployment 이름은 CLI 정지 어댑터(cli/src/core/olive.ts LABEL)와 같은 DNS label이다. 다르면 CLI가 그 대상을 거부한다.
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const REPLICAS_POINTER = ["/spec/replicas"];
// kind executor인 줄의 roles(대상이 맡을 수 있는 역할 목록, D-64 등록표)와 role(이 실행기에 배정한 역할 하나). 값은 ukyi-app/olive
// 계약 v1의 역할 이름(src/contract/v1/role.ts ROLES)과 같아야 한다. 실행기는 이 밖의 값을 받지 않아 감독에 붙기 전에 끝난다.
// 계약의 판이 바뀌면 함께 고친다.
const TARGET_OPTIONAL_KEYS = ["roles", "role"];
const V1_ROLES = new Set(["diagnosis", "isolated_reader", "code_author", "pr_review", "memory_curator"]);
export const OLIVE_RULES = ["olive-targets", "olive-replicas", "olive-chart-targets", "olive-owner", "olive-ignore-differences", "olive-isolation", "olive-executor-store", "olive-executor-split", "olive-executor-key"];

// 격리 검사를 다른 검사에 맡기는 실행 네임스페이스. sandbox는 작업자 보안 예외까지 아는 policy.ts checkSandbox가 본다.
// 여기 없는 대상 ns는 누가 선언하든(뒤 티켓이 다른 차트에 선언해도) 올리브 격리 검사를 받는다.
const ISOLATION_DELEGATED: Record<string, string> = { sandbox: "policy.ts checkSandbox" };

// 배포 렌더의 이름. REAL은 root의 실제 값 전체 렌더(render 단계와 같은 것), FORCED는 대상 차트의 components를 켠 root 렌더다.
const REAL = "root";
const FORCED = "root+켬";

export type Target = { id: string; kind: string; namespace: string; deployment: string; declaredBy: string; stop: unknown; start: unknown; roles?: unknown; role?: unknown };
// targets: targets.yaml의 파싱 결과 그대로. charts: declaredBy → 켠 값 파일 렌더, chartRenders: 그 렌더 호출의 출처(문서가 0개여도 남는다).
// deployed: REAL·FORCED → 전체 렌더 문서(출처는 render.ts의 `<Application>[<클러스터>]:<source path>` 등).
// host: 호스트가 설치하는 매니페스트(host/k3s-manifests). 격리 검사의 PV·StorageClass 입력이다.
export type OliveInput = { targets: any; charts: Record<string, Doc[]>; chartRenders: Record<string, string[]>; deployed: Record<string, Doc[]>; host: HostManifests };

// 빈 문자열도 생략과 같다. Argo CD는 namespaced 리소스의 빈 namespace를 Application destination으로 채운다(v3.6.1 controller/state.go).
const nsOf = (d: Doc): string | undefined => d.obj.metadata?.namespace || d.ns;
const isString = (v: unknown): v is string => typeof v === "string";

// 렌더 출처에서 그 문서를 낸 Application·클러스터·source path. cluster가 없으면 배포되지 않는 렌더(차트 시험 값, 남은 kustomization)다.
type Source = { app?: string; cluster?: string; path: string };
function sourceOf(origin: string): Source {
  let m = origin.match(/^(.+)\[([a-z0-9-]+)\]:(.+)$/);
  if (m) return { app: m[1], cluster: m[2], path: m[3] };
  m = origin.match(/^(app|data):(.+)\[([a-z0-9-]+)\]$/);
  if (m) return m[1] === "app" ? { app: m[2], cluster: m[3], path: "platform/charts/app" } : { app: `${m[2]}-data`, cluster: m[3], path: "platform/charts/app-data" };
  m = origin.match(/^chart:(.+?)\/ci\//);
  if (m) return { path: `platform/${m[1]}` };
  m = origin.match(/^kustomize:(.+)$/);
  return { path: m ? m[1] : origin };
}
const deployedDoc = (d: Doc) => sourceOf(d.origin).cluster !== undefined;
const srcName = (s: Source) => (s.app ? `${s.app}(${s.path})` : s.path);

function clusterNames(): string[] {
  return gitFiles("platform/root/values-*.yaml").map((vf) => basename(vf).replace(/^values-/, "").replace(/\.yaml$/, ""));
}

// 자리(ns·Deployment·declaredBy)를 읽을 수 있는 줄. 모양 위반은 checkTargetShape가 따로 낸다. 여기서 빼면 그 줄의 Deployment가
// "목록 밖"으로 한 번 더 걸려 원인이 둘로 보인다.
export function targetList(raw: any): Target[] {
  const list: unknown[] = Array.isArray(raw?.targets) ? raw.targets : [];
  return list.filter((t: any): t is Target => !!t && typeof t === "object" && isString(t.namespace) && isString(t.deployment) && isString(t.declaredBy));
}

// 목록의 모양. 줄은 정의상 실행 Deployment(supervisor.md §1.1 "0개"인 다섯)라 start와 상관없이 stop: true다.
// 지금 켤 수 없는 대상도 다른 경로로 떠 있을 수 있어 정지·소멸 확인이 덮어야 한다.
function checkTargetShape(raw: any): Violation[] {
  const out: Violation[] = [];
  const bad = (where: string, message: string) => out.push({ rule: "olive-targets", where: `${OLIVE_TARGETS_FILE} ${where}`.trim(), message });
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || !Array.isArray(raw.targets) || raw.targets.length === 0) {
    bad("", "targets 목록이 없다");
    return out;
  }
  const extraTop = Object.keys(raw).filter((k) => k !== "targets");
  if (extraTop.length) bad("", `targets 밖의 칸: ${extraTop.join(", ")}`);
  raw.targets.forEach((t: any, i: number) => {
    const w = `targets[${i}]${isString(t?.id) ? `(${t.id})` : ""}`;
    if (!t || typeof t !== "object" || Array.isArray(t)) return bad(w, "대상은 맵이다");
    const keys = Object.keys(t);
    const missing = TARGET_KEYS.filter((k) => !keys.includes(k));
    const extra = keys.filter((k) => !TARGET_KEYS.includes(k) && !TARGET_OPTIONAL_KEYS.includes(k));
    if (missing.length) bad(w, `칸이 없다: ${missing.join(", ")}`);
    if (extra.length) bad(w, `모르는 칸: ${extra.join(", ")}`);
    for (const k of ["id", "namespace", "deployment"]) {
      if (k in t && !(isString(t[k]) && t[k].length <= 63 && LABEL.test(t[k]))) bad(w, `${k}는 DNS label이다: ${JSON.stringify(t[k])}`);
    }
    if ("kind" in t && !TARGET_KINDS.has(t.kind)) bad(w, `kind는 ${[...TARGET_KINDS].join("·")} 중 하나다: ${JSON.stringify(t.kind)}`);
    if ("declaredBy" in t) {
      const d = t.declaredBy;
      const ok = d === "" || (isString(d) && /^platform\/[a-z0-9-]+$/.test(d) && existsSync(join(ROOT, d, "Chart.yaml")));
      if (!ok) bad(w, `declaredBy는 빈 값이거나 이 저장소의 차트(platform/<이름>)다: ${JSON.stringify(d)}`);
      else if (TARGET_KINDS.has(t.kind) && OLIVE_KINDS.has(t.kind) !== (d === OLIVE_CHART)) bad(w, `kind ${t.kind}와 declaredBy ${JSON.stringify(d)}가 맞지 않는다(${OLIVE_CHART}는 ${[...OLIVE_KINDS].join("·")}만 만든다)`);
    }
    for (const k of ["stop", "start"]) if (k in t && typeof t[k] !== "boolean") bad(w, `${k}는 true·false다: ${JSON.stringify(t[k])}`);
    if (t.stop === false) bad(w, `stop이 true가 아니다(start: ${JSON.stringify(t.start)}). 실행 대상은 켤 수 있는지와 상관없이 비상 정지·소멸 확인이 덮는다`);
    if (t.start === true && t.declaredBy === "") bad(w, "declaredBy가 빈 대상은 start: true일 수 없다(선언되지 않은 Deployment를 켜지 않는다)");
    // roles는 길이를 막지 않는다(한 대상에 여러 역할, D-64). 실행기 하나와 그 서명 키에는 역할 하나라 배정은 role 하나다.
    // roles가 틀리면 role이 그 안인지는 보지 않는다(원인 하나에 위반 하나).
    // 다른 kind는 역할을 이 칸으로 받지 않는다(세션·작성의 역할은 그 티켓이 정한다).
    if (t.kind === "executor") {
      const r = t.roles;
      const rolesOk = Array.isArray(r) && r.length > 0 && r.every((x) => isString(x) && V1_ROLES.has(x)) && new Set(r).size === r.length;
      if (!rolesOk) bad(w, `roles는 계약 v1 역할 이름(${[...V1_ROLES].join("·")})이 겹치지 않는 목록이다(이 대상이 맡을 수 있는 역할, D-64): ${JSON.stringify(r)}`);
      if (!(isString(t.role) && V1_ROLES.has(t.role) && (!rolesOk || r.includes(t.role)))) {
        bad(w, `role은 roles 안의 계약 v1 역할 이름 하나다(이 실행기에 배정한 역할. 차트가 OLIVE_ROLE과 역할 이미지를 이 값으로 고른다, D-64): role ${JSON.stringify(t.role)}, roles ${JSON.stringify(r)}`);
      }
    } else for (const k of ["roles는", "role은"]) if (k.slice(0, -1) in t) bad(w, `${k} kind executor인 줄에만 둔다(kind ${JSON.stringify(t.kind)})`);
  });
  const list = targetList(raw);
  const dup = (keyOf: (t: any) => string, what: string) => {
    const seen = new Set<string>();
    for (const t of raw.targets) {
      if (!t || typeof t !== "object") continue;
      const k = keyOf(t);
      if (seen.has(k)) bad("", `${what}이 둘 이상이다: ${k}`);
      seen.add(k);
    }
  };
  dup((t) => String(t.id), "id");
  dup((t) => `${t.namespace}/${t.deployment}`, "대상 Deployment");
  // 자원 한도(olive-limits)와 정지 자물쇠가 ns마다 하나다. platform/olive의 두 대상이 한 ns를 쓰면 한도가 둘로 렌더된다.
  const oliveNs = list.filter((t) => t.declaredBy === OLIVE_CHART).map((t) => t.namespace);
  for (const ns of new Set(oliveNs)) if (oliveNs.filter((x) => x === ns).length > 1) bad("", `${OLIVE_CHART} 대상의 namespace ${ns}가 둘 이상이다`);
  const sup = raw.targets.filter((t: any) => t?.kind === "supervisor").length;
  if (sup !== 1) bad("", `supervisor 대상은 하나다(지금 ${sup})`);
  return out;
}

function replicasViolations(d: Doc, t: Target): Violation[] {
  const spec = d.obj.spec ?? {};
  if (!Object.hasOwn(spec, "replicas")) return [{ rule: "olive-replicas", where: id(d), message: `대상 ${t.id}의 spec.replicas 칸이 없다(없으면 1로 뜬다). Git 값은 0이다(D-38)` }];
  if (spec.replicas !== 0) return [{ rule: "olive-replicas", where: id(d), message: `대상 ${t.id}의 spec.replicas가 0이 아니다(${JSON.stringify(spec.replicas)}). Git 값은 0이고 켜고 끄기는 관리자 CLI다(D-38)` }];
  return [];
}

// 대상 Deployment 자신에 두면 Argo CD v3.6.1이 그 리소스의 diff·동기 상태를 바꾸는 주석. 예외를 둘 자리는 소유 Application의
// ignoreDifferences 하나다(checkIgnoreDifferences가 모양을 본다). 값과 상관없이 키가 있으면 거절한다.
//   ignore-differences: Application 예외에 더해 diff에서 뺀다(util/argo/diff/ignore.go ExtractIgnoreDifferencesFromAnnotations, diff.go StateDiffs).
//   compare-options: 리소스 비교 옵션(IgnoreExtraneous, controller/state.go).
//   hook 둘: hook 리소스는 동기 상태에 들지 않아 selfHeal이 replicas를 고치지 않는다(gitops-engine/pkg/sync/hook/hook.go IsHook, controller/state.go).
export const ARGO_RESOURCE_ANNOTATIONS = ["argocd.argoproj.io/ignore-differences", "argocd.argoproj.io/compare-options", "argocd.argoproj.io/hook", "helm.sh/hook"];
function annotationViolations(d: Doc, t: Target): Violation[] {
  const ann = d.obj.metadata?.annotations ?? {};
  return ARGO_RESOURCE_ANNOTATIONS.filter((k) => Object.hasOwn(ann, k)).map((k) => ({
    rule: "olive-ignore-differences",
    where: id(d),
    message: `대상 ${t.id}의 Deployment에 Argo CD 주석 ${k}를 두지 않는다. 예외는 소유 Application의 ignoreDifferences에만 둔다`,
  }));
}

// 작업자 실행기의 상태 저장소와 감독 신원(D-75, D-100, platform/olive/templates/executor-pvc.yaml·executor-deployments.yaml).
// platform/olive를 렌더한 곳(ci/*.yaml 렌더, 켠 root의 olive Application)마다 이 차트의 실행기 대상을 본다.
//   - 실행기 ns의 PVC가 정확히 하나이고 local-retain이며 wave가 Deployment와 같고 Prune=false·Delete=false다. 둘이면 어느 것이
//     저장소인지 렌더로 가를 수 없고, wave가 앞서면 첫 배포가 Pending PVC에서 멈추며, 보존 옵션이 없으면 저장소가 지워져 재등록이 필요하다.
//   - 그 PVC를 가리키는 볼륨이 하나이고 실행기 컨테이너(이름으로 고른다)에만 붙는다. 다른 uid의 역할 컨테이너(D-100)에 붙으면
//     모델이 저장소 ID·nonce·영수증을 고칠 수 있다. 컨테이너 순서는 보지 않는다.
//   - OLIVE_STORE_DIR가 그 마운트 경로 아래이고, OLIVE_SUPERVISOR_URI가 같은 렌더의 감독 Certificate URI SAN과 같다.
//     Certificate가 없는 렌더(pki 꺼짐)는 olive.pki.uri의 꼴(spiffe://olive.internal/ns/<감독 ns>/supervisor)과 견준다.
const EXECUTOR_CONTAINER = "executor";
const STORE_CLASS = "local-retain";

// platform/olive를 렌더한 곳(출처)마다의 문서. 켠 root 렌더에는 차트 ci 렌더도 들어 있어, 같은 출처가 두 번 세지지 않게 거기서는
// 배포되는 Application의 문서만 고른다.
function oliveChartGroups(charts: Record<string, Doc[]>, deployed: Record<string, Doc[]>): Map<string, Doc[]> {
  const groups = new Map<string, Doc[]>();
  const docs = [...expand(charts[OLIVE_CHART] ?? []), ...expand(deployed[FORCED] ?? []).filter((d) => deployedDoc(d) && sourceOf(d.origin).path === OLIVE_CHART)];
  for (const d of docs) groups.set(d.origin, [...(groups.get(d.origin) ?? []), d]);
  return groups;
}
function checkExecutorStore(targets: Target[], charts: Record<string, Doc[]>, deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-executor-store", where, message });
  const sup = targets.find((t) => t.kind === "supervisor" && t.declaredBy === OLIVE_CHART);
  const executors = targets.filter((t) => t.kind === "executor" && t.declaredBy === OLIVE_CHART);
  // 감독 줄이 없으면 checkTargetShape가 낸다.
  if (!sup) return out;
  const wave = (d: Doc) => String(d.obj.metadata?.annotations?.["argocd.argoproj.io/sync-wave"] ?? "0");
  for (const [origin, group] of oliveChartGroups(charts, deployed)) {
    const certs = group.filter((d) => d.obj.kind === "Certificate" && nsOf(d) === sup.namespace);
    let wantUri: string | undefined = `spiffe://olive.internal/ns/${sup.namespace}/supervisor`;
    if (certs.length > 0) {
      const uris = certs.map((d) => d.obj.spec?.uris);
      wantUri = certs.length === 1 && Array.isArray(uris[0]) && uris[0].length === 1 && isString(uris[0][0]) ? uris[0][0] : undefined;
      if (wantUri === undefined) push(origin, `감독 ns ${sup.namespace}의 Certificate URI SAN이 하나가 아니다(${JSON.stringify(uris)}). 실행기 env와 견줄 수 없다`);
    }
    for (const t of executors) {
      const dep = group.find((d) => d.obj.kind === "Deployment" && nsOf(d) === t.namespace && d.obj.metadata?.name === t.deployment);
      // 대상 Deployment가 없으면 olive-chart-targets가 낸다.
      if (!dep) continue;
      const where = id(dep);
      const pvcs = group.filter((d) => d.obj.kind === "PersistentVolumeClaim" && nsOf(d) === t.namespace);
      if (pvcs.length !== 1) {
        push(where, `대상 ${t.id}의 네임스페이스 ${t.namespace}에 PVC가 정확히 하나가 아니다(${pvcs.length}개). 실행기 상태 저장소는 인스턴스마다 하나다(D-75)`);
        continue;
      }
      const pvc = pvcs[0];
      const pvcName = pvc.obj.metadata?.name;
      if (pvc.obj.spec?.storageClassName !== STORE_CLASS) push(id(pvc), `실행기 저장소 PVC의 storageClassName이 ${STORE_CLASS}가 아니다(${JSON.stringify(pvc.obj.spec?.storageClassName)})`);
      if (wave(pvc) !== wave(dep)) push(id(pvc), `실행기 저장소 PVC의 sync-wave ${wave(pvc)}가 Deployment의 ${wave(dep)}와 다르다(WaitForFirstConsumer라 앞 wave면 동기가 멈춘다)`);
      const opts = String(pvc.obj.metadata?.annotations?.["argocd.argoproj.io/sync-options"] ?? "").split(",").map((s) => s.trim());
      if (!opts.includes("Prune=false") || !opts.includes("Delete=false")) push(id(pvc), "실행기 저장소 PVC에 sync-options Prune=false,Delete=false가 없다(지워지면 재등록 전 배정이 0이다)");
      const spec = podSpec(dep.obj) ?? {};
      const vols = (spec.volumes ?? []).filter((v: any) => v?.persistentVolumeClaim?.claimName === pvcName);
      if (vols.length !== 1) {
        push(where, `대상 ${t.id}의 파드에 PVC ${pvcName}를 가리키는 볼륨이 정확히 하나가 아니다(${vols.length}개)`);
        continue;
      }
      const vol = vols[0].name;
      const mine = (spec.containers ?? []).filter((c: any) => c?.name === EXECUTOR_CONTAINER);
      if (mine.length !== 1) {
        push(where, `대상 ${t.id}의 파드에 실행기 컨테이너 ${EXECUTOR_CONTAINER}가 정확히 하나가 아니다(${mine.length}개)`);
        continue;
      }
      const c = mine[0];
      for (const other of [...(spec.initContainers ?? []), ...(spec.containers ?? []), ...(spec.ephemeralContainers ?? [])]) {
        if (other !== c && (other?.volumeMounts ?? []).some((m: any) => m?.name === vol)) push(`${where} container ${other?.name}`, `저장소 볼륨(${vol})을 실행기 컨테이너 ${EXECUTOR_CONTAINER} 밖에 붙이지 않는다(역할 컨테이너가 저장소 ID·nonce·영수증을 고칠 수 있다, D-100)`);
      }
      const cw = `${where} container ${EXECUTOR_CONTAINER}`;
      const mounts = (c.volumeMounts ?? []).filter((m: any) => m?.name === vol);
      if (mounts.length !== 1 || mounts[0].readOnly === true || mounts[0].subPath !== undefined || !isString(mounts[0].mountPath)) {
        push(cw, `저장소 볼륨(${vol})을 쓰기 가능하게 한 번(subPath 없이) 붙이지 않았다`);
        continue;
      }
      const mp = String(mounts[0].mountPath).replace(/\/+$/, "");
      const env = (name: string) => (c.env ?? []).filter((e: any) => e?.name === name);
      const dir = env("OLIVE_STORE_DIR");
      const dirValue = dir.length === 1 ? dir[0].value : undefined;
      if (!isString(dirValue) || !(dirValue === mp || dirValue.startsWith(`${mp}/`))) push(cw, `OLIVE_STORE_DIR(${JSON.stringify(dir.map((e: any) => e.value))})가 저장소 마운트 경로 ${mp} 아래 하나가 아니다`);
      const uri = env("OLIVE_SUPERVISOR_URI");
      if (wantUri !== undefined && (uri.length !== 1 || uri[0].value !== wantUri)) push(cw, `OLIVE_SUPERVISOR_URI(${JSON.stringify(uri.map((e: any) => e.value))})가 감독 인증서의 URI SAN ${wantUri}와 다르다`);
    }
  }
  return out;
}

// 작업자 실행기 파드의 제어·역할 분할(D-100·D-102·D-103·D-107, platform/olive/templates/executor-deployments.yaml 머리 주석).
// 역할 컨테이너에서는 모델과 도구가 돈다. 경계를 어기면 모델이 TLS 개인 키나 저장소에 닿거나, 제어 프로세스를 들여다보거나,
// 대리를 바꿔칠 수 있다. 상대 비교(두 uid가 다르다, 두 경로가 같다)는 둘이 함께 틀리면 통과하므로 아래 경계 표의 절대 값과 렌더를
// 그대로 대조한다. 템플릿 값을 바꾸는 PR은 이 표를 함께 고친다. platform/olive를 렌더한 곳(ci/*.yaml 렌더, 켠 root의 olive
// Application)마다 이 차트의 대상을 본다. 위반 하나는 메시지 하나로 낸다(fixture가 원인을 하나씩 확인한다).
//
// 경계 표(실행기 줄마다 같은 모양. 값은 아래 SPLIT_* 상수):
//   파드: 일반 컨테이너 executor·role, init olive-init 하나, 임시 컨테이너 없음(어긋나면 나머지는 보지 않는다).
//     securityContext는 SPLIT_POD_SECURITY 그대로(runAsNonRoot, 65532:65532, seccomp RuntimeDefault). fsGroup·supplementalGroups가
//     없다(둘 다 모든 컨테이너에 보조 그룹으로 붙어 역할이 제어의 그룹이 된다). shareProcessNamespace가 없다(D-102. 있으면
//     /proc/<pid>/root로 제어의 파일에 닿는다).
//   컨테이너(SPLIT_CONTAINERS): 실효 uid·gid(컨테이너 값, 없으면 파드 값), 나머지 securityContext(SPLIT_CONTAINER_SECURITY, restricted),
//     command(args·restartPolicy 없음), 마운트 집합(이름, 고정 경로, readOnly. subPath·subPathExpr 등 다른 칸 없음), env.
//       olive-init  65532:65532  ["bun", "src/main/agent-install.ts"]  agent-bin /opt/olive-agent 쓰기 하나. env 없음
//       executor    65532:65532  ["bun", "src/main/executor.ts"]       tmp /tmp, agent-link /run/olive/agent, store(값 경로) 쓰기.
//                                                                     effect-signing /run/olive/effect-signing 읽기 전용.
//                                                                     tls(값 경로)·trust /run/olive/trust는 있으면 읽기 전용.
//                                                                     env는 아래 다섯만 본다(나머지 이름은 olive-executor-store 등):
//                                                                       OLIVE_ROLE = targets.yaml role, OLIVE_AGENT_SOCKET,
//                                                                       OLIVE_INSTANCE = 대상 id(templates/_helpers.tpl olive.instance),
//                                                                       OLIVE_POLICY_REVISION = 계약 v1 revision 꼴이고 같은 렌더의 감독 값과 같다(D-108),
//                                                                       OLIVE_SIGNING_KEY_FILE = /run/olive/effect-signing/EFFECT_SIGNING_KEY
//       role        10002:10002  ["/opt/olive-agent/olive-agent"]     agent-bin /opt/olive-agent, agent-link /run/olive/agent 읽기 전용,
//                                (대리가 PID 1, D-102)                 role-tmp /tmp 쓰기. env는 정확히 OLIVE_AGENT_SOCKET과 빈 BUN_OPTIONS·
//                                                                     BUN_BE_BUN·LD_PRELOAD(대리 안의 Bun·로더가 이미지 ENV를 대리 코드보다
//                                                                     먼저 읽는다. 이미지 ENV 자체는 렌더로 볼 수 없다, values.yaml roleImages)
//     /opt/olive-agent와 대리 파일 이름은 올리브 설치기(src/main/agent-install.ts)의 고정 경로다. 마운트만 옮기면 설치한 대리가 없다.
//     소켓은 /run/olive/agent/agent.sock 하나다. 두 컨테이너가 같은 폴더 전체를 붙이고 그 바로 아래 같은 파일 이름이어야 같은 파일이다.
//   볼륨(SPLIT_VOLUMES): agent-bin 디스크 256Mi, agent-link 메모리 1Mi, role-tmp 디스크 512Mi, tmp 디스크 64Mi, store PVC
//     (olive-executor-store가 본다), effect-signing Secret olive-effect-signing-key의 키 EFFECT_SIGNING_KEY 하나(복구 스위치와
//     상관없이 늘 있다. 끄면 Secret을 손으로 만든다). tls Secret·trust ConfigMap(있으면)과 effect-signing은 파일마다 유효 모드 0444
//     (fsGroup 없이 65532가 읽는다).
//   비밀: secret·PVC·projected 볼륨은 executor에만 붙는다. executor 밖 컨테이너에 envFrom·env valueFrom이 없다(볼륨 없이도 Secret이 들어간다).
//   겹침: 한 컨테이너 안의 마운트 경로는 같거나 포개지지 않는다(값이 정하는 tls·store 경로 포함. 같으면 PodTemplate이 무효이고 포개면
//     한쪽 파일이 가려진다).
//   role: 프로브·lifecycle·ports가 없다(D-74, kubelet이 그 안에서 명령을 돌리지 않게).
//   이미지: olive-init = executor = ghcr.io/ukyi-app/olive@sha256(대리와 실행기의 링크 계약이 같은 커밋이다). role은 대상 role의
//     역할 이미지다. 시험 값(RENDER_FILL = ci/enabled.yaml)이 역할마다 다른 가짜 참조라 대상↔이미지 대응이 렌더에 보인다.
//     함정: 켜는 PR이 실제 역할 이미지를 넣으면 켠 root 렌더가 그 값이 되어 이 대조(roleImageWanted)가 실패한다. 그 PR이 기대 값을 고친다.
//   한도: 같은 ns의 ResourceQuota olive-limits가 파드의 실효 limits(max(일반 컨테이너 합, 가장 큰 init))와 같다. 작으면 파드가
//     거부되고, 크면 두 번째 파드가 들어갈 자리가 생긴다(templates/resourcequota.yaml). 상시 실행 init(restartPolicy Always)은 이 식에
//     맞지 않아 위 컨테이너 표가 거절한다. 파드 단위 spec.resources도 두지 않는다. 있으면 쿠버네티스가 컨테이너 합 대신 그 값을
//     파드의 limits로 써서 이 식이 실제와 달라진다.
//   작업 폴더: olive-init·executor의 command는 이미지 작업 폴더(IMAGE_WORKDIR) 기준 상대 경로라 workingDir는 생략하거나 그 폴더다.
//   하나: 렌더마다 대상(감독 포함) Deployment와 olive-limits가 각각 정확히 하나다. 둘이면 CI는 첫 문서를, Argo CD는 마지막 문서를
//     고른다. olive-limits가 없으면 그 네임스페이스의 총량 상한이 사라진다.
//   감독: 실행기에서 뺀 fsGroup 65532가 감독 파드에는 있다. 감독은 0440 Secret(서명 키·계정·TLS)을 그 그룹으로 읽는다.
//     감독 컨테이너의 OLIVE_POLICY_REVISION도 계약 v1 revision 꼴이어야 한다(실행기 값과 견주는 기준).
//     함정: 현관(apps/homelab-bot)의 정책 값 자리는 아직 없어 여기서 견주지 않는다. 현관 차트 PR이 그 대조를 더한다.
const ROLE_CONTAINER = "role";
const SUPERVISOR_CONTAINER = "supervisor";
// 효과 서명 키(D-73·D-100, templates/_helpers.tpl olive.effectKey.*). 템플릿 값을 바꾸면 여기도 함께 고친다.
const EFFECT_KEY = "EFFECT_SIGNING_KEY";
const EFFECT_KEY_SECRET = "olive-effect-signing-key";
const EFFECT_KEY_DIR = "/run/olive/effect-signing";
const EFFECT_KEY_FILE = `${EFFECT_KEY_DIR}/${EFFECT_KEY}`;
const effectKeyStore = (t: Target) => `infisical-olive-executor-${t.id}`;
const effectKeyPath = (t: Target) => `/olive/executors/${t.id}`;
// 계약 v1 revision 꼴(ukyi-app/olive src/executor/runtime.ts REVISION). 감독·실행기 진입점은 이 꼴이 아니면 81로 끝난다.
const POLICY_REVISION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const INIT_CONTAINER = "olive-init";
const AGENT_DIR = "/opt/olive-agent";
const AGENT_LINK_DIR = "/run/olive/agent";
const AGENT_SOCKET = `${AGENT_LINK_DIR}/agent.sock`;
// 올리브 이미지의 작업 폴더(ukyi-app/olive Dockerfile의 WORKDIR). 다른 폴더면 bun이 상대 경로 진입점을 찾지 못한다.
const IMAGE_WORKDIR = "/app";
const SECRET_VOLUME_TYPES = ["secret", "persistentVolumeClaim", "projected"];
const OLIVE_IMAGE = /^ghcr\.io\/ukyi-app\/olive@sha256:[0-9a-f]{64}$/;
const SECRET_FILE_MODE = 0o444;
const SUPERVISOR_FS_GROUP = 65532;
const SPLIT_POD_SECURITY: Record<string, unknown> = { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: "RuntimeDefault" } };
const SPLIT_CONTAINER_SECURITY: Record<string, unknown> = { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } };
// path가 없으면 값 파일이 정하는 경로다(겹침만 본다). optional은 값에 따라 생기는 마운트다(pki, 직접 준 TLS Secret).
type MountRule = { path?: string; readOnly: boolean; optional?: boolean };
type ContainerRule = { uid: number; gid: number; command: string[]; what: string; mounts: Record<string, MountRule>; env?: Record<string, string> };
const SPLIT_CONTAINERS: Record<string, ContainerRule> = {
  [INIT_CONTAINER]: { uid: 65532, gid: 65532, command: ["bun", "src/main/agent-install.ts"], what: "대리 설치기", mounts: { "agent-bin": { path: AGENT_DIR, readOnly: false } }, env: {} },
  [EXECUTOR_CONTAINER]: {
    uid: 65532,
    gid: 65532,
    command: ["bun", "src/main/executor.ts"],
    what: "실행기 진입점",
    mounts: {
      tmp: { path: "/tmp", readOnly: false },
      "agent-link": { path: AGENT_LINK_DIR, readOnly: false },
      store: { readOnly: false },
      "effect-signing": { path: EFFECT_KEY_DIR, readOnly: true },
      tls: { readOnly: true, optional: true },
      trust: { path: "/run/olive/trust", readOnly: true, optional: true },
    },
  },
  [ROLE_CONTAINER]: {
    uid: 10002,
    gid: 10002,
    command: [`${AGENT_DIR}/olive-agent`],
    what: "agent-bin 안의 대리",
    mounts: { "agent-bin": { path: AGENT_DIR, readOnly: true }, "agent-link": { path: AGENT_LINK_DIR, readOnly: true }, "role-tmp": { path: "/tmp", readOnly: false } },
    env: { OLIVE_AGENT_SOCKET: AGENT_SOCKET, BUN_OPTIONS: "", BUN_BE_BUN: "", LD_PRELOAD: "" },
  },
};
// emptyDir는 칸까지 그대로 본다. secret은 defaultMode 밖의 칸(secretName·items)을 그대로 본다. mode는 파일마다 유효 모드 0444를 본다.
type VolumeRule = { type: string; emptyDir?: Record<string, string>; secret?: Record<string, unknown>; what?: string; why?: string; optional?: boolean; mode?: boolean };
const SPLIT_VOLUMES: Record<string, VolumeRule> = {
  "agent-bin": { type: "emptyDir", emptyDir: { sizeLimit: "256Mi" }, what: "디스크 emptyDir(sizeLimit 256Mi)", why: "메모리 매체면 대리(약 104MiB)가 메모리 상한에 든다" },
  "agent-link": { type: "emptyDir", emptyDir: { medium: "Memory", sizeLimit: "1Mi" }, what: "메모리 emptyDir(sizeLimit 1Mi)", why: "소켓 파일 하나만 두는 자리다" },
  "role-tmp": { type: "emptyDir", emptyDir: { sizeLimit: "512Mi" }, what: "디스크 emptyDir(sizeLimit 512Mi)", why: "역할 전용 /tmp의 상한이다(넘으면 kubelet이 파드를 쫓아낸다)" },
  tmp: { type: "emptyDir", emptyDir: { sizeLimit: "64Mi" }, what: "디스크 emptyDir(sizeLimit 64Mi)", why: "제어 전용 /tmp의 상한이다" },
  store: { type: "persistentVolumeClaim" },
  "effect-signing": {
    type: "secret",
    secret: { secretName: EFFECT_KEY_SECRET, items: [{ key: EFFECT_KEY, path: EFFECT_KEY }] },
    what: `Secret ${EFFECT_KEY_SECRET}의 키 ${EFFECT_KEY} 하나`,
    why: "OLIVE_SIGNING_KEY_FILE이 그 파일을 가리키고, 다른 Secret이면 실행기가 다른 키로 서명하거나 기동하지 못한다",
    mode: true,
  },
  tls: { type: "secret", optional: true, mode: true },
  trust: { type: "configMap", optional: true, mode: true },
};
const show = (v: unknown) => (v === undefined ? "없음" : JSON.stringify(v));
const sortKeys = (v: any): any => (Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v);
const same = (a: unknown, b: unknown) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
const keysOf = (a: any, b: Record<string, unknown>) => [...new Set([...Object.keys(a ?? {}), ...Object.keys(b)])];
// 쿠버네티스 Secret·ConfigMap 볼륨의 파일별 유효 모드: items[].mode, 없으면 defaultMode, 없으면 0644.
// 함정: 렌더 원문의 0444는 쿠버네티스(YAML 1.1)가 8진으로, Bun.YAML(1.2)이 십진 444로 읽는다. 차트는 두 해석이 같은 십진 292로 적고,
// 이 검사는 Bun이 읽은 수를 그대로 0o444와 견준다. 0444로 적힌 렌더는 444로 읽혀 실패한다(실제와 다른 값을 통과시키지 않는다).
const fileModes = (src: any): [string, unknown][] => {
  const def = src?.defaultMode ?? 0o644;
  return Array.isArray(src?.items) && src.items.length > 0 ? src.items.map((it: any) => [String(it?.path), it?.mode ?? def]) : [["(모든 키)", def]];
};
const modeText = (m: unknown) => (typeof m === "number" && Number.isInteger(m) ? `0${m.toString(8)}(십진 ${m})` : show(m));
const normPath = (p: string) => {
  const n = posix.normalize(p);
  return n.length > 1 ? n.replace(/\/+$/, "") : n;
};
const under = (a: string, b: string) => a === b || a.startsWith(b === "/" ? "/" : `${b}/`);
// 켠 root 렌더와 차트 시험 렌더가 쓰는 역할 이미지(RENDER_FILL). 위 표 "이미지"의 함정을 본다.
const roleImageWanted = (role: unknown): string | undefined => {
  const fill = RENDER_FILL[OLIVE_CHART];
  const repo = fill[`roleImages.${String(role)}.repository`];
  const digest = fill[`roleImages.${String(role)}.digest`];
  return isString(role) && repo && digest ? `${repo}@${digest}` : undefined;
};
// 수량을 밀리코어·바이트로. 모르는 꼴은 NaN이라 비교가 실패로 드러난다.
const cpuMilli = (q: unknown): number => {
  const m = String(q ?? "").match(/^([0-9]+(?:\.[0-9]+)?)(m?)$/);
  return m ? (m[2] ? Number(m[1]) : Number(m[1]) * 1000) : NaN;
};
const memBytes = (q: unknown): number => {
  const m = String(q ?? "").match(/^([0-9]+)(Ki|Mi|Gi|Ti|k|M|G|T)?$/);
  const unit: Record<string, number> = { "": 1, Ki: 1024, Mi: 1024 ** 2, Gi: 1024 ** 3, Ti: 1024 ** 4, k: 1e3, M: 1e6, G: 1e9, T: 1e12 };
  return m ? Number(m[1]) * unit[m[2] ?? ""] : NaN;
};
// 이름이 같은 env 항목들과, 그것이 값 항목 하나일 때의 값.
const envOf = (c: any, name: string): any[] => (c?.env ?? []).filter((x: any) => x?.name === name);
const plainOne = (list: any[]): string | undefined => (list.length === 1 && list[0].valueFrom === undefined && isString(list[0].value) ? list[0].value : undefined);
const envValues = (list: any[]) => JSON.stringify(list.map((x: any) => x.value));
const policyShapeMessage = (list: any[], who: string) =>
  `OLIVE_POLICY_REVISION(${envValues(list)})이 계약 v1 revision 꼴(${POLICY_REVISION.source})의 값 하나가 아니다(${who}. 비거나 꼴이 틀리면 진입점이 81로 끝난다, values.yaml policy.revision)`;
function checkExecutorSplit(targets: Target[], charts: Record<string, Doc[]>, deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-executor-split", where, message });
  const mine = targets.filter((t) => t.declaredBy === OLIVE_CHART && OLIVE_KINDS.has(t.kind));
  for (const [origin, group] of oliveChartGroups(charts, deployed)) {
    // 실행기 값과 견줄 감독의 정책 판 번호. 감독 쪽이 틀리면 그 위반 하나만 내고 실행기는 꼴만 본다(원인 하나에 위반 하나).
    let supRevision: string | undefined;
    const supT = mine.find((t) => t.kind === "supervisor");
    const supDeps = supT ? group.filter((d) => d.obj.kind === "Deployment" && nsOf(d) === supT.namespace && d.obj.metadata?.name === supT.deployment) : [];
    if (supDeps.length === 1) {
      const c = (podSpec(supDeps[0].obj)?.containers ?? []).find((x: any) => x?.name === SUPERVISOR_CONTAINER);
      const list = envOf(c, "OLIVE_POLICY_REVISION");
      const v = plainOne(list);
      if (isString(v) && POLICY_REVISION.test(v)) supRevision = v;
      else push(`${id(supDeps[0])} container ${SUPERVISOR_CONTAINER}`, policyShapeMessage(list, "감독"));
    }
    for (const t of mine) {
      const deps = group.filter((d) => d.obj.kind === "Deployment" && nsOf(d) === t.namespace && d.obj.metadata?.name === t.deployment);
      const quotas = group.filter((d) => d.obj.kind === "ResourceQuota" && nsOf(d) === t.namespace && d.obj.metadata?.name === "olive-limits");
      const twice = "정확히 하나여야 한다(CI는 첫 문서를, Argo CD는 마지막 문서를 고른다)";
      if (deps.length > 1) push(origin, `대상 ${t.id}의 Deployment ${t.namespace}/${t.deployment}가 같은 렌더에 ${deps.length}개다. ${twice}`);
      if (quotas.length > 1) push(origin, `대상 ${t.id}의 ResourceQuota ${t.namespace}/olive-limits가 같은 렌더에 ${quotas.length}개다. ${twice}`);
      if (quotas.length === 0) push(origin, `대상 ${t.id}의 네임스페이스 ${t.namespace}에 ResourceQuota olive-limits가 없다(그 네임스페이스의 총량 상한이 사라진다)`);
      // 대상 Deployment가 없으면 olive-chart-targets가 낸다.
      if (deps.length !== 1 || quotas.length !== 1) continue;
      if (t.kind === "supervisor") {
        const fsGroup = podSpec(deps[0].obj)?.securityContext?.fsGroup;
        if (fsGroup !== SUPERVISOR_FS_GROUP) push(id(deps[0]), `감독 파드의 fsGroup(${show(fsGroup)})이 ${SUPERVISOR_FS_GROUP}가 아니다. 감독은 0440 Secret(서명 키·계정·TLS)을 이 그룹으로 읽는다(실행기 파드에서만 뺐다, D-103)`);
      } else out.push(...executorPodViolations(t, deps[0], quotas[0], supRevision));
    }
  }
  return out;
}

// 실행기 파드 하나를 위 경계 표와 대조한다. supRevision: 같은 렌더 감독의 정책 판 번호(감독 쪽이 틀리면 undefined).
function executorPodViolations(t: Target, dep: Doc, quota: Doc, supRevision: string | undefined): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-executor-split", where, message });
  const where = id(dep);
  const spec = podSpec(dep.obj) ?? {};
  const containers: any[] = spec.containers ?? [];
  const inits: any[] = spec.initContainers ?? [];
  const names = (list: any[]) => list.map((c) => String(c?.name)).sort();
  if (JSON.stringify(names(containers)) !== JSON.stringify([EXECUTOR_CONTAINER, ROLE_CONTAINER]) || JSON.stringify(names(inits)) !== JSON.stringify([INIT_CONTAINER]) || (spec.ephemeralContainers ?? []).length > 0) {
    push(where, `대상 ${t.id}의 파드 구성이 일반 컨테이너 ${EXECUTOR_CONTAINER}·${ROLE_CONTAINER}, init ${INIT_CONTAINER} 하나가 아니다(일반 ${JSON.stringify(names(containers))}, init ${JSON.stringify(names(inits))}, 임시 ${(spec.ephemeralContainers ?? []).length}개)`);
    return out;
  }
  const exec = containers.find((c) => c.name === EXECUTOR_CONTAINER);
  const role = containers.find((c) => c.name === ROLE_CONTAINER);
  const init = inits[0];
  const cw = (c: any) => `${where} container ${c?.name}`;

  // 파드.
  const podSc = spec.securityContext ?? {};
  for (const k of keysOf(podSc, SPLIT_POD_SECURITY)) {
    if (same(podSc[k], SPLIT_POD_SECURITY[k])) continue;
    if (k === "fsGroup") push(where, `파드에 fsGroup(${show(podSc.fsGroup)})을 두지 않는다. 역할 컨테이너도 그 그룹이 된다(D-103)`);
    else if (k === "supplementalGroups") {
      if (Array.isArray(podSc.supplementalGroups) && podSc.supplementalGroups.length === 0) push(where, "파드에 supplementalGroups([])를 두지 않는다. 빈 목록은 그룹을 더하지 않지만 표에서는 이 필드를 생략한다");
      else push(where, `파드에 supplementalGroups(${show(podSc.supplementalGroups)})를 두지 않는다. 역할 컨테이너도 그 그룹이 된다(D-103)`);
    }
    else push(where, `파드 securityContext.${k}(${show(podSc[k])})가 표의 값(${show(SPLIT_POD_SECURITY[k])})과 다르다`);
  }
  if (spec.shareProcessNamespace === false) push(where, "shareProcessNamespace(false)를 두지 않는다. false는 PID 공간을 나누지 않지만 표에서는 이 필드를 생략한다");
  else if (spec.shareProcessNamespace !== undefined) push(where, "shareProcessNamespace를 두지 않는다. 역할 컨테이너가 제어 프로세스와 그 파일(/proc/<pid>/root)에 닿는다(D-102)");
  if (spec.resources !== undefined) push(where, `파드 단위 resources(${show(spec.resources)})를 두지 않는다. 있으면 쿠버네티스가 컨테이너 합 대신 그 값을 파드의 limits로 써서 olive-limits 대조가 실제와 달라진다(한도는 컨테이너 단위로만 준다)`);

  // 볼륨.
  const volumes = new Map<string, any>((spec.volumes ?? []).map((v: any) => [String(v?.name), v]));
  const typeOf = (name: string) => Object.keys(volumes.get(name) ?? {}).filter((x) => x !== "name");
  for (const name of volumes.keys()) if (!Object.hasOwn(SPLIT_VOLUMES, name)) push(where, `파드 볼륨 ${name}은 표에 없다(표: ${Object.keys(SPLIT_VOLUMES).join("·")})`);
  for (const [name, vr] of Object.entries(SPLIT_VOLUMES)) {
    const v = volumes.get(name);
    if (!v) {
      if (!vr.optional) push(where, `파드 볼륨 ${name}이 없다(표: ${vr.what ?? vr.type})`);
      continue;
    }
    const types = typeOf(name);
    if (vr.emptyDir) {
      if (types.length !== 1 || types[0] !== "emptyDir" || !same(v.emptyDir ?? {}, vr.emptyDir)) push(where, `볼륨 ${name}이 표의 ${vr.what}가 아니다(${JSON.stringify({ ...v, name: undefined })}). ${vr.why}`);
    } else if (types.length !== 1 || types[0] !== vr.type) push(where, `볼륨 ${name}이 표의 ${vr.type}가 아니다(${types.join(",")})`);
    else {
      if (vr.secret) {
        const { defaultMode: _mode, ...rest } = v.secret ?? {};
        if (!same(rest, vr.secret)) push(where, `볼륨 ${name}이 표의 ${vr.what}가 아니다(${JSON.stringify(rest)}). ${vr.why}`);
      }
      if (vr.mode) {
        for (const [file, mode] of fileModes(v[vr.type])) {
          if (mode !== SECRET_FILE_MODE) push(where, `볼륨 ${name}의 파일 ${file} 유효 모드 ${modeText(mode)}가 표의 0444가 아니다. 파드에 fsGroup이 없어 uid 65532는 기타 읽기 권한으로 읽는다`);
        }
      }
    }
  }

  // 컨테이너.
  for (const c of [init, exec, role]) {
    const rule = SPLIT_CONTAINERS[c.name];
    const who = String(c.name);
    const sc = c.securityContext ?? {};
    for (const [k, want] of [["runAsUser", rule.uid], ["runAsGroup", rule.gid]] as const) {
      const eff = sc[k] ?? podSc[k];
      if (eff === want) continue;
      if (c === role) push(cw(c), `역할 컨테이너의 실효 ${k}(${show(eff)})가 표의 ${want}가 아니다. 제어(${SPLIT_CONTAINERS[EXECUTOR_CONTAINER].uid})와 다른 uid·gid여야 모델이 제어의 파일을 읽지 못한다(D-100·D-103)`);
      else push(cw(c), `${who}의 실효 ${k}(${show(eff)})가 표의 ${want}가 아니다`);
    }
    for (const k of keysOf(sc, SPLIT_CONTAINER_SECURITY)) {
      if (k !== "runAsUser" && k !== "runAsGroup" && !same(sc[k], SPLIT_CONTAINER_SECURITY[k])) push(cw(c), `securityContext.${k}(${show(sc[k])})가 표의 값(${show(SPLIT_CONTAINER_SECURITY[k])})과 다르다(${who})`);
    }
    if (!same(c.command, rule.command)) push(cw(c), `command(${JSON.stringify(c.command)})가 ${rule.what} [${rule.command.join(", ")}] 하나가 아니다${c === role ? "(대리가 PID 1이어야 한다, D-102)" : ""}`);
    if (c.args !== undefined) push(cw(c), `args(${show(c.args)})를 두지 않는다(${who}의 명령은 표의 command 하나다)`);
    const relative = rule.command.slice(1).filter((a) => !a.startsWith("/"));
    if (relative.length > 0 && c.workingDir !== undefined && c.workingDir !== IMAGE_WORKDIR) {
      push(cw(c), `workingDir(${show(c.workingDir)})가 생략도 이미지 작업 폴더 ${IMAGE_WORKDIR}도 아니다(${who}. command의 상대 경로 ${relative.join("·")}를 그 폴더에서 찾는다)`);
    }
    if (c.restartPolicy !== undefined) {
      push(cw(c), `restartPolicy(${show(c.restartPolicy)})를 두지 않는다(${who}. ${c === init ? "Always면 설치 뒤 끝나지 않는 상시 실행 init이라 실효 limits가 일반 컨테이너 합에 더해져 olive-limits를 넘는다" : "표에 없는 재시작 규칙이다"})`);
    }
    // 마운트: 표 밖의 것, 표의 것(한 번, readOnly, 고정 경로, 다른 칸 없음), 겹침.
    const mounts: any[] = c.volumeMounts ?? [];
    for (const m of mounts) {
      const name = String(m?.name);
      if (Object.hasOwn(rule.mounts, name)) continue;
      if (c !== exec && typeOf(name).some((x) => SECRET_VOLUME_TYPES.includes(x))) push(cw(c), `비밀·PVC 볼륨 ${name}(${typeOf(name).join(",")})을 ${EXECUTOR_CONTAINER} 밖에 붙이지 않는다(모델이 키·저장소에 닿는다, D-73·D-100)`);
      else push(cw(c), `${name}을 ${who}에 붙이지 않는다(표 밖의 볼륨이다. ${who}의 표: ${Object.keys(rule.mounts).join("·")})`);
    }
    for (const [name, mr] of Object.entries(rule.mounts)) {
      const ms = mounts.filter((m) => m?.name === name);
      if (ms.length === 0) {
        if (!mr.optional) push(cw(c), `${name}을 ${who}에 붙이지 않았다(표: ${mr.path ?? "값 파일의 경로"}, ${mr.readOnly ? "읽기 전용" : "쓰기"})`);
        continue;
      }
      if (ms.length > 1) {
        push(cw(c), `${name}을 ${who}에 한 번 붙이지 않았다(${ms.length}번)`);
        continue;
      }
      const m = ms[0];
      if ((m.readOnly === true) !== mr.readOnly) push(cw(c), mr.readOnly ? `${name}을 readOnly: true로 붙이지 않았다(${who})` : `${name}을 쓰기 가능하게 붙이지 않았다(${who})`);
      if (mr.path !== undefined && m.mountPath !== mr.path) push(cw(c), `${name}의 mountPath ${show(m.mountPath)}가 표의 고정 경로 ${mr.path}가 아니다(${who})`);
      for (const k of Object.keys(m)) if (!["name", "mountPath", "readOnly"].includes(k)) push(cw(c), `${name} 마운트에 ${k}(${show(m[k])})를 두지 않는다(${who}. 볼륨 폴더 전체를 붙여야 컨테이너끼리 같은 파일을 본다)`);
    }
    const paths: [string, string][] = mounts.filter((m) => isString(m?.mountPath)).map((m) => [String(m.name), normPath(m.mountPath)]);
    for (const [i, [a, pa]] of paths.entries()) {
      for (const [b, pb] of paths.slice(i + 1)) {
        if (under(pa, pb) || under(pb, pa)) push(cw(c), `마운트 경로가 겹친다: ${a}(${pa})와 ${b}(${pb})(${who}. 같으면 PodTemplate이 유효하지 않고, 한쪽이 다른 쪽 안이면 그 파일이 가려진다)`);
      }
    }
    // env: executor 밖에는 Secret을 넣는 칸이 없고, 표가 있는 컨테이너는 이름 집합과 값이 표와 같다.
    if (c !== exec) {
      if ((c.envFrom ?? []).length > 0) push(cw(c), `envFrom을 두지 않는다(볼륨 없이도 Secret·ConfigMap 값이 ${EXECUTOR_CONTAINER} 밖으로 들어간다)`);
      for (const e of c.env ?? []) if (e?.valueFrom !== undefined) push(cw(c), `env ${e.name}에 valueFrom을 두지 않는다(볼륨 없이도 Secret 값이 ${EXECUTOR_CONTAINER} 밖으로 들어간다)`);
    }
    if (rule.env) {
      const tableEnv = rule.env;
      for (const [name, want] of Object.entries(tableEnv)) {
        const e = (c.env ?? []).filter((x: any) => x?.name === name);
        // valueFrom 항목은 위에서 따로 낸다(원인 하나에 위반 하나). 남은 값 항목만 표와 견준다.
        const plain = e.filter((x: any) => x?.valueFrom === undefined);
        if (plain.length === 0 && e.length > 0) continue;
        if (plain.length === 1 && (plain[0].value ?? "") === want) continue;
        if (name === "OLIVE_AGENT_SOCKET") push(cw(c), socketMessage(plain));
        else push(cw(c), `역할 컨테이너 env에 ${name}이 빈 값으로 한 번 있지 않다(${JSON.stringify(plain.map((x: any) => x.value))}). 대리 안의 Bun·로더가 이미지 ENV를 대리 코드보다 먼저 읽는다`);
      }
      // valueFrom 항목은 위에서 따로 낸다(원인 하나에 위반 하나).
      const extra = [...new Set((c.env ?? []).filter((x: any) => x?.valueFrom === undefined).map((x: any) => String(x?.name)).filter((n: string) => !Object.hasOwn(tableEnv, n)))];
      if (extra.length > 0) push(cw(c), `env에 표 밖의 이름 ${extra.join("·")}를 두지 않는다(${who}의 표: ${Object.keys(tableEnv).join("·") || "없음"}. 모델이 도는 환경과 설치기에 들어가는 값은 표의 것뿐이다)`);
    }
  }
  const execSocket = (exec.env ?? []).filter((x: any) => x?.name === "OLIVE_AGENT_SOCKET");
  if (!(execSocket.length === 1 && execSocket[0].valueFrom === undefined && execSocket[0].value === AGENT_SOCKET)) push(cw(exec), socketMessage(execSocket));
  const roleEnv = (exec.env ?? []).filter((x: any) => x?.name === "OLIVE_ROLE");
  if (roleEnv.length !== 1 || roleEnv[0].value !== t.role) push(cw(exec), `OLIVE_ROLE(${JSON.stringify(roleEnv.map((x: any) => x.value))})이 ${OLIVE_TARGETS_FILE}의 대상 ${t.id} role(${show(t.role)})과 같은 값 하나가 아니다(실행기는 배정한 v1 역할 하나만 받는다)`);
  const instance = envOf(exec, "OLIVE_INSTANCE");
  if (plainOne(instance) !== t.id) push(cw(exec), `OLIVE_INSTANCE(${envValues(instance)})이 대상 id ${t.id} 하나가 아니다(인스턴스 이름은 대상 id다, templates/_helpers.tpl olive.instance. 다르면 등록표 행과 효과 키 폴더 ${effectKeyPath(t)}가 어긋난다)`);
  const revision = envOf(exec, "OLIVE_POLICY_REVISION");
  const revisionValue = plainOne(revision);
  if (!isString(revisionValue) || !POLICY_REVISION.test(revisionValue)) push(cw(exec), policyShapeMessage(revision, `대상 ${t.id}`));
  else if (supRevision !== undefined && revisionValue !== supRevision) {
    push(cw(exec), `OLIVE_POLICY_REVISION(${JSON.stringify(revisionValue)})이 감독의 값(${JSON.stringify(supRevision)})과 다르다(대상 ${t.id}. 한 값 policy.revision에서 렌더해야 한다, D-108. 다르면 감독이 그 실행기에 새 일을 배정하지 않는다)`);
  }
  const keyFile = envOf(exec, "OLIVE_SIGNING_KEY_FILE");
  if (plainOne(keyFile) !== EFFECT_KEY_FILE) push(cw(exec), `OLIVE_SIGNING_KEY_FILE(${envValues(keyFile)})이 표의 ${EFFECT_KEY_FILE}(effect-signing 마운트 ${EFFECT_KEY_DIR} 안의 키 파일) 하나가 아니다`);
  for (const k of ["livenessProbe", "readinessProbe", "startupProbe", "lifecycle", "ports"]) {
    if (role[k] !== undefined) push(cw(role), `역할 컨테이너에 ${k}를 두지 않는다(D-74: kubelet이 그 안에서 명령을 돌리지 않게)`);
  }

  // 이미지.
  if (!isString(exec.image) || !OLIVE_IMAGE.test(exec.image)) push(cw(exec), `이미지(${show(exec.image)})가 ghcr.io/ukyi-app/olive@sha256:<64 hex>가 아니다`);
  if (init.image !== exec.image) push(cw(init), `${INIT_CONTAINER} 이미지(${init.image})가 ${EXECUTOR_CONTAINER} 이미지(${exec.image})와 다르다. 대리와 실행기는 같은 판이어야 한다(D-103)`);
  const wantImage = roleImageWanted(t.role);
  if (wantImage === undefined) push(cw(role), `대상 ${t.id}의 role(${show(t.role)})에 표의 역할 이미지가 없다(RENDER_FILL roleImages)`);
  else if (role.image !== wantImage) push(cw(role), `역할 컨테이너 이미지(${show(role.image)})가 대상 ${t.id}의 역할 ${String(t.role)} 이미지(${wantImage})가 아니다`);

  // 한도.
  for (const [k, parse] of [["limits.cpu", cpuMilli], ["limits.memory", memBytes]] as const) {
    const field = k.split(".")[1];
    const sum = containers.reduce((a, c) => a + parse(c?.resources?.limits?.[field]), 0);
    const want = Math.max(sum, ...inits.map((c) => parse(c?.resources?.limits?.[field])));
    const have = parse(quota.obj.spec?.hard?.[k]);
    if (!(Number.isFinite(want) && have === want)) push(id(quota), `ResourceQuota ${k}(${JSON.stringify(quota.obj.spec?.hard?.[k])})가 대상 ${t.id} 파드의 실효 limits(${Number.isFinite(want) ? want : "읽을 수 없음"}, 일반 컨테이너 합과 가장 큰 init 중 큰 값)와 같지 않다`);
  }
  return out;
}
const socketMessage = (e: any[]) =>
  `OLIVE_AGENT_SOCKET(${JSON.stringify(e.map((x: any) => x.value))})이 표의 ${AGENT_SOCKET} 하나가 아니다(agent-link 마운트 ${AGENT_LINK_DIR} 바로 아래 정상 파일 이름이어야 두 컨테이너가 같은 파일을 본다)`;

// 작업자 실행기의 효과 서명 키 비밀 연결(D-73·D-100, templates/clustersecretstore.yaml·executor-externalsecrets.yaml).
// Free 플랜에는 Infisical 경로 권한이 없어 store의 secretsPath는 경계가 아니다. 절대 키(/로 시작)는 secretsPath를 무시하고 감독 폴더
// (/olive/supervisor)나 계정 폴더까지 읽는다(앱 store의 같은 함정은 data.ts checkSecretPaths). 상대 키도 폴더 성분(../)을 붙이면 provider가
// 기본 폴더와 합쳐 정규화하므로 글자만 봐서는 폴더 안인지 알 수 없다. 그래서 경계는 실행기 ns에 열린 store와 그 ns의 ExternalSecret
// 목록 자체이고, 이 검사가 렌더 단위(keyUnits)마다 둘을 본다:
//   - 실행기 ns에 열린 store는 켠 렌더에서 그 실행기의 store 하나, 끈 렌더에서 0개다. 같은 클러스터의 모든 배포 출처를 본다
//     (ClusterSecretStore는 어느 차트가 만들든 클러스터 전체에 하나다). conditions가 없으면 모든 ns가 쓰고, namespaceRegexes는
//     실행기 ns 이름과 실제로 맞춰 본다(ESO는 앞뒤를 고정하지 않는 MatchString이다). JS로 읽을 수 없는 정규식과 namespaceSelector는
//     렌더로 풀 수 없어 열린 것으로 본다.
//   - 켠 렌더: 실행기마다 store infisical-olive-executor-<인스턴스>가 정확히 하나, conditions는 [{namespaces: [그 ns]}] 그대로,
//     secretsPath는 /olive/executors/<인스턴스>다(인스턴스 = 대상 id, templates/_helpers.tpl olive.instance). 감독 store는 감독 ns 하나다.
//   - 켠 렌더의 실행기 ns ExternalSecret은 효과 키 ExternalSecret(target olive-effect-signing-key) 하나뿐이다. 자기 store
//     (kind ClusterSecretStore)를 쓰고 data는 EFFECT_SIGNING_KEY → EFFECT_SIGNING_KEY 하나, dataFrom은 없다(파일 이름 = Secret 키 =
//     Infisical 키. OLIVE_SIGNING_KEY_FILE과 볼륨 items는 olive-executor-split이 본다). 다른 Secret이 필요한 계약이 생기면
//     그 대상·store·키를 여기에 명시해 늘린다. 이름만 다른 ExternalSecret을 허용하면 위 정규화 함정으로 폴더 경계가 사라진다.
//   - 끈 렌더(복구 스위치 externalSecrets.enabled=false): 이 차트의 store·ExternalSecret이 0개, 실행기 ns의 ExternalSecret도 0개다.
//     같은 이름 Secret은 사람이 손으로 만든다(restore.md 3절 U40). 볼륨은 스위치와 상관없이 olive-executor-split이 본다.
// 켬·끔은 문서 개수가 아니라 렌더에 넣은 값으로 정한다. 문서로 정하면 ExternalSecret 생성이 빠진 렌더가 store 검사까지 건너뛴다.
function checkExecutorKey(targets: Target[], charts: Record<string, Doc[]>, deployed: Record<string, Doc[]>): Violation[] {
  const executors = targets.filter((t) => t.kind === "executor" && t.declaredBy === OLIVE_CHART);
  const sup = targets.find((t) => t.kind === "supervisor" && t.declaredBy === OLIVE_CHART);
  return keyUnits(charts, deployed).flatMap((u) => executorKeyViolations(u, executors, sup));
}

// 키 검사의 렌더 단위. docs: 그 렌더의 문서 전부, owned: 이 차트가 낸 문서인지, enabled: 그 렌더에 넣은 복구 스위치 값.
type KeyUnit = { where: string; docs: Doc[]; owned: (d: Doc) => boolean; enabled: boolean };
const SUPERVISOR_STORE = "infisical-olive";

// 차트 ci 렌더는 값 파일마다 하나(문서가 모두 이 차트 것), 배포 렌더는 켠 root 렌더의 클러스터마다 하나(모든 배포 출처).
// 켠 root 렌더는 지금 root 렌더에 olive를 켠 것이라 다른 출처를 빠짐없이 담는다. 지금 root 렌더를 따로 보면 같은 store가 두 번 걸린다.
function keyUnits(charts: Record<string, Doc[]>, deployed: Record<string, Doc[]>): KeyUnit[] {
  const units: KeyUnit[] = [];
  const base = valueLayers(`${OLIVE_CHART}/values.yaml`);
  const byOrigin = new Map<string, Doc[]>();
  for (const d of expand(charts[OLIVE_CHART] ?? [])) byOrigin.set(d.origin, [...(byOrigin.get(d.origin) ?? []), d]);
  for (const [origin, docs] of byOrigin) {
    const m = origin.match(/^chart:olive\/(ci\/.+)$/);
    units.push({ where: origin, docs, owned: () => true, enabled: switchOn([...base, ...(m ? valueLayers(`${OLIVE_CHART}/${m[1]}`) : [])]) });
  }
  const forced = expand(deployed[FORCED] ?? []).filter(deployedDoc);
  for (const cluster of [...new Set(forced.map((d) => sourceOf(d.origin).cluster!))]) {
    const docs = forced.filter((d) => sourceOf(d.origin).cluster === cluster);
    // root는 platform/olive에 valuesObject만 넘긴다(platform/root/templates/olive.yaml). valueFiles가 생겨도 같은 순서로 쌓는다.
    // 같은 차트를 내는 Application이 여럿이거나 없으면 olive-owner가 낸다. 여기서는 하나라도 켰으면 켠 것으로, 없으면 차트 기본값으로 본다.
    const apps = argoApps(docs).flatMap((a) => effectiveSources(a.obj.spec).filter((s) => sameRepo(s?.repoURL) && s?.path === OLIVE_CHART));
    const enabled = apps.length === 0 ? switchOn(base) : apps.some((s) => switchOn([...base, ...(s?.helm?.valueFiles ?? []).flatMap((f: unknown) => (isString(f) ? valueLayers(posix.join(OLIVE_CHART, f)) : [])), s?.helm?.valuesObject]));
    units.push({ where: `${FORCED}[${cluster}]`, docs, owned: (d) => sourceOf(d.origin).path === OLIVE_CHART, enabled });
  }
  return units;
}
function valueLayers(path: string): unknown[] {
  if (!existsSync(join(ROOT, path))) return [];
  const v = Bun.YAML.parse(readText(path));
  return Array.isArray(v) ? v : [v];
}
// Helm처럼 뒤 층이 이긴다. 비어 있으면 Helm의 if처럼 꺼짐이다.
function switchOn(layers: unknown[]): boolean {
  let v: unknown;
  for (const l of layers) {
    const x = (l as any)?.externalSecrets?.enabled;
    if (x !== undefined) v = x;
  }
  return !(v === false || v === null || v === 0 || v === "");
}

// store의 conditions가 ns에 열리는 이유. 닫혀 있으면 undefined.
function storeOpensTo(conds: unknown, ns: string): string | undefined {
  if (!Array.isArray(conds) || conds.length === 0) return "conditions 없음: 모든 ns가 쓴다";
  for (const c of conds as any[]) {
    if (c?.namespaceSelector !== undefined) return `namespaceSelector ${JSON.stringify(c.namespaceSelector)}: 렌더로 풀 수 없다`;
    if (Array.isArray(c?.namespaces) && c.namespaces.includes(ns)) return `conditions namespaces에 ${ns}가 있다`;
    for (const re of Array.isArray(c?.namespaceRegexes) ? c.namespaceRegexes : c?.namespaceRegexes === undefined ? [] : [c.namespaceRegexes]) {
      let hit: boolean;
      try {
        hit = isString(re) && new RegExp(re).test(ns);
      } catch {
        return `namespaceRegexes ${JSON.stringify(re)}: 읽을 수 없는 정규식`;
      }
      if (!isString(re)) return `namespaceRegexes ${JSON.stringify(re)}: 문자열이 아니다`;
      if (hit) return `namespaceRegexes ${JSON.stringify(re)}가 ${ns}에 맞는다`;
    }
  }
  return undefined;
}

function executorKeyViolations(u: KeyUnit, executors: Target[], sup: Target | undefined): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-executor-key", where, message });
  const stores = u.docs.filter((d) => d.obj.kind === "ClusterSecretStore");
  const esTarget = (d: Doc) => d.obj.spec?.target?.name ?? d.obj.metadata?.name;
  if (!u.enabled) {
    const left = u.docs.filter((d) => u.owned(d) && (d.obj.kind === "ClusterSecretStore" || d.obj.kind === "ExternalSecret"));
    if (left.length > 0) push(u.where, `복구 스위치(externalSecrets.enabled)를 끈 렌더에 이 차트의 store·ExternalSecret이 ${left.length}개 있다(${left.map(id).join(", ")}). 끄면 0개다(같은 이름 Secret은 사람이 만든다)`);
  } else if (sup) {
    // 실행기 ns에 열린 경우는 아래 실행기별 검사가 낸다(원인 하나에 위반 하나).
    for (const s of stores.filter((d) => d.obj.metadata?.name === SUPERVISOR_STORE && u.owned(d))) {
      const conds = s.obj.spec?.conditions;
      if (!same(conds, [{ namespaces: [sup.namespace] }]) && !executors.some((t) => storeOpensTo(conds, t.namespace))) {
        push(id(s), `감독 store ${SUPERVISOR_STORE}의 conditions(${show(conds)})가 [{namespaces: [${sup.namespace}]}]가 아니다(감독 ns 하나만 계정·서명 키 폴더를 읽는다)`);
      }
    }
  }
  for (const t of executors) {
    const want = effectKeyStore(t);
    if (u.enabled) {
      const own = stores.filter((d) => d.obj.metadata?.name === want);
      if (own.length !== 1) push(u.where, `대상 ${t.id}의 ClusterSecretStore ${want}가 정확히 하나가 아니다(${own.length}개). 실행기 ns마다 전용 store 하나다(D-73)`);
      else {
        const conds = own[0].obj.spec?.conditions;
        if (!same(conds, [{ namespaces: [t.namespace] }])) push(id(own[0]), `store ${want}의 conditions(${show(conds)})가 [{namespaces: [${t.namespace}]}]가 아니다(그 실행기 ns 하나만 이 store를 쓴다)`);
        const path = own[0].obj.spec?.provider?.infisical?.secretsScope?.secretsPath;
        if (path !== effectKeyPath(t)) push(id(own[0]), `store ${want}의 secretsPath(${show(path)})가 ${effectKeyPath(t)}가 아니다(인스턴스 이름 = 대상 id의 폴더)`);
      }
    }
    for (const s of stores) {
      // 켠 렌더의 자기 store는 위에서, 끈 렌더의 이 차트 store는 스위치 검사가 낸다.
      if (u.enabled ? s.obj.metadata?.name === want : u.owned(s)) continue;
      const why = storeOpensTo(s.obj.spec?.conditions, t.namespace);
      if (why) push(id(s), `store ${s.obj.metadata?.name}가 실행기 ns ${t.namespace}에 열려 있다(${why}). 실행기 ns에 열린 store는 ${u.enabled ? want : "없다(복구 스위치 끔)"}${u.enabled ? " 하나다" : ""}(감독 ns용 비밀 연결을 실행기에 열지 않는다, D-73)`);
    }
    const ess = u.docs.filter((d) => d.obj.kind === "ExternalSecret" && nsOf(d) === t.namespace);
    if (!u.enabled) {
      for (const es of ess.filter((d) => !u.owned(d))) push(id(es), `복구 스위치를 끈 렌더의 실행기 ns ${t.namespace}에 ExternalSecret이 있다. 끄면 그 ns의 ExternalSecret은 0개다`);
      continue;
    }
    for (const es of ess.filter((d) => esTarget(d) !== EFFECT_KEY_SECRET)) {
      push(id(es), `실행기 ns ${t.namespace}의 ExternalSecret(target ${show(esTarget(es))})은 허용 목록 밖이다. 실행기 ns의 ExternalSecret은 효과 서명 키(target ${EFFECT_KEY_SECRET}) 하나다(상대 키의 폴더 성분과 dataFrom이 기본 폴더 밖을 읽는다. 늘리려면 대상·store·키를 이 검사에 명시한다)`);
    }
    const effect = ess.filter((d) => esTarget(d) === EFFECT_KEY_SECRET);
    if (effect.length !== 1) {
      push(u.where, `대상 ${t.id}의 ns ${t.namespace}에 효과 서명 키 ExternalSecret(target ${EFFECT_KEY_SECRET})이 정확히 하나가 아니다(${effect.length}개)`);
      continue;
    }
    const es = effect[0];
    const ref = es.obj.spec?.secretStoreRef ?? {};
    if (ref.kind !== "ClusterSecretStore" || ref.name !== want) push(id(es), `실행기 ns ${t.namespace}의 ExternalSecret이 자기 store(ClusterSecretStore ${want})가 아닌 ${show(ref.kind)} ${show(ref.name)}를 쓴다`);
    const keys: unknown[] = [
      ...(es.obj.spec?.data ?? []).map((x: any) => x?.remoteRef?.key),
      ...(es.obj.spec?.dataFrom ?? []).flatMap((x: any) => [x?.extract?.key, x?.find?.path]),
    ];
    const absolute = keys.filter((k): k is string => isString(k) && k.startsWith("/"));
    for (const k of absolute) push(id(es), `실행기 ns ${t.namespace}의 ExternalSecret이 절대 키 ${k}를 쓴다(secretsPath를 무시하고 감독·계정 폴더까지 읽는다. Free 플랜에는 경로 권한이 없다)`);
    // 절대 키는 위에서 따로 낸다(원인 하나에 위반 하나).
    if (absolute.length > 0) continue;
    const spec = es.obj.spec ?? {};
    if (!same(spec.data, [{ secretKey: EFFECT_KEY, remoteRef: { key: EFFECT_KEY } }]) || spec.dataFrom !== undefined) {
      push(id(es), `효과 서명 키 ExternalSecret의 data(${show(spec.data)}${spec.dataFrom !== undefined ? `, dataFrom ${show(spec.dataFrom)}` : ""})가 ${EFFECT_KEY} → ${EFFECT_KEY} 하나가 아니다(파일 이름 = Secret 키 = Infisical 키)`);
    }
  }
  return out;
}

const argoApps = (docs: Doc[]) => docs.filter((d) => d.obj.kind === "Application" && String(d.obj.apiVersion).startsWith("argoproj.io/") && deployedDoc(d));
const deployersOf = (apps: Doc[], cluster: string, chart: string) =>
  apps.filter((a) => context(a.origin) === cluster && effectiveSources(a.obj.spec).some((s) => sameRepo(s?.repoURL) && s?.path === chart));

// 차트의 ci/*.yaml 렌더마다 그 차트가 선언한 대상이 있고 replicas가 0인지. 렌더 호출 단위로 보므로 문서가 0개인 값 파일도 걸린다.
// platform/olive는 목록과 렌더가 같은 집합이어야 한다.
function checkChartTargets(targets: Target[], charts: Record<string, Doc[]>, renders: Record<string, string[]>): Violation[] {
  const out: Violation[] = [];
  for (const chart of [...new Set(targets.map((t) => t.declaredBy).filter((d) => d !== ""))]) {
    const mine = targets.filter((t) => t.declaredBy === chart);
    const docs = expand(charts[chart] ?? []);
    const origins = renders[chart] ?? [];
    if (origins.length === 0) out.push({ rule: "olive-chart-targets", where: chart, message: "켠 값 파일(ci/*.yaml)의 렌더가 없다. 대상 Deployment를 확인할 수 없다" });
    for (const origin of origins) {
      const deps = docs.filter((d) => d.origin === origin && d.obj.kind === "Deployment");
      for (const t of mine) {
        const found = deps.filter((d) => nsOf(d) === t.namespace && d.obj.metadata?.name === t.deployment);
        if (found.length === 0) out.push({ rule: "olive-chart-targets", where: origin, message: `${OLIVE_TARGETS_FILE}의 대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})가 렌더에 없다` });
        for (const d of found) out.push(...replicasViolations(d, t), ...annotationViolations(d, t));
      }
      if (chart !== OLIVE_CHART) continue;
      for (const d of deps) {
        if (!mine.some((t) => t.namespace === nsOf(d) && t.deployment === d.obj.metadata?.name)) {
          out.push({ rule: "olive-chart-targets", where: id(d), message: `${OLIVE_TARGETS_FILE}에 없는 Deployment다. 비상 정지·소멸 확인이 이 파드를 덮지 못한다` });
        }
      }
    }
  }
  return out;
}

// 실제 Application 값의 렌더(AC-29: 최초 배포 때 1로 생기면 안 된다). 클러스터마다 본다.
//   - REAL(지금 root): 그 클러스터에 대상 차트를 source로 하는 Application이 있으면 그 렌더에 대상이 있어야 한다(없으면 꺼진 구성
//     요소라 요구하지 않는다). FORCED(대상 차트를 켠 root): 꺼 둔 구성 요소도 실제 값으로 보며 대상이 꼭 있어야 한다.
//     소유 Application의 존재·개수는 checkIgnoreDifferences가 본다(FORCED는 클러스터마다 하나, REAL은 둘 이상이면 실패).
//   - 소유(olive-owner): 대상 자리(유효 ns·Deployment 이름)의 Deployment는 declaredBy 차트를 source로 하는 Application 하나만 낸다.
//     declaredBy가 빈 대상의 자리에는 어느 렌더에도 Deployment가 없다. 다른 소스가 같은 자리에 내면 그 replicas·예외를 아무도 보지 않는다.
//   유효 ns는 metadata.namespace, 없으면 Application의 destination.namespace다(render.ts가 Doc.ns로 넘긴다).
function checkDeployed(targets: Target[], deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const clusters = clusterNames();
  for (const [variant, raw] of Object.entries(deployed)) {
    const docs = expand(raw);
    const forced = variant === FORCED;
    const applications = argoApps(docs);
    const seenClusters = new Set(docs.map((d) => sourceOf(d.origin).cluster).filter(isString));
    for (const c of clusters) if (!seenClusters.has(c)) out.push({ rule: "olive-chart-targets", where: `${variant}[${c}]`, message: "이 클러스터의 Application 렌더가 없다. 실제 값의 대상을 확인할 수 없다" });
    for (const t of targets) {
      const at = docs.filter((d) => d.obj.kind === "Deployment" && nsOf(d) === t.namespace && d.obj.metadata?.name === t.deployment);
      if (t.declaredBy === "") {
        for (const d of at) out.push({ rule: "olive-owner", where: id(d), message: `declaredBy가 빈 대상 ${t.id}의 자리에 ${srcName(sourceOf(d.origin))}가 Deployment를 낸다. 선언하는 PR이 targets.yaml의 declaredBy를 함께 채운다` });
        continue;
      }
      for (const d of at) {
        const s = sourceOf(d.origin);
        if (s.path !== t.declaredBy) out.push({ rule: "olive-owner", where: id(d), message: `대상 ${t.id}의 자리에 다른 소스 ${srcName(s)}가 Deployment를 낸다(소유는 ${t.declaredBy})` });
      }
      for (const c of clusters) {
        const own = at.filter((d) => sourceOf(d.origin).cluster === c && sourceOf(d.origin).path === t.declaredBy);
        const apps = [...new Set(own.map((d) => sourceOf(d.origin).app))];
        if (apps.length > 1) out.push({ rule: "olive-owner", where: `${variant}[${c}]`, message: `대상 ${t.id}를 Application ${apps.join(", ")}가 함께 낸다(하나여야 한다)` });
        const deployed = forced || deployersOf(applications, c, t.declaredBy).length > 0;
        if (deployed && own.length === 0) out.push({ rule: "olive-chart-targets", where: `${variant}[${c}]`, message: `대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})가 ${t.declaredBy}의 실제 값 렌더에 없다` });
        for (const d of own) out.push(...replicasViolations(d, t), ...annotationViolations(d, t));
      }
    }
    for (const d of docs) {
      const s = sourceOf(d.origin);
      if (s.cluster === undefined || s.path !== OLIVE_CHART || d.obj.kind !== "Deployment") continue;
      if (!targets.some((t) => t.declaredBy === OLIVE_CHART && t.namespace === nsOf(d) && t.deployment === d.obj.metadata?.name)) {
        out.push({ rule: "olive-chart-targets", where: id(d), message: `${OLIVE_TARGETS_FILE}에 없는 Deployment다. 비상 정지·소멸 확인이 이 파드를 덮지 못한다` });
      }
    }
  }
  return out;
}

// Argo CD v3.6.1 util/argo/normalizers/diff_normalizer.go(ignoreNormalizer.Normalize)의 선택: group·kind는 glob(gobwas, 빈 값은 빈
// group·kind에만 맞는다), name·namespace는 빈 값이면 전부, 아니면 정확히 같을 때. 이 검사는 glob을 풀지 않고 glob 문자가 든 값과
// 문자열이 아닌 값을 "적용된다"로 본다(보수적: 대상과 겹치지 않는 glob, 예 kind Stateful*도 거절한다).
// jqPathExpressions·managedFieldsManagers도 같은 선택을 거친다.
const GLOB_CHARS = /[*?[\]{}\\!]/;
function fieldApplies(pattern: unknown, value: string, emptyIsAll: boolean): boolean {
  if (pattern === undefined || pattern === null || pattern === "") return emptyIsAll;
  if (!isString(pattern) || GLOB_CHARS.test(pattern)) return true;
  return pattern === value;
}
const applies = (e: any, t: Target) =>
  fieldApplies(e?.group, "apps", false) && fieldApplies(e?.kind, "Deployment", false) && fieldApplies(e?.name, t.deployment, true) && fieldApplies(e?.namespace, t.namespace, true);
const exactSelector = (e: any, t: Target) => e?.group === "apps" && e?.kind === "Deployment" && e?.namespace === t.namespace && e?.name === t.deployment;
const exactEntry = (e: any, t: Target) =>
  exactSelector(e, t) && Object.keys(e).every((k) => ["group", "kind", "namespace", "name", "jsonPointers"].includes(k)) && JSON.stringify(e.jsonPointers) === JSON.stringify(REPLICAS_POINTER);

// 대상을 배포하는 Application의 replicas 예외(supervisor.md §7.1 1). 클러스터마다 두 렌더에서 본다. FORCED(대상 차트를 켠 root)에는
// 소유 Application이 꼭 하나다. REAL(지금 root)은 지금 실제로 배포하는 Application이라 그 예외가 클러스터에 적용되는 값이다.
// REAL에 소유 Application이 없으면(꺼진 구성 요소) 보지 않는다. FORCED만 보면 지금 켜진 Application이 꺼진 조합에서만 내는 예외를 놓친다.
// 예외가 없으면 selfHeal이 CLI가 켠 값을 Git 값 0으로 되돌리고, RespectIgnoreDifferences가 없으면 다른 이유의 sync가 덮는다.
// 대상에 적용되는 항목은 정확한 모양 하나만이다. 넓은 선택자나 다른 칸이 끼면 그 칸의 라이브 변경(이미지, 볼륨, 다른 Deployment)을
// Git이 되돌리지 않는다. platform/olive 밖의 대상은 start: true일 때만 예외를 둔다(그 전에는 손으로 올린 값을 selfHeal이 내린다).
function checkIgnoreDifferences(targets: Target[], deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-ignore-differences", where, message });
  const charts = [...new Set(targets.map((t) => t.declaredBy).filter((d) => d !== ""))];
  const clusters = clusterNames();
  const appsOf: Record<string, Doc[]> = { [REAL]: argoApps(expand(deployed[REAL] ?? [])), [FORCED]: argoApps(expand(deployed[FORCED] ?? [])) };
  for (const [variant, c] of [REAL, FORCED].flatMap((v) => clusters.map((x) => [v, x] as const))) {
    for (const chart of charts) {
      const mine = targets.filter((t) => t.declaredBy === chart);
      const deployers = deployersOf(appsOf[variant], c, chart);
      if (variant === REAL && deployers.length === 0) continue;
      if (deployers.length !== 1) {
        push(`${variant}[${c}] ${chart}`, `${chart}를 배포하는 Application이 ${deployers.length}개다(하나여야 그 예외를 확인한다)`);
        continue;
      }
      const app = deployers[0];
      const appName = app.obj.metadata?.name;
      const entries: any[] = Array.isArray(app.obj.spec?.ignoreDifferences) ? app.obj.spec.ignoreDifferences : [];
      entries.forEach((e, i) => {
        const w = `${id(app)} ignoreDifferences[${i}]`;
        const hit = mine.filter((t) => applies(e, t));
        if (hit.length === 0) {
          if (chart === OLIVE_CHART) push(w, `${OLIVE_TARGETS_FILE}에 없는 리소스의 예외다(${e?.kind} ${e?.namespace}/${e?.name}). ${appName}의 예외는 대상 Deployment의 /spec/replicas뿐이다`);
          return;
        }
        for (const t of hit) {
          if (exactSelector(e, t) && !exactEntry(e, t)) {
            const extra = Object.keys(e).filter((k) => !["group", "kind", "namespace", "name", "jsonPointers"].includes(k));
            push(w, `대상 ${t.id}의 예외가 /spec/replicas 말고 다른 칸을 가리킨다(jsonPointers ${JSON.stringify(e.jsonPointers ?? [])}${extra.length ? `, ${extra.join(", ")}` : ""})`);
          } else if (!exactSelector(e, t)) {
            push(w, `대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})에 적용되는 넓은 예외다(group ${JSON.stringify(e?.group)}, kind ${JSON.stringify(e?.kind)}, namespace ${JSON.stringify(e?.namespace)}, name ${JSON.stringify(e?.name)}). group apps·kind Deployment·그 namespace·name·/spec/replicas만 적는다`);
          } else if (chart !== OLIVE_CHART && t.start !== true) {
            push(w, `대상 ${t.id}가 start: true가 아닌데 ${appName}에 그 replicas 예외가 있다. 손으로 올린 값을 selfHeal이 되돌리지 못한다(켜는 PR이 start와 함께 넣는다)`);
          }
        }
      });
      // platform/olive는 대상 전부(start와 상관없이 켜고 끄기는 CLI다). 다른 차트는 지금 켤 수 있는(start: true) 대상만 요구한다.
      // 선택자가 정확한 항목이 있으면 칸이 틀린 것은 위에서 따로 낸다(원인을 둘로 보이지 않게).
      for (const t of mine) {
        if (entries.some((e) => exactSelector(e, t))) continue;
        if (chart === OLIVE_CHART) push(id(app), `대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})의 /spec/replicas 예외가 없다`);
        else if (t.start === true) push(id(app), `대상 ${t.id}가 start: true인데 그 Deployment(${t.namespace}/${t.deployment})를 배포하는 ${appName}에 /spec/replicas 예외가 없다. selfHeal이 CLI가 켠 값을 0으로 되돌린다`);
      }
      const hasTargetEntry = entries.some((e) => mine.some((t) => applies(e, t)));
      const respect = (app.obj.spec?.syncPolicy?.syncOptions ?? []).includes("RespectIgnoreDifferences=true");
      if ((chart === OLIVE_CHART || hasTargetEntry) && !respect) {
        push(id(app), "syncOptions에 RespectIgnoreDifferences=true가 없다. 다른 이유의 sync가 Git 값 0으로 덮어 CLI가 켠 파드를 내린다");
      }
    }
  }
  return out;
}

export function checkOliveTargets(input: OliveInput): Violation[] {
  const targets = targetList(input.targets);
  // 실제 값으로 켠 렌더에도 격리 검사를 건다. render 단계는 지금 root(꺼진 구성 요소 없음)와 ci/*.yaml 렌더만 본다.
  const forcedApps = (input.deployed[FORCED] ?? []).filter(deployedDoc);
  return [
    ...checkTargetShape(input.targets),
    ...checkChartTargets(targets, input.charts, input.chartRenders),
    ...checkExecutorStore(targets, input.charts, input.deployed),
    ...checkExecutorSplit(targets, input.charts, input.deployed),
    ...checkExecutorKey(targets, input.charts, input.deployed),
    ...checkDeployed(targets, input.deployed),
    ...checkIgnoreDifferences(targets, input.deployed),
    ...checkOliveIsolation(forcedApps, input.targets, input.host),
  ];
}

export function readOliveTargets(): any {
  return Bun.YAML.parse(readText(OLIVE_TARGETS_FILE));
}

// 올리브 실행 네임스페이스의 금지(D-37, supervisor.md §1.1, AC-29). 전체 렌더에서 본다. 다른 차트가 올리브 ns에 워크로드를 두거나
// 올리브 SA를 묶는 바인딩을 더해도 걸린다. 대상 ns는 대상 줄 전부의 ns에서 ISOLATION_DELEGATED를 뺀 것이다(선언 주체와 상관없다).
//   - 대상 자료 밖의 워크로드: 정지는 대상 Deployment만 0으로 내린다. 자물쇠는 새 파드만 막아 이미 뜬 파드가 남는다.
//     정지 중에도 떠야 하는 것은 실행 ns 밖에 둔다(B-16).
//   - RBAC: 감독에 Kubernetes 쓰기 권한이 없고 실행기에는 클러스터 자격이 없다. ns 안 Role·RoleBinding도, 밖에서 올리브 SA를 묶는 것도 막는다.
//     SA는 kind: User(system:serviceaccount:<ns>:<이름>)와 그룹으로도 묶인다.
//   - 토큰: 파드가 실제로 쓰는 SA(serviceAccountName, 없으면 default)가 같은 렌더 맥락·ns에 있어야 하고, 그 SA와 파드 양쪽의 자동
//     마운트가 꺼져 있다. 렌더에 없는 SA(클러스터의 default 포함)는 값을 확인할 수 없다. projected 토큰은 볼륨 허용 목록이 막는다.
//   - 호스트: hostNetwork·hostPID·hostIPC, hostPath(hc 소켓 자리), 0이 아닌 hostPort, privileged, allowPrivilegeEscalation, capability
//     추가를 막는다(초기화·임시 컨테이너 포함). Namespace에는 PSA enforce: restricted가 있어야 한다. 렌더에서 막는 이유: PSA는 생성 때만
//     거절하므로 잘못된 템플릿이 병합되면 다음 기동이 실패한다.
//   - 볼륨은 emptyDir·secret·configMap·PVC만. PVC는 OLIVE_PVC_CLASSES의 동적 프로비저닝만이다. selector·volumeName이 있거나 그 클래스로
//     묶일 수 있는 Git 정적 PV가 있으면 노드의 아무 경로나 가리키는 PV에 묶일 수 있다. 정적 PV·StorageClass는 플랫폼 렌더와
//     호스트가 설치하는 매니페스트(install.sh가 host/k3s-manifests 바로 아래 *.yaml을 k3s 자동 배포에 넣는다)를 함께 본다. 허용 클래스는 호스트
//     매니페스트에 선언돼 있고 provisioner가 정한 동적 프로비저너여야 한다.
//     이전 클래스 표기(volume.beta.kubernetes.io/storage-class 주석)는 Kubernetes가 spec.storageClassName보다 먼저 읽는다
//     (component-helpers storage/volume GetPersistentVolume(Claim)Class). 유효 클래스를 따로 계산하지 않고 올리브 PVC와
//     결합 후보 PV(claimRef 없음)에서 거절한다.
//   - 두 번째 조절 주체: 대상 Deployment(위임한 ns 포함)를 가리키는 HorizontalPodAutoscaler. CLI가 켠 뒤 replicas를 바꾼다.
//     이 저장소에는 다른 조절 리소스(KEDA·VPA)의 CRD가 없다.
const OLIVE_VOLUME_TYPES = new Set(["emptyDir", "secret", "configMap", "persistentVolumeClaim"]);
// 허용 클래스 → 그 provisioner. host/k3s-manifests/local-retain.yaml: rancher.io/local-path, WaitForFirstConsumer. 파드가 놓인 노드에
// PV를 새로 만든다. provisioner가 바뀌면(정적 PV만 쓰는 클래스 등) 이름이 같아도 동적 프로비저닝이 아니다.
const OLIVE_PVC_CLASSES = new Map([["local-retain", "rancher.io/local-path"]]);
const BETA_CLASS = "volume.beta.kubernetes.io/storage-class";
const HOST_MANIFEST_DIR = "host/k3s-manifests";
export const HOST_MANIFESTS = `${HOST_MANIFEST_DIR}/*.yaml`;
export type HostManifests = { docs: Doc[]; errors: string[] };
// install.sh의 설치 루프(bash 기본 glob "$HOST_DIR"/k3s-manifests/*.yaml)와 같은 범위: 바로 아래의 숨김 아닌 .yaml만.
// git pathspec의 *는 디렉터리 경계를 넘어 하위 디렉터리 파일도 고른다. 그 파일은 호스트에 설치되지 않으므로 거기 둔 StorageClass가
// 존재 검사를 채우면 안 된다(render.ts plainDir와 같은 거르기).
export function hostManifestFiles(tracked: string[]): string[] {
  return tracked.filter((f) => dirname(f) === HOST_MANIFEST_DIR && !basename(f).startsWith(".") && f.endsWith(".yaml"));
}
export function readHostManifests(tracked: string[] = gitFiles(HOST_MANIFESTS), read: (f: string) => string = readText): HostManifests {
  const out: HostManifests = { docs: [], errors: [] };
  const files = hostManifestFiles(tracked);
  if (files.length === 0) out.errors.push(`${HOST_MANIFESTS}에 바로 아래 추적 파일이 없다`);
  for (const f of files) {
    try {
      for (const obj of parseAll(read(f))) {
        if (!obj || typeof obj !== "object" || Array.isArray(obj)) continue;
        out.docs.push({ origin: `host:${f}`, obj });
        // k3s는 타입을 생략한 목록 자식에 목록 kind에서 복원한 타입을 채워 적용한다. 검사는 복원하지 않으므로 그 모양을 거절한다.
        for (const m of listShapeErrors(obj)) out.errors.push(`${f}: ${m}`);
      }
    } catch (e) {
      out.errors.push(`${f}: ${(e as Error).message}`);
    }
  }
  return out;
}
// host: 호스트 매니페스트. null이면 그 몫(읽기 실패, 허용 클래스 선언)을 보지 않는다(같은 입력을 두 번 부를 때 한 번만 보려고).
export function checkOliveIsolation(docs: Doc[], raw: any = readOliveTargets(), host: HostManifests | null = readHostManifests()): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-isolation", where, message });
  if (host) {
    for (const e of host.errors) push("host/k3s-manifests", `호스트 매니페스트를 읽지 못했다: ${e}`);
    // 읽지 못한 문서가 있으면 선언이 없는지 판단할 수 없다. 실패는 위 오류가 이미 낸다.
    if (host.errors.length === 0) for (const cls of OLIVE_PVC_CLASSES.keys()) {
      if (!expand(host.docs).some((d) => d.obj.kind === "StorageClass" && d.obj.metadata?.name === cls)) push(HOST_MANIFESTS, `허용 클래스 ${cls}의 StorageClass 선언이 없다(동적 프로비저닝인지 확인할 수 없다)`);
    }
    docs = [...docs, ...host.docs];
  }
  const targets = targetList(raw);
  const nss = new Set(targets.map((t) => t.namespace).filter((ns) => !Object.hasOwn(ISOLATION_DELEGATED, ns)));
  const inOlive = (d: Doc) => nss.has(nsOf(d) ?? "");
  const coversOlive = (s: any, bindingNs: string | undefined) => {
    // 빈 namespace의 SA 주체는 바인딩의 ns로 풀린다(RBAC authorizer appliesToUser).
    if (s?.kind === "ServiceAccount") return nss.has(s.namespace || bindingNs || "");
    if (s?.kind === "User") return nss.has(String(s.name).match(/^system:serviceaccount:([^:]+):/)?.[1] ?? "");
    if (s?.kind === "Group") {
      const n = String(s.name);
      return n === "system:serviceaccounts" || n === "system:authenticated" || nss.has(n.match(/^system:serviceaccounts:(.+)$/)?.[1] ?? "");
    }
    return false;
  };
  const all = expand(docs);
  const key = (d: Doc, ns: string | undefined, name: unknown) => `${context(d.origin)}|${ns}|${name}`;
  const serviceAccounts = new Map(all.filter((d) => d.obj.kind === "ServiceAccount").map((d) => [key(d, nsOf(d), d.obj.metadata?.name), d]));
  const namespaces = new Map(all.filter((d) => d.obj.kind === "Namespace").map((d) => [key(d, undefined, d.obj.metadata?.name), d]));
  const workloadNs = new Map<string, Doc>();
  let seen = 0;
  for (const d of all) {
    const k = d.obj.kind;
    const where = id(d);
    if (k === "HorizontalPodAutoscaler") {
      const ref = d.obj.spec?.scaleTargetRef ?? {};
      const t = targets.find((x) => x.namespace === nsOf(d) && x.deployment === ref.name);
      if (t && (ref.kind === "Deployment" || !isString(ref.kind))) push(where, `HorizontalPodAutoscaler가 대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})를 조절한다. 켜고 끄기는 관리자 CLI 하나다(D-38)`);
      continue;
    }
    if (k === "Namespace" && nss.has(d.obj.metadata?.name)) {
      if (d.obj.metadata?.labels?.["pod-security.kubernetes.io/enforce"] !== "restricted") push(where, `올리브 네임스페이스 ${d.obj.metadata.name}에 pod-security.kubernetes.io/enforce: restricted가 없다`);
      continue;
    }
    if ((k === "Role" || k === "RoleBinding") && inOlive(d)) {
      push(where, `올리브 네임스페이스 ${nsOf(d)}에 ${k}를 두지 않는다(RBAC 없음, D-37)`);
      continue;
    }
    if ((k === "RoleBinding" || k === "ClusterRoleBinding") && (d.obj.subjects ?? []).some((s: any) => coversOlive(s, nsOf(d)))) {
      push(where, `올리브 SA(또는 그 SA가 드는 그룹)를 묶는 ${k}를 두지 않는다(RBAC 없음, D-37)`);
      continue;
    }
    if (k === "ServiceAccount" && inOlive(d) && d.obj.automountServiceAccountToken !== false) push(where, "ServiceAccount의 automountServiceAccountToken이 false가 아니다");
    if (k === "PersistentVolumeClaim" && inOlive(d)) {
      const spec = d.obj.spec ?? {};
      if (spec.volumeName !== undefined) push(where, `PVC를 정적 PV ${spec.volumeName}에 묶지 않는다(노드 경로를 고를 수 있다)`);
      if (spec.selector !== undefined) push(where, "PVC에 selector를 두지 않는다(동적 프로비저닝 대상이 아니고 조건에 맞는 정적 PV에 묶인다)");
      if (!OLIVE_PVC_CLASSES.has(spec.storageClassName)) push(where, `PVC의 storageClassName ${JSON.stringify(spec.storageClassName)}은 허용 클래스(${[...OLIVE_PVC_CLASSES.keys()].join("·")})가 아니다(없으면 기본 클래스, 빈 값이면 정적 PV)`);
      if (Object.hasOwn(d.obj.metadata?.annotations ?? {}, BETA_CLASS)) push(where, `PVC에 이전 클래스 주석 ${BETA_CLASS}를 두지 않는다(storageClassName보다 먼저 읽힌다)`);
    }
    if (k === "PersistentVolume") {
      const claimNs = d.obj.spec?.claimRef?.namespace;
      if (nss.has(claimNs ?? "")) push(where, `올리브 네임스페이스 ${claimNs}의 PVC에 묶인 정적 PV를 두지 않는다`);
      else if (OLIVE_PVC_CLASSES.has(d.obj.spec?.storageClassName) && claimNs === undefined) push(where, `storageClassName ${d.obj.spec.storageClassName}의 claimRef 없는 정적 PV는 올리브 PVC에 묶일 수 있다`);
      if (claimNs === undefined && Object.hasOwn(d.obj.metadata?.annotations ?? {}, BETA_CLASS)) push(where, `claimRef 없는 정적 PV에 이전 클래스 주석 ${BETA_CLASS}를 두지 않는다(올리브 PVC의 결합 후보가 될 수 있다)`);
    }
    if (k === "StorageClass" && OLIVE_PVC_CLASSES.has(d.obj.metadata?.name)) {
      const want = OLIVE_PVC_CLASSES.get(d.obj.metadata.name);
      if (d.obj.provisioner !== want) push(where, `허용 클래스 ${d.obj.metadata.name}의 provisioner가 ${JSON.stringify(d.obj.provisioner)}다(${want}여야 올리브 PVC가 동적 프로비저닝된다)`);
    }
    if (!WORKLOAD_KINDS.has(k) || !inOlive(d)) continue;
    seen++;
    workloadNs.set(key(d, undefined, nsOf(d)), d);
    const isTarget = k === "Deployment" && targets.some((t) => t.namespace === nsOf(d) && t.deployment === d.obj.metadata?.name);
    if (!isTarget) push(where, `${OLIVE_TARGETS_FILE}의 대상 자료 밖의 워크로드다. 비상 정지가 이 파드를 내리지 못한다(정지 중에도 떠야 하면 실행 네임스페이스 밖에 둔다)`);
    const spec = podSpec(d.obj) ?? {};
    if (spec.automountServiceAccountToken !== false) push(where, "파드의 automountServiceAccountToken이 false가 아니다");
    const saName = spec.serviceAccountName ?? spec.serviceAccount ?? "default";
    if (!serviceAccounts.has(key(d, nsOf(d), saName))) push(where, `파드가 쓰는 ServiceAccount ${saName}이 같은 네임스페이스 ${nsOf(d)}에 렌더되지 않는다(토큰 자동 마운트 값을 확인할 수 없다)`);
    for (const f of ["hostNetwork", "hostPID", "hostIPC"]) if (spec[f] === true) push(where, `${f}를 쓰지 않는다`);
    for (const v of spec.volumes ?? []) {
      const types = Object.keys(v ?? {}).filter((x) => x !== "name");
      if (types.includes("hostPath")) push(where, `hostPath 볼륨 ${v.name}을 쓰지 않는다(호스트 경로·hc 소켓)`);
      else if (types.length !== 1 || !OLIVE_VOLUME_TYPES.has(types[0])) push(where, `볼륨 ${v?.name}의 종류 ${types.join(",")}를 쓰지 않는다(${[...OLIVE_VOLUME_TYPES].join("·")}만)`);
    }
    for (const c of [...(spec.initContainers ?? []), ...(spec.containers ?? []), ...(spec.ephemeralContainers ?? [])]) {
      const cw = `${where} container ${c?.name}`;
      const sc = c?.securityContext ?? {};
      for (const p of c?.ports ?? []) if (p?.hostPort !== undefined && p.hostPort !== 0) push(cw, `hostPort ${p.hostPort}를 쓰지 않는다`);
      if (sc.privileged === true) push(cw, "privileged를 쓰지 않는다");
      if (sc.allowPrivilegeEscalation !== false) push(cw, "allowPrivilegeEscalation: false가 아니다");
      if (!(sc.capabilities?.drop ?? []).includes("ALL")) push(cw, "capabilities.drop에 ALL이 없다");
      const add: unknown[] = sc.capabilities?.add ?? [];
      if (add.length > 0) push(cw, `capability ${add.join(", ")}를 더하지 않는다`);
    }
  }
  for (const [k, d] of workloadNs) {
    const ns = nsOf(d);
    if (!namespaces.has(k)) push(`${d.origin} Namespace/${ns}`, `워크로드가 있는 올리브 네임스페이스 ${ns}의 Namespace가 같은 렌더에 없다(PSA restricted를 확인할 수 없다)`);
  }
  if (seen === 0) push("render", "올리브 네임스페이스에서 검사한 워크로드가 0개다(L40)");
  return out;
}

// 렌더에 꼭 필요한데 실제 배포 값이 아직 비운 키(source path → 점 경로 → 값). 빈 값이면 템플릿의 required가 렌더를 멈춘다.
// render.ts fillEmpty가 Application의 최종 값(차트 values.yaml → valueFiles → valuesObject)이 비었을 때만 채운다. 켜는 PR이 어느 자리에든
// 실제 값을 넣으면 그 값이 남는다. replicas·대상 켜짐(targets.yaml, executors, enabled)에 닿는 키는 두지 않는다.
// 값은 platform/olive/ci/enabled.yaml과 같은 가짜다.
const RENDER_FILL: Record<string, Record<string, string>> = {
  [OLIVE_CHART]: {
    "image.digest": `sha256:${"0".repeat(64)}`,
    "supervisor.account.name": "ci-account",
    "policy.revision": "ci-policy",
    "roleImages.diagnosis.repository": "example.invalid/olive-role-diagnosis",
    "roleImages.diagnosis.digest": `sha256:${"1".repeat(64)}`,
    "roleImages.isolated_reader.repository": "example.invalid/olive-role-isolated-reader",
    "roleImages.isolated_reader.digest": `sha256:${"1".repeat(64)}`,
  },
};
function renderFill(): Record<string, Record<string, unknown>> {
  const out: Record<string, Record<string, unknown>> = {};
  for (const [chart, paths] of Object.entries(RENDER_FILL)) {
    for (const [p, v] of Object.entries(paths)) {
      const parts = p.split(".");
      let node: any = (out[chart] ??= {});
      for (const k of parts.slice(0, -1)) node = node[k] ??= {};
      node[parts[parts.length - 1]] = v;
    }
  }
  return out;
}

// 입력: 대상 차트마다 ci/*.yaml 렌더(호출마다 출처를 남긴다), 지금 root의 전체 렌더(render 단계 캐시), 대상 차트를 켠 root의 전체 렌더.
// root 차트는 components.<디렉터리 이름>.enabled로 켠다. 이름이 다르면 Application이 렌더되지 않아 olive-chart-targets가 실패한다.
let cached: OliveInput | undefined;
export function oliveInput(): OliveInput {
  if (cached) return structuredClone(cached);
  const targets = readOliveTargets();
  const declaring = [...new Set(targetList(targets).map((t) => t.declaredBy))].filter((d) => /^platform\/[a-z0-9-]+$/.test(d) && existsSync(join(ROOT, d, "Chart.yaml")));
  const charts: Record<string, Doc[]> = {};
  const chartRenders: Record<string, string[]> = {};
  for (const dir of declaring) {
    const c = collectChartRenders(dir, gitFiles(`${dir}/ci/*.yaml`), (f) => helmTemplate(basename(dir), dir, `app-${basename(dir)}`, [f]));
    charts[dir] = c.docs;
    chartRenders[dir] = c.origins;
  }
  const real = renderAll();
  const forced = renderAll({ rootOverlay: { components: Object.fromEntries(declaring.map((d) => [basename(d), { enabled: true }])) }, fill: renderFill() });
  // 지금 root의 렌더 실패는 render 단계가 낸다. 켠 렌더에서만 나는 실패(꺼 둔 차트의 실제 값 렌더)는 이 검사의 입력이 없다는 뜻이다.
  const known = new Set(real.violations.map((v) => `${v.where}|${v.message}`));
  const extra = forced.violations.filter((v) => !known.has(`${v.where}|${v.message}`));
  if (extra.length > 0) throw new Error(`대상 차트를 켠 root 렌더 실패: ${extra.map(fmt).join("; ")}`);
  cached = { targets, charts, chartRenders, deployed: { [REAL]: real.docs, [FORCED]: forced.docs }, host: readHostManifests() };
  return structuredClone(cached);
}

// 차트 ci 렌더 수집. 렌더 호출마다 문서 수와 상관없이 출처를 남긴다(문서 0개인 값 파일도 checkChartTargets가 본다).
export function collectChartRenders(dir: string, files: string[], render: (f: string) => { ok: boolean; out: string }): { docs: Doc[]; origins: string[] } {
  const docs: Doc[] = [];
  const origins: string[] = [];
  for (const f of files) {
    const origin = `chart:${relative("platform", dir)}/${relative(dir, f)}`;
    const r = render(f);
    if (!r.ok) throw new Error(`${origin} 렌더 실패: ${r.out.trim()}`);
    origins.push(origin);
    for (const obj of parseAll(r.out)) if (typeof obj === "object" && obj !== null && !Array.isArray(obj)) docs.push({ origin, obj });
  }
  return { docs, origins };
}

// fixture(tools/ci/fixtures/olive/*.yaml). 대조군(FIXTURE_CONTROLS)마다 patch를 얹는다.
// 머리 주석: # expect: fail(# rule:, # match: 메시지 일부) 또는 pass. # also: <규칙,...>은 그 patch가 함께 내는 다른 규칙이고, 대조군마다
// 실제로 한 번 이상 나야 한다(안 나면 그 줄이 낡은 것이다).
// 음성 fixture는 자기 전제(대상의 start·declaredBy, 있어야 하거나 없어야 하는 리소스)를 patch로 직접 만든다. 지금 선언이 우연히 그
// 상태라서 통과하면 정상 전환(O10·O13) 뒤에 fixture가 깨지거나 아무것도 증명하지 않는다.
// patch 한 줄:
//   in: targets(select는 id 등 칸) | chart(chart: 기본 platform/olive. 렌더가 없는 차트는 빈 렌더 목록으로 시작한다)
//     | render(render: root·root+켬, 없으면 둘 다) | apps(Application. render가 없으면 두 렌더 모두) | all(차트 렌더 전부와 두 렌더)
//     | host(호스트 매니페스트)
//   select: targets 밖은 kind·namespace·name·origin(출처 그대로). 고를 것이 없으면 fixture 오류다(drop은 예외).
//   set({점 경로: 값}), unset([점 경로]): 고른 것마다. 점 경로의 숫자는 목록 번호다.
//   remove({목록 경로: {칸: 값}}): 칸이 모두 같은 항목을 지운다. 없어도 된다. append({목록 경로: 값}): 끝에 더한다.
//   edit({목록 경로: {match: {칸: 값}, set: {점 경로: 값}}}): 맞는 항목이 하나 이상이어야 한다.
//   drop(true): 고른 문서를 지운다. 없어도 된다.
//   add(문서): chart는 그 차트의 ci 렌더마다, render는 origin(필수) 출처로, host는 host:<origin> 출처로 더한다.
//     ns는 그 출처 Application의 destination.namespace다.
//   addRender(출처): chart에 문서 0개인 ci 렌더 호출 하나를 더한다.
//   from(렌더 이름): in: render와 render가 필요하다. from 렌더에서 select에 맞는 문서(하나 이상)를 출처·ns 그대로 render에 복사한다.
//     지금 root에 소유 Application·대상이 있는지는 대조군과 클러스터 구성에 따라 다르다. 실제 root를 고치는 음성 사례는 이 클러스터의
//     기존 문서를 drop한 뒤 켠 root(클러스터마다 소유 Application이 하나, 대조군의 patch가 함께 얹힌 것)에서 복사해 전제를 만든다.
type PatchOp = {
  from?: string;
  ns?: string;
  drop?: boolean;
  addRender?: string;
  in?: string;
  chart?: string;
  render?: string;
  select?: Record<string, unknown>;
  set?: Record<string, unknown>;
  unset?: string[];
  remove?: Record<string, Record<string, unknown>>;
  append?: Record<string, unknown>;
  edit?: Record<string, { match?: Record<string, unknown>; set?: Record<string, unknown> }>;
  add?: unknown;
  origin?: string;
};

function header(text: string, key: string): string | undefined {
  return text.match(new RegExp(`^# ${key}: (.+)$`, "m"))?.[1].trim();
}

function getPath(obj: any, path: string): any {
  return path.split(".").reduce((o, k) => o?.[k], obj);
}

function setPath(obj: any, path: string, value: unknown): void {
  const parts = path.split(".");
  let cur = obj;
  for (const p of parts.slice(0, -1)) {
    if (cur[p] === undefined || cur[p] === null) cur[p] = {};
    cur = cur[p];
  }
  cur[parts[parts.length - 1]] = structuredClone(value);
}

function unsetPath(obj: any, path: string): boolean {
  const parts = path.split(".");
  let cur = obj;
  for (const p of parts.slice(0, -1)) {
    cur = cur?.[p];
    if (cur === undefined || cur === null) return false;
  }
  const last = parts[parts.length - 1];
  if (!(last in cur)) return false;
  if (Array.isArray(cur)) cur.splice(Number(last), 1);
  else delete cur[last];
  return true;
}

function docPicked(op: PatchOp, d: Doc): boolean {
  const sel = op.select ?? {};
  return (
    (op.in !== "apps" || (d.obj.kind === "Application" && deployedDoc(d))) &&
    (sel.kind === undefined || d.obj.kind === sel.kind) &&
    (sel.namespace === undefined || nsOf(d) === sel.namespace) &&
    (sel.name === undefined || d.obj.metadata?.name === sel.name) &&
    (sel.origin === undefined || d.origin === sel.origin)
  );
}

const matches = (item: any, fields: Record<string, unknown>) => Object.entries(fields).every(([k, v]) => JSON.stringify(item?.[k]) === JSON.stringify(v));

export function applyPatch(input: OliveInput, ops: PatchOp[]): string | undefined {
  for (const [i, op] of ops.entries()) {
    const sel = op.select ?? {};
    let objs: any[];
    if (op.in === "targets") {
      objs = (input.targets?.targets ?? []).filter((t: any) => Object.entries(sel).every(([k, v]) => t?.[k] === v));
    } else if (["chart", "render", "apps", "all", "host"].includes(op.in ?? "")) {
      const chart = op.chart ?? OLIVE_CHART;
      // 고를 문서가 든 목록들(drop은 이 목록에서 지운다).
      let lists: Doc[][];
      if (op.in === "chart") {
        if (!input.charts[chart]) {
          if (!existsSync(join(ROOT, chart, "Chart.yaml"))) return `patch[${i}]: 차트 ${chart}가 없다`;
          input.charts[chart] = [];
          input.chartRenders[chart] = [];
        }
        if (isString(op.addRender)) {
          input.chartRenders[chart].push(op.addRender);
          continue;
        }
        if (op.add !== undefined) {
          for (const origin of input.chartRenders[chart]) input.charts[chart].push({ origin, obj: structuredClone(op.add) as Record<string, any> });
          continue;
        }
        lists = [input.charts[chart]];
      } else if (op.in === "host") {
        if (op.add !== undefined) {
          input.host.docs.push({ origin: `host:${op.origin ?? "fixture"}`, obj: structuredClone(op.add) as Record<string, any> });
          continue;
        }
        lists = [input.host.docs];
      } else {
        const variants = op.render ? [op.render] : Object.keys(input.deployed);
        if (variants.some((v) => !input.deployed[v])) return `patch[${i}]: 렌더 ${op.render}가 없다(${Object.keys(input.deployed).join("·")})`;
        if (isString(op.from)) {
          if (op.in !== "render" || !op.render || !input.deployed[op.from]) return `patch[${i}]: from은 in: render와 render, 있는 렌더 이름이 필요하다`;
          const found = input.deployed[op.from].filter((d) => docPicked(op, d));
          if (found.length === 0) return `patch[${i}]: from ${op.from}에 select ${JSON.stringify(sel)}에 맞는 문서가 없다`;
          input.deployed[op.render].push(...structuredClone(found));
          continue;
        }
        if (op.add !== undefined) {
          if (op.in !== "render" || !isString(op.origin)) return `patch[${i}]: add는 in: render와 origin이 필요하다`;
          for (const v of variants) input.deployed[v].push({ origin: op.origin, obj: structuredClone(op.add) as Record<string, any>, ns: op.ns });
          continue;
        }
        lists = variants.map((v) => input.deployed[v]);
        if (op.in === "all") lists.push(...Object.values(input.charts));
      }
      const picked = (d: Doc) => docPicked(op, d);
      if (op.drop === true) {
        for (const list of lists) list.splice(0, list.length, ...list.filter((d) => !picked(d)));
        continue;
      }
      objs = lists.flat().filter(picked).map((d) => d.obj);
    } else return `patch[${i}]: in은 targets·chart·render·apps·all·host 중 하나다`;
    if (objs.length === 0) return `patch[${i}]: select ${JSON.stringify(sel)}에 맞는 것이 없다`;
    for (const o of objs) {
      for (const [p, v] of Object.entries(op.set ?? {})) setPath(o, p, v);
      for (const p of op.unset ?? []) if (!unsetPath(o, p)) return `patch[${i}]: 지울 경로 ${p}가 없다`;
      for (const [p, fields] of Object.entries(op.remove ?? {})) {
        const list = getPath(o, p);
        if (Array.isArray(list)) setPath(o, p, list.filter((x) => !matches(x, fields)));
      }
      for (const [p, v] of Object.entries(op.append ?? {})) {
        const list = getPath(o, p);
        if (list !== undefined && !Array.isArray(list)) return `patch[${i}]: ${p}가 목록이 아니다`;
        setPath(o, p, [...(list ?? []), v]);
      }
      for (const [p, e] of Object.entries(op.edit ?? {})) {
        const list = getPath(o, p);
        const hit = Array.isArray(list) ? list.filter((x) => matches(x, e.match ?? {})) : [];
        if (hit.length === 0) return `patch[${i}]: ${p}에 ${JSON.stringify(e.match)}에 맞는 항목이 없다`;
        for (const x of hit) for (const [q, v] of Object.entries(e.set ?? {})) setPath(x, q, v);
      }
    }
  }
  return undefined;
}

// render 단계는 지금 root 전체 렌더(차트 ci 렌더 포함)에 checkOliveIsolation을 건다. 여기서는 대상 차트 ci 렌더로 그 몫을 대신한다.
// 호스트 매니페스트의 몫은 checkOliveTargets 안의 호출이 한 번 본다.
export const allChecks = (input: OliveInput) => [...checkOliveTargets(input), ...checkOliveIsolation(Object.values(input.charts).flat(), input.targets, null)];

// 대조군. "지금"은 patch 없는 입력(이 PR의 sandbox CI 값 포함), 나머지는 정상 전환을 그린 양성 fixture를 얹은 입력이다.
// fixture 묶음 전체가 대조군마다 같은 결과여야 한다. 한 대조군에서만 맞는 음성 fixture는 정상 전환 PR을 막거나 그 뒤 아무것도 증명하지 않는다.
const FIXTURE_DIR = "tools/ci/fixtures/olive";
const FIXTURE_CONTROLS: Record<string, string> = { O13: `${FIXTURE_DIR}/writer-start-o13.yaml`, O10: `${FIXTURE_DIR}/session-o10.yaml` };
// 대조군 이름을 따로 적는다. FIXTURE_CONTROLS에서 항목을 빼도 끝의 규칙별 음성 사례 검사는 초록으로 남으므로, 실제로 돈 대조군이 이 목록과
// 같아야 한다. 대조군을 바꾸는 PR은 두 곳을 함께 고친다.
const EXPECTED_CONTROLS = ["지금", "O13", "O10"];

type Fixture = { file: string; expect: string; rule?: string; match?: string; also: Set<string>; ops: PatchOp[] };
function readFixture(f: string): Fixture | string {
  const text = readText(f);
  const expect = header(text, "expect") ?? "";
  const rule = header(text, "rule");
  const match = header(text, "match");
  const also = new Set((header(text, "also") ?? "").split(",").map((s) => s.trim()).filter(Boolean));
  const ops = (Bun.YAML.parse(text) as any)?.patch;
  const okHeader = expect === "pass" ? !rule && !match && also.size === 0 : expect === "fail" && !!rule && !!match && !also.has(rule);
  if (!okHeader || !Array.isArray(ops) || ops.length === 0 || [...also].some((r) => !OLIVE_RULES.includes(r))) {
    return "머리 주석 # expect: fail(# rule:, # match: 메시지 일부, 필요하면 # also: 다른 규칙) 또는 # expect: pass와 patch 목록이 필요하다";
  }
  return { file: f, expect, rule, match, also, ops };
}

// 렌더 경로의 작은 시험. fixture는 렌더가 끝난 입력에 patch를 얹으므로 렌더 쪽 판단(목록 안 Application, 보충값 우선순위, 0문서 출처)을
// 보지 못한다. 그 함수를 직접 부른다.
function renderSelfTests(): string[] {
  const bad: string[] = [];
  const list = Bun.YAML.parse("apiVersion: v1\nkind: List\nitems:\n  - {apiVersion: argoproj.io/v1alpha1, kind: Application, metadata: {name: child}}\n  - {kind: ConfigMapList, items: [{kind: ApplicationSet, metadata: {name: nested}}]}\n");
  if (JSON.stringify(listedArgoApps(list)) !== JSON.stringify(["Application/child", "ApplicationSet/nested"])) bad.push(`listedArgoApps가 목록 안 Application을 찾지 못했다: ${JSON.stringify(listedArgoApps(list))}`);
  if (listedArgoApps({ kind: "Application", metadata: { name: "top" } }).length !== 0) bad.push("listedArgoApps가 최상위 Application을 목록 항목으로 봤다");
  const fill = { image: { digest: "fill" } };
  const digest = (layers: unknown[], vo: any) => (fillEmpty(layers, vo, fill) as any)?.image?.digest;
  const cases: [string, unknown[], any, unknown][] = [
    ["값 파일의 정상 값이 남는다", [{ image: { digest: "" } }, { image: { digest: "sha256:real" } }], undefined, undefined],
    ["valuesObject의 정상 값이 남는다", [{ image: { digest: "" } }], { image: { digest: "sha256:real" } }, "sha256:real"],
    ["valuesObject의 빈 문자열은 채운다", [{ image: { digest: "sha256:real" } }], { image: { digest: "" } }, "fill"],
    ["모두 비면 채운다", [{ image: { digest: "" } }, undefined], { other: 1 }, "fill"],
  ];
  for (const [name, layers, vo, want] of cases) if (digest(layers, vo) !== want) bad.push(`fillEmpty(${name}): ${JSON.stringify(digest(layers, vo))}, 기대 ${JSON.stringify(want)}`);
  const c = collectChartRenders("platform/x", ["platform/x/ci/a.yaml", "platform/x/ci/empty.yaml"], (f) => ({ ok: true, out: f.endsWith("a.yaml") ? "kind: ConfigMap\n" : "" }));
  if (JSON.stringify(c.origins) !== JSON.stringify(["chart:x/ci/a.yaml", "chart:x/ci/empty.yaml"]) || c.docs.length !== 1) bad.push(`collectChartRenders가 문서 0개인 렌더의 출처를 남기지 않았다: ${JSON.stringify(c.origins)}`);
  bad.push(...listedAppTests(), ...multiDocValuesTest(), ...hostScopeTest(), ...executorTlsPathTest(), ...policyRevisionRenderTest());
  return bad;
}

// pki를 끄고 실행기 TLS Secret을 직접 줄 때 그 경로가 제어의 다른 마운트와 겹치면 렌더가 멈춘다(templates/_helpers.tpl olive.executorTlsPath).
// fixture는 렌더가 끝난 문서를 고치므로 값 → 렌더 실패는 여기서만 본다. 겹치지 않는 경로는 렌더된다(막는 범위가 넓지 않다).
// 신뢰 묶음 /run/olive/trust는 그 마운트가 생길 때(pki를 켜고 묶음을 줄 때)만 겹침 대상이다. pki를 켜면 스키마가 TLS 경로를
// /run/olive/tls로 고정해 그 겹침은 렌더 전에 막힌다.
function executorTlsPathTest(): string[] {
  const dir = tempDir("olive-tls-path");
  const values = (path: string) => {
    const f = join(dir, `${path.replaceAll("/", "_")}.yaml`);
    writeFileSync(f, `pki:\n  enabled: false\nexecutors:\n  reader:\n    tls:\n      secretName: ci-example\n      mountPath: ${path}\n`);
    return helmTemplate("olive", OLIVE_CHART, "app-olive", [`${OLIVE_CHART}/ci/enabled.yaml`, f]);
  };
  const bad: string[] = [];
  for (const [path, overlaps] of [["/run/olive/agent", "/run/olive/agent"], ["/run/olive", "/run/olive/agent"], ["/run/olive/agent/tls", "/run/olive/agent"], ["/run/olive/effect-signing/tls", EFFECT_KEY_DIR]]) {
    const r = values(path);
    if (r.ok || !r.out.includes(`executors.reader.tls.mountPath ${path} overlaps the executor pod mount ${overlaps}`)) bad.push(`실행기 TLS 경로 ${path}가 ${overlaps}와 겹치는데 렌더가 그 이유로 멈추지 않았다: ${r.ok ? "렌더 성공" : r.out.trim()}`);
  }
  for (const path of ["/run/olive/ext-tls", "/run/olive/trust/client"]) {
    const ok = values(path);
    if (!ok.ok) bad.push(`pki를 끈 실행기 TLS 경로 ${path}는 실제 마운트와 겹치지 않는데 렌더되지 않았다: ${ok.out.trim()}`);
  }
  return bad;
}

// 정책 판 번호(D-108)가 비면 렌더가 멈추고(templates/_helpers.tpl olive.policyRevision), 계약 v1 꼴이 아니면 스키마가 거절한다.
// fixture는 렌더가 끝난 문서를 고치므로 값 → 렌더 실패는 여기서만 본다. 꼴이 맞는 값은 렌더된다(막는 범위가 넓지 않다).
function policyRevisionRenderTest(): string[] {
  const dir = tempDir("olive-policy");
  const render = (name: string, revision: string) => {
    const f = join(dir, `${name}.yaml`);
    writeFileSync(f, `policy:\n  revision: ${JSON.stringify(revision)}\n`);
    return helmTemplate("olive", OLIVE_CHART, "app-olive", [`${OLIVE_CHART}/ci/enabled.yaml`, f]);
  };
  const bad: string[] = [];
  const empty = render("empty", "");
  if (empty.ok || !empty.out.includes("policy.revision is required")) bad.push(`policy.revision이 빈 값인데 렌더가 그 이유로 멈추지 않았다: ${empty.ok ? "렌더 성공" : empty.out.trim()}`);
  for (const [name, v] of [["dash", "-lead"], ["long", "a".repeat(65)], ["space", "a b"]]) {
    const r = render(name, v);
    if (r.ok || !/policy\.revision|\/policy\/revision/.test(r.out)) bad.push(`policy.revision ${JSON.stringify(v)}는 계약 v1 꼴이 아닌데 스키마가 그 자리로 거절하지 않았다: ${r.ok ? "렌더 성공" : r.out.trim()}`);
  }
  // 렌더 성공만 보면 helper가 입력을 버리고 고정 값을 내도 통과한다. 감독·두 실행기 env가 입력 문자열 그대로인지 본다.
  // ci/enabled.yaml의 값(ci-policy)과 다른 값이어야 그 고정을 가려낸다.
  const want = "2026-11-24.1_a";
  const ok = render("ok", want);
  if (!ok.ok) bad.push(`policy.revision ${JSON.stringify(want)}는 꼴이 맞는데 렌더되지 않았다: ${ok.out.trim()}`);
  else {
    const docs = parseAll(ok.out);
    for (const t of targetList(readOliveTargets()).filter((x) => x.declaredBy === OLIVE_CHART && OLIVE_KINDS.has(x.kind))) {
      const name = t.kind === "supervisor" ? SUPERVISOR_CONTAINER : EXECUTOR_CONTAINER;
      const deps = docs.filter((d) => d?.kind === "Deployment" && d.metadata?.namespace === t.namespace && d.metadata?.name === t.deployment);
      const c = deps.length === 1 ? (podSpec(deps[0])?.containers ?? []).find((x: any) => x?.name === name) : undefined;
      const got = envOf(c, "OLIVE_POLICY_REVISION");
      if (plainOne(got) !== want) bad.push(`policy.revision ${JSON.stringify(want)}로 렌더한 대상 ${t.id}(${t.namespace}/${t.deployment} container ${name})의 OLIVE_POLICY_REVISION이 입력 그대로가 아니다(Deployment ${deps.length}개, env ${envValues(got)})`);
    }
  }
  return bad;
}

// 목록 안 Application은 모든 렌더가 지나는 parseRendered가 거절한다. root 차트 출력(Application source 렌더)과 root 파일 자체 둘 다.
// root 파일은 실제 renderAll에 내용을 바꿔 넣어 본다(root 파일은 visit을 거치지 않고 add만 지난다).
const LISTED_APP = "---\napiVersion: v1\nkind: List\nitems:\n  - {apiVersion: argoproj.io/v1alpha1, kind: Application, metadata: {name: child}}\n";
function listedAppTests(): string[] {
  const bad: string[] = [];
  const hit = (vs: Violation[], where: string) => vs.some((v) => v.rule === "render" && v.where === where && v.message.includes("목록(items) 안의 Application/child"));
  const out = parseRendered("root-prod[prod]:platform/root", `apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: adguard}\n${LISTED_APP}`, "argocd");
  if (out.docs.length !== 2 || !hit(out.violations, "root-prod[prod]:platform/root")) bad.push(`parseRendered가 root 차트 출력의 목록 안 Application을 거절하지 않았다: ${out.violations.map(fmt).join("; ") || "없음"}`);
  const rf = gitFiles("platform/root/root-*.yaml")[0];
  if (!rf) return [...bad, "root 파일(platform/root/root-*.yaml)이 없다"];
  const r = renderAll({ rootText: { [rf]: `${readText(rf)}\n${LISTED_APP}` } });
  if (!hit(r.violations, rf)) bad.push(`renderAll이 root 파일 ${rf} 자체의 목록 안 Application을 거절하지 않았다: ${r.violations.map(fmt).join("; ") || "없음"}`);
  return bad;
}

// 다중 문서 값 파일(Helm은 문서별로 읽어 뒤 문서가 덮는다). 첫 문서는 platform/olive/ci/enabled.yaml, 둘째 문서는 정상 digest다
// (올리브 이미지와 역할 이미지 둘 다. 최상위 키 단위로 덮이므로 역할 이미지는 repository까지 다시 적는다).
// 보충값을 거친 렌더의 Deployment 이미지가 Helm 단독 렌더와 같아야 한다(보충값이 정상 digest를 시험값으로 덮지 않는다).
function multiDocValuesTest(): string[] {
  const real = `sha256:${"7".repeat(64)}`;
  const dir = tempDir("olive-values");
  const vf = join(dir, "multi.yaml");
  const roles = ["diagnosis", "isolated_reader"].map((r) => `  ${r}:\n    repository: example.invalid/olive-role-${r.replace("_", "-")}\n    digest: ${real}\n`).join("");
  writeFileSync(vf, `${readText(`${OLIVE_CHART}/ci/enabled.yaml`)}\n---\nimage:\n  digest: ${real}\nroleImages:\n${roles}`);
  const images = (r: { ok: boolean; out: string }) =>
    r.ok ? parseAll(r.out).filter((d) => d?.kind === "Deployment").flatMap((d) => (podSpec(d)?.containers ?? []).map((c: any) => String(c.image))).sort() : [`렌더 실패: ${r.out.trim()}`];
  const helmOnly = images(helmTemplate("olive", OLIVE_CHART, "app-olive", [vf]));
  const vo = filledValuesObject(OLIVE_CHART, [vf], undefined, renderFill()[OLIVE_CHART]);
  const files = [vf];
  if (vo) {
    files.push(join(dir, "values.json"));
    writeFileSync(files[1], JSON.stringify(vo));
  }
  const filled = images(helmTemplate("olive", OLIVE_CHART, "app-olive", files));
  if (helmOnly.length === 0 || !helmOnly.every((i) => i.endsWith(`@${real}`)) || JSON.stringify(filled) !== JSON.stringify(helmOnly)) {
    return [`다중 문서 값 파일: 보충값 렌더 이미지 ${JSON.stringify(filled)}가 Helm 단독 ${JSON.stringify(helmOnly)}와 다르다(기대 digest ${real})`];
  }
  return [];
}

// 호스트 매니페스트는 install.sh와 같이 바로 아래의 숨김 아닌 .yaml만 읽는다. 허용 클래스가 하위 디렉터리나 숨김 파일에만 있으면 실패다.
function hostScopeTest(): string[] {
  const sc = "apiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata: {name: local-retain}\nprovisioner: rancher.io/local-path\n";
  const tracked = [`${HOST_MANIFEST_DIR}/examples/local-retain.yaml`, `${HOST_MANIFEST_DIR}/.local-retain.yaml`, `${HOST_MANIFEST_DIR}/other.yaml`];
  const host = readHostManifests(tracked, (f) => (f.endsWith("/other.yaml") ? "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x, namespace: kube-system}\n" : sc));
  const bad: string[] = [];
  if (JSON.stringify(host.docs.map((d) => d.origin)) !== JSON.stringify([`host:${HOST_MANIFEST_DIR}/other.yaml`])) bad.push(`readHostManifests가 바로 아래가 아닌 파일을 읽었다: ${JSON.stringify(host.docs.map((d) => d.origin))}`);
  if (!checkOliveIsolation([], readOliveTargets(), host).some((v) => v.message.includes("허용 클래스 local-retain의 StorageClass 선언이 없다"))) bad.push("허용 클래스가 하위 디렉터리·숨김 파일에만 있는데 olive-isolation이 실패하지 않았다");
  return bad;
}

// 목록 모양의 거절(render.ts listShapeErrors)이 렌더·호스트 입력 양쪽에 걸리는지. 리뷰의 입력을 그대로 쓴다.
// 타입을 생략한 자식은 "선언이 없다"가 아니라 거절 메시지로 실패해야 한다(복원하지 않는다는 것이 보이게).
const UNTYPED_SC = "apiVersion: storage.k8s.io/v1\nkind: StorageClassList\nitems:\n  - metadata: {name: local-retain}\n    provisioner: rancher.io/local-path\n    reclaimPolicy: Retain\n    volumeBindingMode: WaitForFirstConsumer\n";
const UNTYPED_PV = "apiVersion: v1\nkind: PersistentVolumeList\nitems:\n  - metadata: {name: stray}\n    spec: {capacity: {storage: 1Gi}, accessModes: [ReadWriteOnce], storageClassName: local-retain, hostPath: {path: /var/lib/stray}}\n";
const TYPED_SC = "apiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata: {name: local-retain}\nprovisioner: rancher.io/local-path\n";
function listShapeTests(base: OliveInput): string[] {
  const bad: string[] = [];
  const untyped = "에 apiVersion·kind가 없다";
  const nested = "가 다시 목록이다";
  const hosts: [string, Record<string, string>][] = [
    ["타입을 생략한 StorageClassList", { "sc.yaml": UNTYPED_SC }],
    ["타입을 생략한 PersistentVolumeList", { "local-retain.yaml": TYPED_SC, "stray-pv.yaml": UNTYPED_PV }],
  ];
  for (const [name, files] of hosts) {
    const host = readHostManifests(Object.keys(files).map((f) => `${HOST_MANIFEST_DIR}/${f}`), (f) => files[basename(f)]);
    const got = checkOliveIsolation([], readOliveTargets(), host).filter((v) => v.where.startsWith(HOST_MANIFEST_DIR));
    if (!got.some((v) => v.rule === "olive-isolation" && v.message.includes(untyped)) || got.some((v) => v.message.includes("StorageClass 선언이 없다"))) {
      bad.push(`호스트 ${name}가 목록 모양 거절로 실패하지 않았다: ${got.map(fmt).join("; ") || "없음"}`);
    }
    for (const text of Object.values(files)) {
      if (!text.includes("List\n")) continue;
      const r = parseRendered("fixture[vm]:platform/x", text, "x");
      if (!r.violations.some((v) => v.rule === "render" && v.message.includes(untyped))) bad.push(`렌더 ${name}를 parseRendered가 거절하지 않았다`);
    }
  }
  // 목록 안의 목록: 켠 root 렌더에서 olive-diagnosis의 Namespace를 List → NamespaceList 안에만 둔다. Argo CD가 배포하는 것은
  // NamespaceList 하나이므로 거절돼야 하고, 거절이 없어도 격리 검사가 Namespace를 손자에서 찾아 조용히 통과하면 안 된다.
  const docs = structuredClone(base.deployed[FORCED] ?? []);
  const wrapped = docs.filter((d) => d.obj.kind === "Namespace" && d.obj.metadata?.name === "olive-diagnosis");
  if (wrapped.length === 0) return [...bad, `${FORCED} 렌더에 olive-diagnosis Namespace가 없다`];
  for (const d of wrapped) d.obj = { apiVersion: "v1", kind: "List", items: [{ apiVersion: "v1", kind: "NamespaceList", items: [d.obj] }] };
  const r = parseRendered(wrapped[0].origin, JSON.stringify(wrapped[0].obj), wrapped[0].ns);
  if (!r.violations.some((v) => v.rule === "render" && v.message.includes(nested))) bad.push(`List → NamespaceList → Namespace를 parseRendered가 거절하지 않았다: ${r.violations.map(fmt).join("; ") || "없음"}`);
  if (!checkOliveIsolation(docs, base.targets, null).some((v) => v.message.includes("olive-diagnosis의 Namespace가 같은 렌더에 없다"))) bad.push("Namespace가 목록 안의 목록에만 있는데 격리 검사가 손자를 배포된 것으로 셌다");
  const host = readHostManifests([`${HOST_MANIFEST_DIR}/nested.yaml`, `${HOST_MANIFEST_DIR}/local-retain.yaml`], (f) => (f.endsWith("nested.yaml") ? `apiVersion: v1\nkind: List\nitems:\n  - ${JSON.stringify(wrapped[0].obj.items[0])}\n` : TYPED_SC));
  if (!host.errors.some((e) => e.includes(nested))) bad.push(`호스트의 목록 안의 목록을 거절하지 않았다: ${JSON.stringify(host.errors)}`);
  return bad;
}

// 원인이 둘 이상인 키 검사 사례(fixture는 위반 하나여야 해서 여기서 본다). 위반 목록이 기대와 개수까지 같아야 한다.
// 켠 값에서 ExternalSecret 생성이 모두 빠져도 store 검사가 남는지, 복구 스위치를 끈 클러스터 렌더가 이 차트 store·ES 0개를 요구하고
// 다른 출처의 store는 계속 보는지, 실제 차트를 끈 값으로 렌더한 출력이 통과하는지.
const EXTRA_STORE = { apiVersion: "external-secrets.io/v1", kind: "ClusterSecretStore", metadata: { name: "ci-extra" }, spec: { conditions: [{ namespaces: ["olive-reader"] }], provider: { fake: { data: [{ key: "PUBLIC_MARKER", value: "public" }] } } } };
function executorKeyTests(base: OliveInput): string[] {
  const bad: string[] = [];
  const executors = targetList(base.targets).filter((t) => t.kind === "executor" && t.declaredBy === OLIVE_CHART);
  const noEs = executors.map((t) => `대상 ${t.id}의 ns ${t.namespace}에 효과 서명 키 ExternalSecret(target ${EFFECT_KEY_SECRET})이 정확히 하나가 아니다(0개)`);
  const dropEs: PatchOp[] = [{ in: "chart", select: { kind: "ExternalSecret" }, drop: true }];
  const extraOpen = "store ci-extra가 실행기 ns olive-reader에 열려 있다";
  // 복구 스위치를 끈 클러스터(vm): root가 넘기는 값처럼 olive Application valuesObject에 externalSecrets.enabled=false를 넣는다.
  const switchOff = (input: OliveInput, dropOwned: boolean) => {
    const docs = input.deployed[FORCED];
    const vm = (d: Doc) => sourceOf(d.origin).cluster === "vm";
    const apps = argoApps(docs.filter(vm)).filter((a) => effectiveSources(a.obj.spec).some((s) => s?.path === OLIVE_CHART));
    for (const a of apps) setPath(a.obj, "spec.source.helm.valuesObject.externalSecrets", { enabled: false });
    if (dropOwned) input.deployed[FORCED] = docs.filter((d) => !(vm(d) && sourceOf(d.origin).path === OLIVE_CHART && ["ClusterSecretStore", "ExternalSecret"].includes(d.obj.kind)));
    return apps.length;
  };
  const addVm = (input: OliveInput) => input.deployed[FORCED].push({ origin: "external-secrets-stores[vm]:platform/external-secrets", obj: structuredClone(EXTRA_STORE) });
  const cases: [string, PatchOp[], ((i: OliveInput) => unknown) | undefined, string[]][] = [
    ["켠 값에서 ExternalSecret이 0개", dropEs, undefined, noEs],
    ["켠 값에서 ExternalSecret이 0개 + 실행기 ns에 열린 store", [...dropEs, { in: "chart", add: EXTRA_STORE }], undefined, [...noEs, extraOpen]],
    [
      "켠 값에서 ExternalSecret이 0개 + 전용 store 폴더가 하위 폴더",
      [...dropEs, { in: "chart", select: { kind: "ClusterSecretStore", name: "infisical-olive-executor-reader" }, set: { "spec.provider.infisical.secretsScope.secretsPath": "/olive/executors/reader/ci" } }],
      undefined,
      [...noEs, `store infisical-olive-executor-reader의 secretsPath("/olive/executors/reader/ci")가 /olive/executors/reader가 아니다`],
    ],
    ["끈 값(vm)인데 이 차트 store·ES가 남음", [], (i) => switchOff(i, false), ["복구 스위치(externalSecrets.enabled)를 끈 렌더에 이 차트의 store·ExternalSecret이"]],
    ["끈 값(vm)의 정상 렌더", [], (i) => switchOff(i, true), []],
    ["끈 값(vm) + 다른 차트 store가 실행기 ns에 열림", [], (i) => (addVm(i), switchOff(i, true)), [`${extraOpen}(conditions namespaces에 olive-reader가 있다). 실행기 ns에 열린 store는 없다(복구 스위치 끔)`]],
  ];
  for (const [name, ops, prep, want] of cases) {
    const input = flatInput(base);
    const err = applyPatch(input, ops);
    if (err) {
      bad.push(`${name}: ${err}`);
      continue;
    }
    if (prep && prep(input) === 0) {
      bad.push(`${name}: ${FORCED} 렌더의 vm 클러스터에 olive Application이 없다`);
      continue;
    }
    const got = allChecks(input);
    const unmatched = got.filter((v) => !(v.rule === "olive-executor-key" && want.some((w) => v.message.includes(w))));
    const counts = want.map((w) => got.filter((v) => v.message.includes(w)).length);
    if (unmatched.length > 0 || counts.some((n) => n !== 1) || got.length !== want.length) {
      bad.push(`${name}: 기대한 위반 ${want.length}개(각 1번)와 다르다. 걸린 것: ${got.map(fmt).join("; ") || "없음"}`);
    }
  }
  // 실제 차트를 복구 스위치 끈 값으로 렌더한 출력. 이 차트 store·ES가 0개라 위반이 없어야 한다.
  const dir = tempDir("olive-key-off");
  const off = join(dir, "off.yaml");
  writeFileSync(off, "externalSecrets:\n  enabled: false\n");
  const r = helmTemplate("olive", OLIVE_CHART, "app-olive", [`${OLIVE_CHART}/ci/enabled.yaml`, off]);
  const enabled = switchOn([...valueLayers(`${OLIVE_CHART}/values.yaml`), ...valueLayers(`${OLIVE_CHART}/ci/enabled.yaml`), { externalSecrets: { enabled: false } }]);
  if (!r.ok) bad.push(`복구 스위치 끈 값 렌더 실패: ${r.out.trim()}`);
  else {
    const unit = { where: "chart:olive/ci/enabled.yaml+off", docs: parseAll(r.out).map((obj) => ({ origin: "chart:olive/ci/enabled.yaml+off", obj })), owned: () => true, enabled };
    const sup = targetList(base.targets).find((t) => t.kind === "supervisor" && t.declaredBy === OLIVE_CHART);
    const got = executorKeyViolations(unit, executors, sup);
    if (enabled || got.length > 0) bad.push(`복구 스위치 끈 값 렌더(스위치 ${enabled ? "켬" : "끔"}으로 읽음)가 통과하지 않았다: ${got.map(fmt).join("; ") || "없음"}`);
  }
  return bad;
}

// 대조군과 fixture는 정책이 보는 모양(한 겹 목록을 편 문서, 출처·destination 유지)의 기존 입력에서 문서를 고른다(select·drop·from).
// 원본 모양 그대로면 다른 차트가 DeploymentList로 낸 세션을 O10 대조군이 지우지 못해 정상 전환이 소유 충돌로 깨진다.
// fixture가 새로 넣는 목록은 펴지 않고 정책에 넘긴다(목록 전개의 회귀를 그 사례가 잡는다).
function flatInput(input: OliveInput): OliveInput {
  const out = structuredClone(input);
  for (const k of Object.keys(out.charts)) out.charts[k] = expand(out.charts[k]);
  for (const k of Object.keys(out.deployed)) out.deployed[k] = expand(out.deployed[k]);
  out.host.docs = expand(out.host.docs);
  return out;
}

function buildControls(base: OliveInput, fixtures: Fixture[]): { controls: [string, OliveInput][]; errors: Violation[] } {
  const flat = flatInput(base);
  const controls: [string, OliveInput][] = [["지금", flat]];
  const errors: Violation[] = [];
  for (const [name, f] of Object.entries(FIXTURE_CONTROLS)) {
    const fx = fixtures.find((x) => x.file === f);
    if (!fx || fx.expect !== "pass") {
      errors.push({ rule: "fixture", where: f, message: `대조군 ${name}의 양성 fixture가 없다` });
      continue;
    }
    const input = structuredClone(flat);
    const err = applyPatch(input, fx.ops);
    if (err) errors.push({ rule: "fixture", where: f, message: `대조군 ${name}: ${err}` });
    else controls.push([name, input]);
  }
  return { controls, errors };
}

// 다른 차트(platform/adguard)가 세션을 DeploymentList의 자식으로 이미 낸 입력. O10 대조군의 정리가 목록 안의 세션도 지워야
// 대조군 셋이 모두 통과한다. 그 입력은 O10 양성 fixture의 patch에서 차트 이름을 바꾸고 Deployment를 목록으로 감싸 만든다.
function listedSessionTest(base: OliveInput, fixtures: Fixture[]): string[] {
  const o10 = fixtures.find((x) => x.file === FIXTURE_CONTROLS.O10);
  if (!o10) return ["O10 양성 fixture가 없다"];
  const names = new Map([
    ["platform/go", "platform/adguard"],
    ["chart:go/ci/o10.yaml", "chart:adguard/ci/o10.yaml"],
    ["go[prod]:platform/go", "adguard[prod]:platform/adguard"],
    ["go[vm]:platform/go", "adguard[vm]:platform/adguard"],
    ["go", "adguard"],
  ]);
  const swap = (v: any): any =>
    typeof v === "string" ? (names.get(v) ?? v) : Array.isArray(v) ? v.map(swap) : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, swap(x)])) : v;
  const ops: PatchOp[] = swap(o10.ops).map((op: PatchOp) => ((op.add as any)?.kind === "Deployment" ? { ...op, add: { apiVersion: "apps/v1", kind: "DeploymentList", items: [op.add] } } : op));
  const input = structuredClone(base);
  const err = applyPatch(input, ops);
  if (err) return [`세션을 DeploymentList로 낸 입력을 만들지 못했다: ${err}`];
  if (!input.deployed[REAL].some((d) => d.obj.kind === "DeploymentList" && d.origin.startsWith("adguard["))) return ["세션을 DeploymentList로 낸 입력에 목록이 없다"];
  const { controls, errors } = buildControls(input, fixtures);
  const bad = errors.map(fmt);
  if (JSON.stringify(controls.map(([n]) => n)) !== JSON.stringify(EXPECTED_CONTROLS)) bad.push(`대조군이 ${controls.map(([n]) => n).join("·")}다`);
  for (const [name, c] of controls) {
    const hits = allChecks(c);
    if (hits.length > 0) bad.push(`대조군 ${name}가 걸렸다: ${hits.map(fmt).join("; ")}`);
  }
  return bad;
}

export function checkOliveFixtures(base: OliveInput): Violation[] {
  const out: Violation[] = [];
  for (const m of renderSelfTests()) out.push({ rule: "fixture", where: "tools/ci/olive.ts renderSelfTests", message: m });
  for (const m of listShapeTests(base)) out.push({ rule: "fixture", where: "tools/ci/olive.ts listShapeTests", message: m });
  for (const m of executorKeyTests(base)) out.push({ rule: "fixture", where: "tools/ci/olive.ts executorKeyTests", message: m });
  const files = gitFiles(`${FIXTURE_DIR}/*.yaml`);
  const fixtures: Fixture[] = [];
  for (const f of files) {
    const fx = readFixture(f);
    if (typeof fx === "string") out.push({ rule: "fixture", where: f, message: fx });
    else fixtures.push(fx);
  }
  for (const m of listedSessionTest(base, fixtures)) out.push({ rule: "fixture", where: "tools/ci/olive.ts listedSessionTest", message: m });
  const { controls, errors } = buildControls(base, fixtures);
  out.push(...errors);
  const ran = controls.map(([n]) => n);
  if (JSON.stringify(ran) !== JSON.stringify(EXPECTED_CONTROLS)) out.push({ rule: "fixture", where: FIXTURE_DIR, message: `대조군이 ${EXPECTED_CONTROLS.length}개(${EXPECTED_CONTROLS.join("·")})가 아니다: ${ran.join("·")}` });
  const covered = new Set<string>();
  for (const [name, control] of controls) {
    const where = (f: string) => `${f} (대조군 ${name})`;
    const hits = allChecks(control);
    if (hits.length > 0) out.push({ rule: "fixture", where: `${FIXTURE_DIR} (대조군 ${name})`, message: `대조군이 걸렸다: ${hits.map(fmt).join("; ")}` });
    for (const fx of fixtures) {
      const input = structuredClone(control);
      const err = applyPatch(input, fx.ops);
      if (err) {
        out.push({ rule: "fixture", where: where(fx.file), message: err });
        continue;
      }
      const got = allChecks(input);
      if (fx.expect === "pass") {
        if (got.length > 0) out.push({ rule: "fixture", where: where(fx.file), message: `양성 fixture가 걸렸다: ${got.map(fmt).join("; ")}` });
        continue;
      }
      covered.add(fx.rule!);
      if (!got.some((v) => v.rule === fx.rule && v.message.includes(fx.match!))) out.push({ rule: "fixture", where: where(fx.file), message: `${fx.rule}(${fx.match})가 걸리지 않았다(걸린 것: ${got.map(fmt).join("; ") || "없음"})` });
      // 모든 위반이 기대한 규칙·메시지(또는 # also의 규칙)여야 한다. 다른 위반이 섞이면 대상 검사가 사라져도 fixture가 초록으로 남는다.
      const other = got.filter((v) => (v.rule !== fx.rule || !v.message.includes(fx.match!)) && !fx.also.has(v.rule));
      if (other.length > 0) out.push({ rule: "fixture", where: where(fx.file), message: `기대하지 않은 위반: ${other.map(fmt).join("; ")}` });
      for (const r of fx.also) if (!got.some((v) => v.rule === r)) out.push({ rule: "fixture", where: where(fx.file), message: `# also의 ${r}가 걸리지 않았다(낡은 줄이면 지운다)` });
    }
  }
  for (const r of OLIVE_RULES) if (!covered.has(r)) out.push({ rule: "fixture", where: FIXTURE_DIR, message: `규칙 ${r}의 음성 fixture가 없다` });
  console.log(`olive fixture ${files.length}개 × 대조군 ${controls.length}개(${controls.map(([n]) => n).join("·")})`);
  return out;
}
