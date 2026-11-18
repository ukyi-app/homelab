// 올리브 실행 대상 검사(D-38·D-39, docs/plans/2026-11-13-olive/supervisor.md §1.1·§7.1·§7.2, AC-29).
// 비상 정지는 실행 대상 목록 하나(platform/olive/targets.yaml)를 믿는다. 차트가 만드는 Deployment, Argo CD 예외(ignoreDifferences),
// CLI가 내리고 올리는 대상이 이 목록과 어긋나면 정지가 덮지 못하는 파드가 생긴다. 규칙 이름은 OLIVE_RULES, 각 함수 머리 주석이 이유다.
// 구성 요소를 root에서 꺼 둬도 돈다. 차트의 ci/*.yaml 렌더와, 대상 차트를 켠 root의 실제 Application 값 렌더를 함께 본다.
// CLI의 올리브 명령은 아직 없다. 생기면 대상을 이 파일에서 읽어야 하고, 손으로 적은 목록을 두면 이 검사가 그 목록을 보지 못한다.
import { existsSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { type Doc, type Violation, ROOT, effectiveSources, fmt, gitFiles, parseAll, readText, sameRepo } from "./lib";
import { WORKLOAD_KINDS, context, expand, id, podSpec } from "./policy";
import { helmTemplate, renderAll } from "./render";

export const OLIVE_TARGETS_FILE = "platform/olive/targets.yaml";
const OLIVE_CHART = "platform/olive";
const TARGET_KEYS = ["id", "kind", "namespace", "deployment", "declaredBy", "stop", "start"];
// platform/olive가 만드는 모양(templates/_helpers.tpl olive.targets). 나머지는 다른 차트가 선언하거나 아직 선언되지 않았다.
const OLIVE_KINDS = new Set(["supervisor", "executor"]);
const TARGET_KINDS = new Set([...OLIVE_KINDS, "session", "writer"]);
// ns·Deployment 이름은 CLI 정지 어댑터(cli/src/core/olive.ts LABEL)와 같은 DNS label이다. 다르면 CLI가 그 대상을 거부한다.
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const REPLICAS_POINTER = ["/spec/replicas"];
export const OLIVE_RULES = ["olive-targets", "olive-replicas", "olive-chart-targets", "olive-owner", "olive-ignore-differences", "olive-isolation"];

// 격리 검사를 다른 검사에 맡기는 실행 네임스페이스. sandbox는 작업자 보안 예외까지 아는 policy.ts checkSandbox가 본다.
// 여기 없는 대상 ns는 누가 선언하든(뒤 티켓이 다른 차트에 선언해도) 올리브 격리 검사를 받는다.
const ISOLATION_DELEGATED: Record<string, string> = { sandbox: "policy.ts checkSandbox" };

// 배포 렌더의 이름. REAL은 root의 실제 값 전체 렌더(render 단계와 같은 것), FORCED는 대상 차트의 components를 켠 root 렌더다.
const REAL = "root";
const FORCED = "root+켬";

export type Target = { id: string; kind: string; namespace: string; deployment: string; declaredBy: string; stop: unknown; start: unknown };
// targets: targets.yaml의 파싱 결과 그대로. charts: declaredBy → 켠 값 파일 렌더, chartRenders: 그 렌더 호출의 출처(문서가 0개여도 남는다).
// deployed: REAL·FORCED → 전체 렌더 문서(출처는 render.ts의 `<Application>[<클러스터>]:<source path>` 등).
export type OliveInput = { targets: any; charts: Record<string, Doc[]>; chartRenders: Record<string, string[]>; deployed: Record<string, Doc[]> };

const nsOf = (d: Doc): string | undefined => d.obj.metadata?.namespace ?? d.ns;
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
    const extra = keys.filter((k) => !TARGET_KEYS.includes(k));
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
        for (const d of found) out.push(...replicasViolations(d, t));
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
//   - REAL(지금 root): 켜진 구성 요소의 대상. FORCED(대상 차트를 켠 root): 꺼 둔 구성 요소도 실제 값으로. FORCED에는 대상이 꼭 있어야 한다.
//   - 소유(olive-owner): 대상 자리(유효 ns·Deployment 이름)의 Deployment는 declaredBy 차트를 source로 하는 Application 하나만 낸다.
//     declaredBy가 빈 대상의 자리에는 어느 렌더에도 Deployment가 없다. 다른 소스가 같은 자리에 내면 그 replicas·예외를 아무도 보지 않는다.
//   유효 ns는 metadata.namespace, 없으면 Application의 destination.namespace다(render.ts가 Doc.ns로 넘긴다).
function checkDeployed(targets: Target[], deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const clusters = clusterNames();
  for (const [variant, raw] of Object.entries(deployed)) {
    const docs = expand(raw);
    const forced = variant === FORCED;
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
        if (forced && own.length === 0) out.push({ rule: "olive-chart-targets", where: `${variant}[${c}]`, message: `대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})가 ${t.declaredBy}의 실제 값 렌더에 없다` });
        for (const d of own) out.push(...replicasViolations(d, t));
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
// 문자열이 아닌 값을 "적용된다"로 본다. jqPathExpressions·managedFieldsManagers도 같은 선택을 거친다.
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

// 대상을 배포하는 Application의 replicas 예외(supervisor.md §7.1 1). 클러스터마다, 대상 차트를 켠 root가 내는 Application 전부에서 본다.
// 예외가 없으면 selfHeal이 CLI가 켠 값을 Git 값 0으로 되돌리고, RespectIgnoreDifferences가 없으면 다른 이유의 sync가 덮는다.
// 대상에 적용되는 항목은 정확한 모양 하나만이다. 넓은 선택자나 다른 칸이 끼면 그 칸의 라이브 변경(이미지, 볼륨, 다른 Deployment)을
// Git이 되돌리지 않는다. platform/olive 밖의 대상은 start: true일 때만 예외를 둔다(그 전에는 손으로 올린 값을 selfHeal이 내린다).
function checkIgnoreDifferences(targets: Target[], deployed: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-ignore-differences", where, message });
  const charts = [...new Set(targets.map((t) => t.declaredBy).filter((d) => d !== ""))];
  const all = expand(deployed[FORCED] ?? []).filter((d) => d.obj.kind === "Application" && String(d.obj.apiVersion).startsWith("argoproj.io/") && deployedDoc(d));
  const clusters = clusterNames();
  for (const c of clusters) {
    const applications = all.filter((d) => context(d.origin) === c);
    for (const chart of charts) {
      const mine = targets.filter((t) => t.declaredBy === chart);
      const deployers = applications.filter((a) => effectiveSources(a.obj.spec).some((s) => sameRepo(s?.repoURL) && s?.path === chart));
      if (deployers.length !== 1) {
        push(`${FORCED}[${c}] ${chart}`, `${chart}를 배포하는 Application이 ${deployers.length}개다(하나여야 그 예외를 확인한다)`);
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
    ...checkDeployed(targets, input.deployed),
    ...checkIgnoreDifferences(targets, input.deployed),
    ...checkOliveIsolation(forcedApps, input.targets),
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
//     묶일 수 있는 Git 정적 PV가 있으면 노드의 아무 경로나 가리키는 PV에 묶일 수 있다.
//   - 두 번째 조절 주체: 대상 Deployment(위임한 ns 포함)를 가리키는 HorizontalPodAutoscaler. CLI가 켠 뒤 replicas를 바꾼다.
//     이 저장소에는 다른 조절 리소스(KEDA·VPA)의 CRD가 없다.
const OLIVE_VOLUME_TYPES = new Set(["emptyDir", "secret", "configMap", "persistentVolumeClaim"]);
// host/k3s-manifests/local-retain.yaml: provisioner rancher.io/local-path, WaitForFirstConsumer. 파드가 놓인 노드에 PV를 새로 만든다.
const OLIVE_PVC_CLASSES = new Set(["local-retain"]);
export function checkOliveIsolation(docs: Doc[], raw: any = readOliveTargets()): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-isolation", where, message });
  const targets = targetList(raw);
  const nss = new Set(targets.map((t) => t.namespace).filter((ns) => !Object.hasOwn(ISOLATION_DELEGATED, ns)));
  const inOlive = (d: Doc) => nss.has(nsOf(d) ?? "");
  const coversOlive = (s: any, bindingNs: string | undefined) => {
    if (s?.kind === "ServiceAccount") return nss.has(s.namespace ?? bindingNs ?? "");
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
      if (!OLIVE_PVC_CLASSES.has(spec.storageClassName)) push(where, `PVC의 storageClassName ${JSON.stringify(spec.storageClassName)}은 허용 클래스(${[...OLIVE_PVC_CLASSES].join("·")})가 아니다(없으면 기본 클래스, 빈 값이면 정적 PV)`);
    }
    if (k === "PersistentVolume") {
      const claimNs = d.obj.spec?.claimRef?.namespace;
      if (nss.has(claimNs ?? "")) push(where, `올리브 네임스페이스 ${claimNs}의 PVC에 묶인 정적 PV를 두지 않는다`);
      else if (OLIVE_PVC_CLASSES.has(d.obj.spec?.storageClassName) && claimNs === undefined) push(where, `storageClassName ${d.obj.spec.storageClassName}의 claimRef 없는 정적 PV는 올리브 PVC에 묶일 수 있다`);
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
// 켜는 PR이 실제 값을 넣으면 그 차트 values.yaml에서 비지 않으므로 채우지 않는다. replicas·대상 켜짐(targets.yaml, executors, enabled)에
// 닿는 키는 두지 않는다. 값은 platform/olive/ci/enabled.yaml과 같은 가짜다.
const RENDER_FILL: Record<string, Record<string, string>> = {
  [OLIVE_CHART]: {
    "image.digest": `sha256:${"0".repeat(64)}`,
    "supervisor.account.name": "ci-account",
  },
};
function renderFill(): Record<string, Record<string, unknown>> {
  const out: Record<string, Record<string, unknown>> = {};
  for (const [chart, paths] of Object.entries(RENDER_FILL)) {
    const values = Bun.YAML.parse(readText(`${chart}/values.yaml`)) as any;
    for (const [p, v] of Object.entries(paths)) {
      const cur = p.split(".").reduce((o, k) => o?.[k], values);
      if (cur !== "" && cur !== undefined && cur !== null) continue;
      const fill = (out[chart] ??= {});
      const parts = p.split(".");
      let node: any = fill;
      for (const k of parts.slice(0, -1)) node = node[k] ??= {};
      node[parts[parts.length - 1]] = v;
    }
  }
  return out;
}
export function renderFillKeys(): string[] {
  return Object.entries(renderFill()).flatMap(([chart, v]) => {
    const flat = (o: any, pre: string): string[] => Object.entries(o).flatMap(([k, x]) => (x && typeof x === "object" ? flat(x, `${pre}${k}.`) : [`${pre}${k}`]));
    return flat(v, "").map((k) => `${chart}:${k}`);
  });
}

// 입력: 대상 차트마다 ci/*.yaml 렌더(호출마다 출처를 남긴다), 지금 root의 전체 렌더(render 단계 캐시), 대상 차트를 켠 root의 전체 렌더.
// root 차트는 components.<디렉터리 이름>.enabled로 켠다. 이름이 다르면 Application이 렌더되지 않아 olive-chart-targets가 실패한다.
let cached: OliveInput | undefined;
export function oliveInput(): OliveInput {
  if (cached) return structuredClone(cached);
  const targets = readOliveTargets();
  const declaring = [...new Set(targetList(targets).map((t) => t.declaredBy))].filter((d) => /^platform\/[a-z0-9-]+$/.test(d) && existsSync(join(ROOT, d, "Chart.yaml")));
  const parse = (origin: string, text: string): Doc[] => parseAll(text).filter((o) => typeof o === "object" && !Array.isArray(o)).map((obj) => ({ origin, obj }));
  const charts: Record<string, Doc[]> = {};
  const chartRenders: Record<string, string[]> = {};
  for (const dir of declaring) {
    charts[dir] = [];
    chartRenders[dir] = [];
    for (const f of gitFiles(`${dir}/ci/*.yaml`)) {
      const origin = `chart:${relative("platform", dir)}/${relative(dir, f)}`;
      const r = helmTemplate(basename(dir), dir, `app-${basename(dir)}`, [f]);
      if (!r.ok) throw new Error(`${origin} 렌더 실패: ${r.out.trim()}`);
      chartRenders[dir].push(origin);
      charts[dir].push(...parse(origin, r.out));
    }
  }
  const real = renderAll();
  const forced = renderAll({ rootOverlay: { components: Object.fromEntries(declaring.map((d) => [basename(d), { enabled: true }])) }, fill: renderFill() });
  // 지금 root의 렌더 실패는 render 단계가 낸다. 켠 렌더에서만 나는 실패(꺼 둔 차트의 실제 값 렌더)는 이 검사의 입력이 없다는 뜻이다.
  const known = new Set(real.violations.map((v) => `${v.where}|${v.message}`));
  const extra = forced.violations.filter((v) => !known.has(`${v.where}|${v.message}`));
  if (extra.length > 0) throw new Error(`대상 차트를 켠 root 렌더 실패: ${extra.map(fmt).join("; ")}`);
  cached = { targets, charts, chartRenders, deployed: { [REAL]: real.docs, [FORCED]: forced.docs } };
  return structuredClone(cached);
}

// fixture(tools/ci/fixtures/olive/*.yaml). 지금 main의 선언(oliveInput)에 patch를 얹는다.
// 머리 주석: # expect: fail(# rule:, # match: 메시지 일부) 또는 pass. # also: <규칙,...>은 그 patch가 함께 내는 줄 아는 다른 규칙이다.
// 대조군은 patch 없는 입력 자체다. 규칙마다 음성 fixture가 하나 이상 있어야 한다.
// patch 한 줄:
//   in: targets(select는 id 등 칸) | chart(chart: 기본 platform/olive) | render(render: root·root+켬, 없으면 둘 다) | apps(root+켬의 Application)
//   select: chart·render·apps는 kind·namespace·name·origin(출처 그대로). 고를 것이 없으면 fixture 오류다.
//   set({점 경로: 값}), unset([점 경로]): 고른 것마다. 점 경로의 숫자는 목록 번호다.
//   remove({목록 경로: {칸: 값}}): 칸이 모두 같은 항목을 지운다. 없어도 된다. append({목록 경로: 값}): 끝에 더한다.
//   edit({목록 경로: {match: {칸: 값}, set: {점 경로: 값}}}): 맞는 항목이 하나 이상이어야 한다.
//   add(문서): chart는 그 차트의 ci 렌더마다, render는 origin(필수) 출처로 더한다. ns는 그 출처 Application의 destination.namespace다.
//   addRender(출처): chart에 문서 0개인 ci 렌더 호출 하나를 더한다.
type PatchOp = {
  ns?: string;
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

const matches = (item: any, fields: Record<string, unknown>) => Object.entries(fields).every(([k, v]) => JSON.stringify(item?.[k]) === JSON.stringify(v));

export function applyPatch(input: OliveInput, ops: PatchOp[]): string | undefined {
  for (const [i, op] of ops.entries()) {
    const sel = op.select ?? {};
    let objs: any[];
    if (op.in === "targets") {
      objs = (input.targets?.targets ?? []).filter((t: any) => Object.entries(sel).every(([k, v]) => t?.[k] === v));
    } else if (op.in === "chart" || op.in === "render" || op.in === "apps") {
      const chart = op.chart ?? OLIVE_CHART;
      let docs: Doc[];
      if (op.in === "chart") {
        if (!input.charts[chart]) return `patch[${i}]: 차트 ${chart}의 렌더가 없다`;
        docs = input.charts[chart];
        if (isString(op.addRender)) {
          input.chartRenders[chart].push(op.addRender);
          continue;
        }
      } else {
        const variants = op.in === "apps" ? [FORCED] : op.render ? [op.render] : Object.keys(input.deployed);
        if (variants.some((v) => !input.deployed[v])) return `patch[${i}]: 렌더 ${op.render}가 없다(${Object.keys(input.deployed).join("·")})`;
        if (op.add !== undefined) {
          if (!isString(op.origin)) return `patch[${i}]: render의 add는 origin이 필요하다`;
          for (const v of variants) input.deployed[v].push({ origin: op.origin, obj: structuredClone(op.add) as Record<string, any>, ns: op.ns });
          continue;
        }
        docs = variants.flatMap((v) => input.deployed[v]);
        if (op.in === "apps") docs = docs.filter((d) => d.obj.kind === "Application" && deployedDoc(d));
      }
      if (op.add !== undefined) {
        for (const origin of input.chartRenders[chart] ?? []) docs.push({ origin, obj: structuredClone(op.add) as Record<string, any> });
        continue;
      }
      objs = docs
        .filter((d) => (sel.kind === undefined || d.obj.kind === sel.kind) && (sel.namespace === undefined || nsOf(d) === sel.namespace) && (sel.name === undefined || d.obj.metadata?.name === sel.name) && (sel.origin === undefined || d.origin === sel.origin))
        .map((d) => d.obj);
    } else return `patch[${i}]: in은 targets·chart·render·apps 중 하나다`;
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
export const allChecks = (input: OliveInput) => [...checkOliveTargets(input), ...checkOliveIsolation(Object.values(input.charts).flat(), input.targets)];

export function checkOliveFixtures(base: OliveInput): Violation[] {
  const out: Violation[] = [];
  const dir = "tools/ci/fixtures/olive";
  const baseHits = allChecks(base);
  if (baseHits.length > 0) out.push({ rule: "fixture", where: `${dir} (대조군: 지금 main의 선언)`, message: `대조군이 걸렸다: ${baseHits.map(fmt).join("; ")}` });
  const covered = new Set<string>();
  const files = gitFiles(`${dir}/*.yaml`);
  for (const f of files) {
    const text = readText(f);
    const expect = header(text, "expect");
    const rule = header(text, "rule");
    const match = header(text, "match");
    const also = new Set((header(text, "also") ?? "").split(",").map((s) => s.trim()).filter(Boolean));
    const ops = (Bun.YAML.parse(text) as any)?.patch;
    const okHeader = expect === "pass" ? !rule && !match && also.size === 0 : expect === "fail" && !!rule && !!match && !also.has(rule);
    if (!okHeader || !Array.isArray(ops) || ops.length === 0 || [...also].some((r) => !OLIVE_RULES.includes(r))) {
      out.push({ rule: "fixture", where: f, message: "머리 주석 # expect: fail(# rule:, # match: 메시지 일부, 필요하면 # also: 다른 규칙) 또는 # expect: pass와 patch 목록이 필요하다" });
      continue;
    }
    const input = structuredClone(base);
    const err = applyPatch(input, ops);
    if (err) {
      out.push({ rule: "fixture", where: f, message: err });
      continue;
    }
    const got = allChecks(input);
    if (expect === "pass") {
      if (got.length > 0) out.push({ rule: "fixture", where: f, message: `양성 fixture가 걸렸다: ${got.map(fmt).join("; ")}` });
      continue;
    }
    covered.add(rule!);
    if (!got.some((v) => v.rule === rule && v.message.includes(match!))) out.push({ rule: "fixture", where: f, message: `${rule}(${match})가 걸리지 않았다(걸린 것: ${got.map(fmt).join("; ") || "없음"})` });
    // 모든 위반이 기대한 규칙·메시지(또는 # also의 규칙)여야 한다. 다른 위반이 섞이면 대상 검사가 사라져도 fixture가 초록으로 남는다.
    const other = got.filter((v) => (v.rule !== rule || !v.message.includes(match!)) && !also.has(v.rule));
    if (other.length > 0) out.push({ rule: "fixture", where: f, message: `기대하지 않은 위반: ${other.map(fmt).join("; ")}` });
  }
  for (const r of OLIVE_RULES) if (!covered.has(r)) out.push({ rule: "fixture", where: dir, message: `규칙 ${r}의 음성 fixture가 없다` });
  console.log(`olive fixture ${files.length}개`);
  return out;
}
