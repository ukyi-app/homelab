// 올리브 실행 대상 검사(D-38·D-39, docs/plans/2026-11-13-olive/supervisor.md §7.1·§7.2, O09 할 일 6 "딸린 제약").
// 비상 정지는 실행 대상 목록 하나(platform/olive/targets.yaml)를 믿는다. 차트가 만드는 Deployment, Argo CD 예외(ignoreDifferences),
// CLI가 내리고 올리는 대상이 이 목록과 어긋나면 정지가 덮지 못하는 파드가 생긴다. 그래서 이 목록을 기준으로 본다.
//   olive-targets: 목록의 모양(칸, 값 범위, start이면 stop, 선언되지 않은 대상은 start: false).
//   olive-replicas: 저장소가 선언한 대상 Deployment의 Git replicas는 0이다. 칸이 없으면 1로 뜨므로 실패다.
//   olive-chart-targets: 대상 Deployment가 선언한 차트의 렌더에 있다. platform/olive는 목록 밖 Deployment를 만들지 않는다.
//   olive-ignore-differences: 대상을 배포하는 Application의 replicas 예외. platform/olive는 대상 전부, 다른 차트는 start: true인 대상.
//   olive-isolation: 올리브 네임스페이스의 워크로드·RBAC·토큰·호스트 접근(checkOliveIsolation. 필수 검사는 전체 렌더에서 돈다).
// 구성 요소를 root에서 꺼 둬도 돈다. 차트는 ci/*.yaml(켠 값)로, root는 대상 차트의 components.<이름>.enabled를 켠 값으로 렌더한다.
// CLI의 올리브 명령은 아직 없다. 생기면 대상을 이 파일에서 읽어야 하고, 손으로 적은 목록을 두면 이 검사가 그 목록을 보지 못한다.
import { existsSync, writeFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { type Doc, type Violation, ROOT, effectiveSources, fmt, gitFiles, parseAll, readText, sameRepo, tempDir } from "./lib";
import { WORKLOAD_KINDS, expand, id, podSpec } from "./policy";
import { helmTemplate } from "./render";

export const OLIVE_TARGETS_FILE = "platform/olive/targets.yaml";
const OLIVE_CHART = "platform/olive";
const TARGET_KEYS = ["id", "kind", "namespace", "deployment", "declaredBy", "stop", "start"];
// platform/olive가 만드는 모양(templates/_helpers.tpl olive.targets). 나머지는 다른 차트가 선언하거나 아직 선언되지 않았다.
const OLIVE_KINDS = new Set(["supervisor", "executor"]);
const TARGET_KINDS = new Set([...OLIVE_KINDS, "session", "writer"]);
// ns·Deployment 이름은 CLI 정지 어댑터(cli/src/core/olive.ts LABEL)와 같은 DNS label이다. 다르면 CLI가 그 대상을 거부한다.
const LABEL = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const REPLICAS_POINTER = ["/spec/replicas"];
export const OLIVE_RULES = ["olive-targets", "olive-replicas", "olive-chart-targets", "olive-ignore-differences", "olive-isolation"];

export type Target = { id: string; kind: string; namespace: string; deployment: string; declaredBy: string; stop: unknown; start: unknown };
// targets: targets.yaml의 파싱 결과 그대로. charts: declaredBy(platform/<이름>) → 켠 값 파일 렌더. apps: 대상 차트를 켠 root 렌더.
export type OliveInput = { targets: any; charts: Record<string, Doc[]>; apps: Doc[] };

const nsOf = (d: Doc): string | undefined => d.obj.metadata?.namespace ?? d.ns;
const isString = (v: unknown): v is string => typeof v === "string";

// 자리(ns·Deployment·declaredBy)를 읽을 수 있는 줄. 모양 위반은 checkTargetShape가 따로 낸다. 여기서 빼면 그 줄의 Deployment가
// "목록 밖"으로 한 번 더 걸려 원인이 둘로 보인다.
export function targetList(raw: any): Target[] {
  const list: unknown[] = Array.isArray(raw?.targets) ? raw.targets : [];
  return list.filter((t: any): t is Target => !!t && typeof t === "object" && isString(t.namespace) && isString(t.deployment) && isString(t.declaredBy));
}

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
    if (t.start === true && t.stop !== true) bad(w, "start: true인데 stop이 true가 아니다. 켤 수 있는 대상은 비상 정지가 덮어야 한다");
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

// 대상마다 그 Deployment가 선언한 차트의 켠 렌더에 있고 replicas가 0인지. platform/olive는 목록과 렌더가 같은 집합이어야 한다.
function checkChartTargets(targets: Target[], charts: Record<string, Doc[]>): Violation[] {
  const out: Violation[] = [];
  for (const chart of [...new Set(targets.map((t) => t.declaredBy).filter((d) => d !== ""))]) {
    const mine = targets.filter((t) => t.declaredBy === chart);
    const docs = expand(charts[chart] ?? []);
    if (docs.length === 0) {
      out.push({ rule: "olive-chart-targets", where: chart, message: "켠 값 파일(ci/*.yaml)의 렌더가 없다. 대상 Deployment를 확인할 수 없다" });
      continue;
    }
    for (const origin of [...new Set(docs.map((d) => d.origin))]) {
      const deps = docs.filter((d) => d.origin === origin && d.obj.kind === "Deployment");
      for (const t of mine) {
        const found = deps.filter((d) => nsOf(d) === t.namespace && d.obj.metadata?.name === t.deployment);
        if (found.length === 0) out.push({ rule: "olive-chart-targets", where: origin, message: `${OLIVE_TARGETS_FILE}의 대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})가 렌더에 없다` });
        for (const d of found) {
          const spec = d.obj.spec ?? {};
          if (!Object.hasOwn(spec, "replicas")) out.push({ rule: "olive-replicas", where: id(d), message: `대상 ${t.id}의 spec.replicas 칸이 없다(없으면 1로 뜬다). Git 값은 0이다(D-38)` });
          else if (spec.replicas !== 0) out.push({ rule: "olive-replicas", where: id(d), message: `대상 ${t.id}의 spec.replicas가 0이 아니다(${JSON.stringify(spec.replicas)}). Git 값은 0이고 켜고 끄기는 관리자 CLI다(D-38)` });
        }
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

// 대상을 배포하는 Application의 replicas 예외(supervisor.md §7.1 1). root 렌더 하나(클러스터)마다 본다.
// 예외가 없으면 selfHeal이 CLI가 켠 값을 Git 값 0으로 되돌리고, RespectIgnoreDifferences가 없으면 다른 이유의 sync가 덮는다.
// 대상의 예외는 /spec/replicas 하나만이다. 다른 칸이 빠지면 그 칸의 라이브 변경(이미지, 볼륨)을 Git이 되돌리지 않는다.
function checkIgnoreDifferences(targets: Target[], apps: Doc[]): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-ignore-differences", where, message });
  const charts = [...new Set(targets.map((t) => t.declaredBy).filter((d) => d !== ""))];
  const all = expand(apps);
  const renders = [...new Set(all.map((d) => d.origin))];
  if (renders.length === 0) push("root", "root 렌더가 없다. 예외를 확인할 수 없다");
  for (const origin of renders) {
    const applications = all.filter((d) => d.origin === origin && d.obj.kind === "Application" && String(d.obj.apiVersion).startsWith("argoproj.io/"));
    for (const chart of charts) {
      const mine = targets.filter((t) => t.declaredBy === chart);
      const deployers = applications.filter((a) => effectiveSources(a.obj.spec).some((s) => sameRepo(s?.repoURL) && s?.path === chart));
      if (deployers.length !== 1) {
        push(`${origin} ${chart}`, `${chart}를 배포하는 Application이 ${deployers.length}개다(하나여야 그 예외를 확인한다)`);
        continue;
      }
      const app = deployers[0];
      const appName = app.obj.metadata?.name;
      const entries: any[] = Array.isArray(app.obj.spec?.ignoreDifferences) ? app.obj.spec.ignoreDifferences : [];
      const covers = (e: any, t: Target) => e?.group === "apps" && e?.kind === "Deployment" && e?.namespace === t.namespace && e?.name === t.deployment;
      entries.forEach((e, i) => {
        const w = `${id(app)} ignoreDifferences[${i}]`;
        const t = mine.find((x) => covers(e, x));
        if (e?.kind === "Deployment" && (!isString(e.name) || !isString(e.namespace))) {
          push(w, "Deployment 예외는 namespace와 name을 적는다. 없으면 대상 밖 Deployment의 칸까지 Git이 놓친다");
        } else if (t) {
          const pointers = JSON.stringify(e.jsonPointers ?? []);
          if (pointers !== JSON.stringify(REPLICAS_POINTER) || e.jqPathExpressions !== undefined || e.managedFieldsManagers !== undefined) {
            push(w, `대상 ${t.id}의 예외가 /spec/replicas 말고 다른 칸을 가리킨다(jsonPointers ${pointers}${e.jqPathExpressions ? `, jqPathExpressions` : ""}${e.managedFieldsManagers ? `, managedFieldsManagers` : ""})`);
          }
        } else if (chart === OLIVE_CHART) {
          push(w, `${OLIVE_TARGETS_FILE}에 없는 리소스의 예외다(${e?.kind} ${e?.namespace}/${e?.name}). ${appName}의 예외는 대상 Deployment의 /spec/replicas뿐이다`);
        }
      });
      // platform/olive는 대상 전부(start와 상관없이 켜고 끄기는 CLI다). 다른 차트는 지금 켤 수 있는(start: true) 대상만 요구한다.
      for (const t of mine) {
        if (entries.some((e) => covers(e, t))) continue;
        if (chart === OLIVE_CHART) push(id(app), `대상 ${t.id}(Deployment ${t.namespace}/${t.deployment})의 /spec/replicas 예외가 없다`);
        else if (t.start === true) push(id(app), `대상 ${t.id}가 start: true인데 그 Deployment(${t.namespace}/${t.deployment})를 배포하는 ${appName}에 /spec/replicas 예외가 없다. selfHeal이 CLI가 켠 값을 0으로 되돌린다`);
      }
      const hasTargetEntry = entries.some((e) => mine.some((t) => covers(e, t)));
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
  return [...checkTargetShape(input.targets), ...checkChartTargets(targets, input.charts), ...checkIgnoreDifferences(targets, input.apps)];
}

export function readOliveTargets(): any {
  return Bun.YAML.parse(readText(OLIVE_TARGETS_FILE));
}

// 올리브 네임스페이스의 금지(D-37, supervisor.md §1.1, AC-29). 전체 렌더에서 본다. 다른 차트가 올리브 ns에 워크로드를 두거나
// 올리브 SA를 묶는 바인딩을 더해도 걸린다. 올리브 ns는 platform/olive 대상과 아직 선언되지 않은 대상(declaredBy "")의 ns다.
// 다른 차트가 선언한 대상의 ns(작성 = sandbox)는 그 차트의 검사(policy.ts checkSandbox)가 맡는다.
//   - 대상 자료 밖의 워크로드: 정지는 대상 Deployment만 0으로 내린다. 자물쇠는 새 파드만 막아 이미 뜬 파드가 남는다.
//     정지 중에도 떠야 하는 것은 실행 ns 밖에 둔다(B-16).
//   - RBAC: 감독에 Kubernetes 쓰기 권한이 없고 실행기에는 클러스터 자격이 없다. ns 안 Role·RoleBinding도, 밖에서 올리브 SA를 묶는 것도 막는다.
//     SA는 kind: User(system:serviceaccount:<ns>:<이름>)와 그룹으로도 묶인다.
//   - 토큰: 파드와 SA 양쪽의 자동 마운트를 끈다. projected serviceAccountToken은 아래 볼륨 허용 목록이 막는다.
//   - 호스트: hostNetwork·hostPID·hostIPC, hostPath(hc 소켓 자리)를 막는다. 볼륨은 emptyDir·secret·configMap·PVC만 받고,
//     PVC는 동적 프로비저닝만이다(정적 PV는 노드의 아무 경로나 가리킬 수 있다).
const OLIVE_VOLUME_TYPES = new Set(["emptyDir", "secret", "configMap", "persistentVolumeClaim"]);
export function checkOliveIsolation(docs: Doc[], raw: any = readOliveTargets()): Violation[] {
  const out: Violation[] = [];
  const push = (where: string, message: string) => out.push({ rule: "olive-isolation", where, message });
  const targets = targetList(raw);
  const nss = new Set(targets.filter((t) => t.declaredBy === OLIVE_CHART || t.declaredBy === "").map((t) => t.namespace));
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
  let seen = 0;
  for (const d of expand(docs)) {
    const k = d.obj.kind;
    const where = id(d);
    if ((k === "Role" || k === "RoleBinding") && inOlive(d)) {
      push(where, `올리브 네임스페이스 ${nsOf(d)}에 ${k}를 두지 않는다(RBAC 없음, D-37)`);
      continue;
    }
    if ((k === "RoleBinding" || k === "ClusterRoleBinding") && (d.obj.subjects ?? []).some((s: any) => coversOlive(s, nsOf(d)))) {
      push(where, `올리브 SA(또는 그 SA가 드는 그룹)를 묶는 ${k}를 두지 않는다(RBAC 없음, D-37)`);
      continue;
    }
    if (k === "ServiceAccount" && inOlive(d) && d.obj.automountServiceAccountToken !== false) push(where, "ServiceAccount의 automountServiceAccountToken이 false가 아니다");
    if (k === "PersistentVolumeClaim" && inOlive(d) && d.obj.spec?.volumeName !== undefined) push(where, `PVC를 정적 PV ${d.obj.spec.volumeName}에 묶지 않는다(노드 경로를 고를 수 있다)`);
    if (k === "PersistentVolume" && nss.has(d.obj.spec?.claimRef?.namespace ?? "")) push(where, `올리브 네임스페이스 ${d.obj.spec.claimRef.namespace}의 PVC에 묶인 정적 PV를 두지 않는다`);
    if (!WORKLOAD_KINDS.has(k) || !inOlive(d)) continue;
    seen++;
    const isTarget = k === "Deployment" && targets.some((t) => t.namespace === nsOf(d) && t.deployment === d.obj.metadata?.name);
    if (!isTarget) push(where, `${OLIVE_TARGETS_FILE}의 대상 자료 밖의 워크로드다. 비상 정지가 이 파드를 내리지 못한다(정지 중에도 떠야 하면 실행 네임스페이스 밖에 둔다)`);
    const spec = podSpec(d.obj) ?? {};
    if (spec.automountServiceAccountToken !== false) push(where, "파드의 automountServiceAccountToken이 false가 아니다");
    for (const f of ["hostNetwork", "hostPID", "hostIPC"]) if (spec[f] === true) push(where, `${f}를 쓰지 않는다`);
    for (const v of spec.volumes ?? []) {
      const types = Object.keys(v ?? {}).filter((x) => x !== "name");
      if (types.includes("hostPath")) push(where, `hostPath 볼륨 ${v.name}을 쓰지 않는다(호스트 경로·hc 소켓)`);
      else if (types.length !== 1 || !OLIVE_VOLUME_TYPES.has(types[0])) push(where, `볼륨 ${v?.name}의 종류 ${types.join(",")}를 쓰지 않는다(${[...OLIVE_VOLUME_TYPES].join("·")}만)`);
    }
  }
  if (seen === 0) push("render", "올리브 네임스페이스에서 검사한 워크로드가 0개다(L40)");
  return out;
}

// 켠 값의 렌더. 대상을 선언한 차트마다 ci/*.yaml로, root는 클러스터 값마다 그 차트들을 켠 값을 얹는다.
// root 차트는 components.<디렉터리 이름>.enabled로 켠다. 이름이 다르면 Application이 렌더되지 않아 olive-ignore-differences가 실패한다.
let cached: OliveInput | undefined;
export function oliveInput(): OliveInput {
  if (cached) return structuredClone(cached);
  const targets = readOliveTargets();
  const declaring = [...new Set(targetList(targets).map((t) => t.declaredBy))].filter((d) => /^platform\/[a-z0-9-]+$/.test(d) && existsSync(join(ROOT, d, "Chart.yaml")));
  const parse = (origin: string, text: string): Doc[] => parseAll(text).filter((o) => typeof o === "object" && !Array.isArray(o)).map((obj) => ({ origin, obj }));
  const charts: Record<string, Doc[]> = {};
  for (const dir of declaring) {
    charts[dir] = [];
    for (const f of gitFiles(`${dir}/ci/*.yaml`)) {
      const origin = `chart:${relative("platform", dir)}/${relative(dir, f)}`;
      const r = helmTemplate(basename(dir), dir, `app-${basename(dir)}`, [f]);
      if (!r.ok) throw new Error(`${origin} 렌더 실패: ${r.out.trim()}`);
      charts[dir].push(...parse(origin, r.out));
    }
  }
  const tmp = tempDir("olive");
  const overlay = join(tmp, "components.json");
  writeFileSync(overlay, JSON.stringify({ components: Object.fromEntries(declaring.map((d) => [basename(d), { enabled: true }])) }));
  const apps: Doc[] = [];
  for (const vf of gitFiles("platform/root/values-*.yaml")) {
    const cluster = basename(vf).replace(/^values-/, "").replace(/\.yaml$/, "");
    const origin = `root+olive-targets[${cluster}]`;
    const r = helmTemplate(`root-${cluster}`, "platform/root", "argocd", [vf, overlay]);
    if (!r.ok) throw new Error(`${origin} 렌더 실패: ${r.out.trim()}`);
    apps.push(...parse(origin, r.out));
  }
  cached = { targets, charts, apps };
  return structuredClone(cached);
}

// 음성 fixture(tools/ci/fixtures/olive/*.yaml). 지금 main의 선언(oliveInput)에 patch를 얹어 기대한 규칙 하나만 걸리는지 본다.
// 대조군은 patch 없는 입력 자체다. 규칙마다 음성 fixture가 하나 이상 있어야 한다.
// patch 한 줄: in(targets|chart|apps), chart(in: chart일 때, 기본 platform/olive), select(targets는 id, 나머지는 kind·namespace·name),
// set({점 경로: 값}), unset([점 경로]), add(문서 하나, in: chart). 점 경로의 숫자는 목록 번호다. 고를 것이 없으면 fixture 오류다.
type PatchOp = { in?: string; chart?: string; select?: Record<string, unknown>; set?: Record<string, unknown>; unset?: string[]; add?: unknown };

function header(text: string, key: string): string | undefined {
  return text.match(new RegExp(`^# ${key}: (.+)$`, "m"))?.[1].trim();
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

function applyPatch(input: OliveInput, ops: PatchOp[]): string | undefined {
  for (const [i, op] of ops.entries()) {
    const sel = op.select ?? {};
    let objs: any[];
    if (op.in === "targets") {
      objs = (input.targets?.targets ?? []).filter((t: any) => Object.entries(sel).every(([k, v]) => t?.[k] === v));
    } else if (op.in === "chart" || op.in === "apps") {
      const docs = op.in === "apps" ? input.apps : input.charts[op.chart ?? OLIVE_CHART];
      if (!docs) return `patch[${i}]: 차트 ${op.chart}의 렌더가 없다`;
      if (op.add !== undefined) {
        for (const origin of [...new Set(docs.map((d) => d.origin))]) docs.push({ origin, obj: structuredClone(op.add) as Record<string, any> });
        continue;
      }
      objs = docs
        .filter((d) => (sel.kind === undefined || d.obj.kind === sel.kind) && (sel.namespace === undefined || nsOf(d) === sel.namespace) && (sel.name === undefined || d.obj.metadata?.name === sel.name))
        .map((d) => d.obj);
    } else return `patch[${i}]: in은 targets·chart·apps 중 하나다`;
    if (objs.length === 0) return `patch[${i}]: select ${JSON.stringify(sel)}에 맞는 것이 없다`;
    for (const o of objs) {
      for (const [p, v] of Object.entries(op.set ?? {})) setPath(o, p, v);
      for (const p of op.unset ?? []) if (!unsetPath(o, p)) return `patch[${i}]: 지울 경로 ${p}가 없다`;
    }
  }
  return undefined;
}

// fixture는 두 검사를 함께 받는다. 필수 검사에서 checkOliveIsolation은 전체 렌더 단계에서 돌지만, 여기서는 대상 차트 렌더만 본다.
const allChecks = (input: OliveInput) => [...checkOliveTargets(input), ...checkOliveIsolation(Object.values(input.charts).flat(), input.targets)];

export function checkOliveFixtures(base: OliveInput): Violation[] {
  const out: Violation[] = [];
  const dir = "tools/ci/fixtures/olive";
  const baseHits = allChecks(base);
  if (baseHits.length > 0) out.push({ rule: "fixture", where: `${dir} (대조군: 지금 main의 선언)`, message: `대조군이 걸렸다: ${baseHits.map(fmt).join("; ")}` });
  const covered = new Set<string>();
  const files = gitFiles(`${dir}/*.yaml`);
  for (const f of files) {
    const text = readText(f);
    const rule = header(text, "rule");
    const match = header(text, "match");
    const ops = (Bun.YAML.parse(text) as any)?.patch;
    if (header(text, "expect") !== "fail" || !rule || !match || !Array.isArray(ops) || ops.length === 0) {
      out.push({ rule: "fixture", where: f, message: "머리 주석 # expect: fail, # rule:, # match:(메시지 일부)와 patch 목록이 필요하다" });
      continue;
    }
    const input = structuredClone(base);
    const err = applyPatch(input, ops);
    if (err) {
      out.push({ rule: "fixture", where: f, message: err });
      continue;
    }
    covered.add(rule);
    const got = allChecks(input);
    if (!got.some((v) => v.rule === rule && v.message.includes(match))) out.push({ rule: "fixture", where: f, message: `${rule}(${match})가 걸리지 않았다(걸린 것: ${got.map(fmt).join("; ") || "없음"})` });
    // 모든 위반이 기대한 규칙·메시지여야 한다. 다른 위반이 섞이면 대상 검사가 사라져도 fixture가 초록으로 남는다.
    const other = got.filter((v) => v.rule !== rule || !v.message.includes(match));
    if (other.length > 0) out.push({ rule: "fixture", where: f, message: `기대하지 않은 위반: ${other.map(fmt).join("; ")}` });
  }
  for (const r of OLIVE_RULES) if (!covered.has(r)) out.push({ rule: "fixture", where: dir, message: `규칙 ${r}의 음성 fixture가 없다` });
  console.log(`olive fixture ${files.length}개`);
  return out;
}
