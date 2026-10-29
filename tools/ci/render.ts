// 저장소가 Argo CD에 내는 매니페스트를 Argo CD와 같은 방식으로 렌더한다(설계 C.4.6 "렌더 + 스키마").
//
// 대상은 디렉터리 목록을 적지 않고 찾는다.
// 1. root Application 파일(platform/root/root-<클러스터>.yaml)마다 그 선언(path, helm.valueFiles, releaseName,
//    destination)대로 root 차트를 렌더한다. root-<클러스터>는 values-<클러스터>.yaml 하나만 읽어야 하고,
//    짝 없는 values-*.yaml도 실패다(VM이 운영 값을 읽는 실수, E8 VM 격리 1번).
// 2. 그 렌더의 Application 중 이 저장소를 가리키는 source를 그 Application이 넘기는 값(valuesObject 등)으로 렌더한다.
//    외부 Helm 저장소의 차트는 렌더하지 않는다. 외부 레지스트리 조회는 필수 검사에 넣지 않는다(설계 C.4.6, P27).
//    Argo CD가 렌더에 쓰는 source 옵션 중 여기서 재현하지 않는 것(kustomize, directory, plugin 등)은 실패로 둔다.
// 3. 위에서 안 다룬 추적 kustomization도 모두 build한다(꺼진 구성 요소도 깨지지 않게).
// 4. 차트의 시험 values(platform/charts/<차트>/ci/*.yaml)로 렌더한다. 공유 차트 PR은 어느 앱에도 바로 적용되지 않으므로
//    이것이 그 PR의 렌더 검사다(설계 C.4.5).
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { type Doc, type Violation, ARGOCD_SOURCE_OVERRIDE, ROOT, effectiveSources, gitFiles, parseAll, run, sameRepo, tempDir, toolVersion } from "./lib";

export type Rendered = { origin: string; text: string };
export type RenderResult = { targets: Rendered[]; docs: Doc[]; violations: Violation[]; skipped: string[] };

// 자기 저장소 source에서 받아들이는 키. 나머지는 Argo CD 렌더를 바꾸는데 여기서 재현하지 않으므로 실패로 둔다.
const SOURCE_KEYS = new Set(["repoURL", "targetRevision", "path", "helm", "ref"]);
const HELM_KEYS = new Set(["valuesObject", "valueFiles", "releaseName"]);
// Kustomize가 찾는 파일 이름 셋(kustomize의 konfig.RecognizedKustomizationFileNames).
const KUSTOMIZATION_FILES = ["kustomization.yaml", "kustomization.yml", "Kustomization"];

export function kubeVersion(): string {
  return toolVersion("kubectl");
}

export function helmTemplate(release: string, chartDir: string, namespace: string | undefined, valueFiles: string[]): { ok: boolean; out: string } {
  // --include-crds: Argo CD는 skipCrds 기본값이 false라 차트의 crds/도 적용한다.
  // --skip-tests: Argo CD는 helm.sh/hook: test 리소스를 hook으로 보지만 맞는 단계가 없어 적용하지 않는다
  // (v3.5.5 gitops-engine/pkg/sync/hook/helm/type.go는 pre/post-install·upgrade만 단계로 바꾼다). 공식 valkey 차트의
  // 시험 Pod가 그 예다. 렌더에 남기면 클러스터에 생기지 않는 Pod를 정책이 검사한다.
  const args = ["helm", "template", release, chartDir, "--include-crds", "--skip-tests", "--kube-version", kubeVersion()];
  if (namespace) args.push("--namespace", namespace);
  for (const f of valueFiles) args.push("-f", f);
  const r = run(args);
  return { ok: r.code === 0, out: r.code === 0 ? r.stdout : r.stderr || r.stdout };
}

// install.yaml 같은 원격 base는 네트워크가 잠깐 끊겨도 필수 검사가 빨개지지 않게 몇 번 다시 시도한다.
function kustomizeBuild(dir: string): { ok: boolean; out: string } {
  let last = "";
  for (let i = 0; i < 3; i++) {
    const r = run(["kustomize", "build", dir]);
    if (r.code === 0) return { ok: true, out: r.stdout };
    last = r.stderr || r.stdout;
    if (!/(dial|timeout|TLS|EOF|connection|50[0-9])/i.test(last)) break;
    Bun.sleepSync(2000 * (i + 1));
  }
  return { ok: false, out: last };
}

function isKustomizeDir(dir: string): boolean {
  return KUSTOMIZATION_FILES.some((f) => existsSync(join(ROOT, dir, f)));
}

// 차트 트리 전체에서 Helm이 템플릿으로 읽는 파일: 루트와 의존 차트(charts/<dep>/...)의 templates/ 아래 전부.
// 묶음 의존 차트(charts/*.tgz)는 풀어서 같은 규칙으로 본다. 작업 트리면 추적 파일만, 태그 트리면 꺼낸 파일 전부.
function templateFiles(dir: string, tmp: string): string[] {
  const abs = dir.startsWith("/") ? dir : join(ROOT, dir);
  const files = dir.startsWith("/")
    ? walkFiles(abs)
    : gitFiles(`${dir}/`).map((f) => join(ROOT, f));
  const out = files.filter((f) => /(^|\/)templates\//.test(relative(abs, f)));
  for (const tgz of files.filter((f) => /(^|\/)charts\/[^/]+\.tgz$/.test(relative(abs, f)))) {
    const dst = join(tmp, "deps", relative(ROOT, tgz).replaceAll("/", "_"));
    mkdirSync(dst, { recursive: true });
    const x = Bun.spawnSync(["tar", "-xzf", tgz, "-C", dst], { stderr: "pipe" });
    if (x.exitCode !== 0) throw new Error(`의존 차트를 풀지 못했다: ${relative(ROOT, tgz)}`);
    out.push(...templateFiles(dst, tmp));
  }
  return [...new Set(out)];
}

function walkFiles(d: string): string[] {
  const out: string[] = [];
  if (!existsSync(d)) return out;
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) out.push(...walkFiles(p));
    else out.push(p);
  }
  return out;
}

// 공유 차트를 태그 시점 내용으로 꺼낸다. 태그가 로컬에 없으면(얕은 checkout) origin에서 그 태그만 받는다.
// 차트 태그(<이름>-v<semver>)만 받는다. 브랜치 이름은 움직이므로 렌더 근거가 못 된다.
const revCache = new Map<string, string>();
export function pathAtRevision(tag: string, path: string, tmp: string): string {
  const key = `${tag}:${path}`;
  const hit = revCache.get(key);
  if (hit) return hit;
  if (!/^[a-z-]+-v\d+\.\d+\.\d+$/.test(tag)) throw new Error(`차트 태그 형식이 아니다: ${tag}`);
  if (run(["git", "rev-parse", "--verify", "--quiet", `refs/tags/${tag}`]).code !== 0) {
    const f = run(["git", "fetch", "--depth=1", "--no-tags", "origin", `refs/tags/${tag}:refs/tags/${tag}`]);
    if (f.code !== 0) throw new Error(`태그 ${tag}가 없다: ${f.stderr.trim()}`);
  }
  const dst = join(tmp, "rev", tag);
  mkdirSync(dst, { recursive: true });
  // tar는 바이너리라 문자열로 받지 않는다.
  const archive = Bun.spawnSync(["git", "archive", "--format=tar", tag, path], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  if (archive.exitCode !== 0) throw new Error(`git archive ${tag} ${path} 실패: ${archive.stderr.toString()}`);
  const x = Bun.spawnSync(["tar", "-x", "-C", dst], { stdin: archive.stdout, stderr: "pipe" });
  if (x.exitCode !== 0) throw new Error(`tar 실패: ${x.stderr.toString()}`);
  const out = join(dst, path);
  // 태그 트리의 source override도 막는다. 태그는 main을 지난 커밋에 달지만, 그 커밋이 이 검사 전의 것일 수 있다.
  const override = (readdirSync(out, { recursive: true }) as string[]).filter((f) => ARGOCD_SOURCE_OVERRIDE.test(basename(f)));
  if (override.length > 0) throw new Error(`${tag}의 ${path}에 .argocd-source 파일이 있다: ${override.join(", ")}`);
  revCache.set(key, out);
  return out;
}

function plainDir(dir: string): { ok: boolean; out: string } {
  // Argo CD directory 소스의 기본값(recurse 없음)과 같이 바로 아래 .yaml·.yml·.json. JSON은 YAML로도 읽힌다.
  const files = gitFiles(`${dir}/*.yaml`, `${dir}/*.yml`, `${dir}/*.json`).filter((f) => dirname(f) === dir);
  if (files.length === 0) return { ok: false, out: `${dir}에 매니페스트가 없다` };
  return { ok: true, out: files.map((f) => readFileSync(join(ROOT, f), "utf8")).join("\n---\n") };
}

// ApplicationSet 이름 → 그 모양이 render.ts의 전개와 같은지 보는 함수(true 또는 어긋난 이유).
// 같은 모양일 때만 아래 단계가 생성될 Application을 대신 렌더한 것이 된다. 복구 멈춤 값은 클러스터마다 달라 함께 받는다.
const APPSET_RENDERERS: Record<string, (set: any, restore: Restore) => true | string> = {};
// 클러스터 값 파일의 tailnet 접두(cluster.tailscale.prefix). ApplicationSet이 앱 values에 넣는 값과 같다.
function clusterPrefixes(clusterFiles: string[]): [string, string][] {
  return clusterFiles.map((vf) => {
    const cluster = vf.replace(/^platform\/root\/values-/, "").replace(/\.yaml$/, "");
    const v = Bun.YAML.parse(readFileSync(join(ROOT, vf), "utf8")) as any;
    const prefix = v?.cluster?.tailscale?.prefix;
    if (typeof prefix !== "string") throw new Error(`${vf}에 cluster.tailscale.prefix가 없다`);
    return [cluster, prefix];
  });
}

// 복구 동안 이 클러스터에서만 바꿀 값(cluster.restore). 비어 있지 않으면 ApplicationSet apps·data의 templatePatch가
// files/restore-patch.tpl·external-secrets-patch.tpl로 바뀌어 그 앱의 values를 덮어쓴다(platform/appsets/*/templates/applicationset.yaml).
// externalSecretsOff: 복구 스위치 cluster.restore.externalSecrets가 bool false(platform/root/templates/_helpers.tpl과 같은 판정).
export type Restore = { suspendedApps: string[]; valkey: Record<string, string>; externalSecretsOff: boolean };
export function clusterRestore(vf: string, overlay?: RootOverlay): Restore {
  const r = (Bun.YAML.parse(readFileSync(join(ROOT, vf), "utf8")) as any)?.cluster?.restore ?? {};
  const o = overlay?.cluster?.restore ?? {};
  const es = "externalSecrets" in o ? o.externalSecrets : r.externalSecrets;
  // 모양이 틀린 값(목록·맵이 아님)은 ApplicationSet 차트 렌더가 실패로 막는다. 여기서는 빈 값으로 본다.
  // bool이 아닌 스위치 값은 root의 cluster-check.yaml이 렌더를 막는다.
  return {
    suspendedApps: Array.isArray(r.suspendedApps) ? r.suspendedApps.map(String) : [],
    valkey: r.valkey && typeof r.valkey === "object" && !Array.isArray(r.valkey) ? r.valkey : {},
    externalSecretsOff: es === false,
  };
}

// 끈 렌더(tools/ci/switch.ts). root 값 위에 얹는 값과, 로컬 차트 시험 values 위에 얹는 값이다.
// 덧씌우기가 있으면 3.(남은 kustomization) build는 건너뛴다. 배포되지 않는 디렉터리라 스위치와 상관없고, 켠 렌더가 이미 본다.
export type RootOverlay = { cluster?: { restore?: Record<string, unknown> } };
export type RenderOptions = { rootOverlay?: RootOverlay; chartOverlay?: Record<string, unknown> };
// 복구 스위치를 끈 값. ApplicationSet이 생성 Application에 넣는 값과 같다(platform/appsets/*/files/external-secrets-patch.tpl).
export const EXTERNAL_SECRETS_OFF = { externalSecrets: { enabled: false } };
const ES_PATCH_LINE = '{{- $_ := set $v "externalSecrets" (dict "enabled" false) }}';

// 복구 스위치를 아는 첫 공유 차트 버전. 그 전 태그는 닫힌 schema가 externalSecrets를 거부하고 ExternalSecret도 그대로 낸다.
// 기존 앱은 옛 태그에 머물 수 있으므로(설계 C.4.5) 스위치를 실제로 끈 클러스터에서만 실패다. 일반 PR의 가상 끔 렌더에서는
// tools/ci/switch.ts가 이 rule을 정보 줄로 바꾼다.
export const ES_SWITCH_SINCE = { app: "1.2.0", data: "1.1.0" } as const;
export const ES_CHART_RULE = "external-secrets-chart";
function esSwitchUnsupported(kind: "app" | "data", app: string, version: unknown): string | undefined {
  const parse = (s: string) => (/^\d+\.\d+\.\d+$/.test(s) ? s.split(".").map(Number) : undefined);
  const have = parse(String(version));
  const since = parse(ES_SWITCH_SINCE[kind])!;
  // 형식이 틀린 chartVersion은 아래 태그 조회가 실패로 막는다.
  if (!have) return undefined;
  const i = have.findIndex((n, k) => n !== since[k]);
  if (i < 0 || have[i] > since[i]) return undefined;
  const file = kind === "app" ? `apps/${app}/values.yaml` : `data/${app}/values.yaml`;
  const chart = kind === "app" ? "앱 차트" : "데이터 차트";
  return `복구 스위치(cluster.restore.externalSecrets: false)는 ${chart} ${ES_SWITCH_SINCE[kind]}부터 지원한다(지금 chartVersion ${version}). 스위치를 끄기 전에 ${file}의 chartVersion을 올린다`;
}

// ApplicationSet apps의 templatePatch가 만드는 앱 values(아래 5.와 tools/ci/appset-patch.ts가 함께 쓴다).
// params는 values.yaml + image.yaml 키(생성기 변수 path·values 제외)다. tailnetPrefix는 클러스터 값이 이긴다.
export function appValues(app: string, params: Record<string, any>, prefix: string, restore: Restore): Record<string, any> {
  const values: Record<string, any> = { ...params, tailnetPrefix: prefix };
  if (restore.suspendedApps.includes(app)) values.suspended = true;
  if (restore.externalSecretsOff) Object.assign(values, structuredClone(EXTERNAL_SECRETS_OFF));
  return values;
}

// ApplicationSet data의 templatePatch가 만드는 데이터 values(아래 6.와 tools/ci/appset-patch.ts가 함께 쓴다).
// 복구 멈춤 맵에 있으면 사람 values의 valkey.running·restoreMode를 버리고 모드 값으로 다시 쓴다.
export function dataValues(app: string, human: Record<string, any>, bucket: string, restore: Restore): Record<string, any> {
  const values: Record<string, any> = { ...human, backup: { bucket } };
  const mode = restore.valkey[app];
  if (mode !== undefined) {
    const { running: _running, restoreMode: _restoreMode, ...rest } = (human.valkey ?? {}) as Record<string, any>;
    values.valkey = { ...rest, running: mode === "restoreMode", ...(mode === "restoreMode" ? { restoreMode: true } : {}) };
  }
  if (restore.externalSecretsOff) Object.assign(values, structuredClone(EXTERNAL_SECRETS_OFF));
  return values;
}

// ApplicationSet apps(platform/appsets/apps/files/applicationset.yaml). 아래 5.가 그 Application을 대신 렌더하므로
// 생성기·템플릿·값 합치기가 그 전개와 같은지 본다. 하나를 바꾸면 이 함수와 5.를 함께 바꾼다.
APPSET_RENDERERS.apps = (set, restore) => {
  const gens: any[] = set.spec?.generators?.[0]?.merge?.generators ?? [];
  const files = gens.map((g) => (g.git?.files ?? []).map((f: any) => f.path).join(",")).join("|");
  if (set.spec?.generators?.length !== 1 || files !== "apps/*/values.yaml|apps/*/image.yaml") {
    return "생성기가 apps/*/values.yaml과 apps/*/image.yaml의 merge 하나가 아니다";
  }
  if (gens.some((g) => g.git?.values?.app !== "{{ .path.basename }}") || JSON.stringify(set.spec.generators[0].merge.mergeKeys) !== '["values"]') {
    return "merge 짝 키가 values.app(디렉터리 이름)이 아니다";
  }
  const t = set.spec?.template ?? {};
  const src = t.spec?.source ?? {};
  if (
    t.metadata?.name !== "{{ .values.app }}" ||
    t.spec?.destination?.namespace !== "app-{{ .values.app }}" ||
    src.path !== "platform/charts/app" ||
    src.targetRevision !== "app-chart-v{{ .chartVersion }}" ||
    t.spec?.sources !== undefined
  ) {
    return "템플릿 이름·ns·source가 render.ts의 앱 렌더(app-<앱>, platform/charts/app@app-chart-v<chartVersion>)와 다르다";
  }
  const patch = String(set.spec?.templatePatch ?? "");
  // 복구 스위치 주입은 끈 클러스터에만 있어야 한다. 켠 클러스터에 있으면 아래 5.가 재현하지 않는 값이 앱에 들어간다.
  if (patch.includes(ES_PATCH_LINE) !== restore.externalSecretsOff) return "templatePatch의 복구 스위치 주입(externalSecrets)이 클러스터 값과 다르다";
  if (restore.suspendedApps.length === 0 && !restore.externalSecretsOff) {
    if (!patch.includes('omit . "path" "values" "tailnetPrefix" | toYaml')) return "templatePatch의 값 합치기가 render.ts와 다르다";
    return true;
  }
  const want = ['{{- $v := omit . "path" "values" "tailnetPrefix" }}', "{{- $v | toYaml | nindent 8 }}"];
  // 복구 멈춤: 목록의 앱에만 suspended: true(아래 5.와 같은 전개).
  if (restore.suspendedApps.length > 0) {
    const list = restore.suspendedApps.map((a) => JSON.stringify(a)).join(" ");
    want.push(`{{- if has .values.app (list ${list}) }}`, '{{- $_ := set $v "suspended" true }}');
  }
  if (want.some((w) => !patch.includes(w))) return "templatePatch의 복구 주입(suspendedApps·externalSecrets)이 render.ts의 전개와 다르다";
  return true;
};

// ApplicationSet data(platform/appsets/data/files/applicationset.yaml). 아래 6.이 그 Application을 대신 렌더한다.
APPSET_RENDERERS.data = (set, restore) => {
  const gens: any[] = set.spec?.generators ?? [];
  const files = (gens[0]?.git?.files ?? []).map((f: any) => f.path).join(",");
  if (gens.length !== 1 || files !== "data/*/values.yaml" || gens[0].git?.values?.app !== "{{ .path.basename }}") {
    return "생성기가 data/*/values.yaml git 생성기 하나(values.app = 디렉터리 이름)가 아니다";
  }
  const t = set.spec?.template ?? {};
  const src = t.spec?.source ?? {};
  if (
    t.metadata?.name !== "{{ .values.app }}-data" ||
    t.spec?.destination?.namespace !== "app-{{ .values.app }}" ||
    src.path !== "platform/charts/app-data" ||
    src.targetRevision !== "data-chart-v{{ .chartVersion }}" ||
    JSON.stringify(src.helm) !== '{"releaseName":"{{ .values.app }}"}' ||
    t.spec?.sources !== undefined
  ) {
    return "템플릿 이름·ns·source가 render.ts의 데이터 렌더(<앱>-data, 릴리스 <앱>, platform/charts/app-data@data-chart-v<chartVersion>)와 다르다";
  }
  const patch = String(set.spec?.templatePatch ?? "");
  if (patch.includes(ES_PATCH_LINE) !== restore.externalSecretsOff) return "templatePatch의 복구 스위치 주입(externalSecrets)이 클러스터 값과 다르다";
  const apps = Object.keys(restore.valkey).sort();
  if (apps.length === 0 && !restore.externalSecretsOff) {
    if (!patch.includes('omit . "path" "values" "backup" | toYaml')) return "templatePatch의 값 합치기가 render.ts와 다르다";
    return true;
  }
  const want = ['{{- $v := omit . "path" "values" "backup" }}', "{{- $v | toYaml | nindent 8 }}"];
  // 복구 멈춤: 맵의 앱에만 valkey.running·restoreMode를 모드 값으로 다시 쓴다(아래 6.과 같은 전개).
  if (apps.length > 0) {
    const pairs = apps.map((a) => `${JSON.stringify(a)} ${JSON.stringify(String(restore.valkey[a]))}`).join(" ");
    want.push(
      `{{- $mode := get (dict ${pairs}) .values.app }}`,
      '{{- $vk := omit (get $v "valkey" | default dict) "running" "restoreMode" }}',
      '{{- $_ := set $vk "running" (eq $mode "restoreMode") }}',
      '{{- $_ := set $vk "restoreMode" true }}',
      '{{- $_ := set $v "valkey" $vk }}',
    );
  }
  if (want.some((w) => !patch.includes(w))) return "templatePatch의 복구 주입(valkeyRestore·externalSecrets)이 render.ts의 전개와 다르다";
  return true;
};

// 클러스터 값 파일의 백업 버킷(cluster.backup.bucket). ApplicationSet data가 데이터 values에 넣는 값과 같다.
function clusterBuckets(clusterFiles: string[]): [string, string | undefined][] {
  return clusterFiles.map((vf) => {
    const cluster = vf.replace(/^platform\/root\/values-/, "").replace(/\.yaml$/, "");
    const v = Bun.YAML.parse(readFileSync(join(ROOT, vf), "utf8")) as any;
    const bucket = v?.cluster?.backup?.bucket;
    return [cluster, typeof bucket === "string" ? bucket : undefined];
  });
}

// 렌더 결과 캐시. 같은 차트·값이면 결과가 같으므로 켠 렌더와 끈 렌더(tools/ci/switch.ts)가 함께 쓴다.
// kustomize 원격 base(argocd install.yaml)를 두 번 받지 않는다. 기본 렌더 결과도 한 번만 만든다.
const cache = new Map<string, { ok: boolean; out: string }>();
let defaultResult: RenderResult | undefined;

export function renderAll(opts: RenderOptions = {}): RenderResult {
  const plain = !opts.rootOverlay && !opts.chartOverlay;
  if (plain && defaultResult) return defaultResult;
  const res: RenderResult = { targets: [], docs: [], violations: [], skipped: [] };
  const tmp = tempDir("render");
  const covered = new Set<string>();

  const add = (origin: string, text: string, ns?: string) => {
    res.targets.push({ origin, text });
    try {
      for (const obj of parseAll(text)) {
        if (typeof obj === "object" && !Array.isArray(obj)) res.docs.push({ origin, obj, ns });
      }
    } catch (e) {
      res.violations.push({ rule: "render", where: origin, message: `YAML 파싱 실패: ${(e as Error).message}` });
    }
  };
  const fail = (origin: string, message: string) => res.violations.push({ rule: "render", where: origin, message });

  // 모든 로컬 차트 렌더(Application source, 시험 values) 앞의 공통 검사. Argo CD는 대상 클러스터의 API 목록·버전을
  // Helm에 넘기고 CI는 그것을 재현하지 않으므로 Capabilities 자체를 막는다. 별칭($c := .Capabilities)이나 index로
  // 돌아가도 이름은 남으므로 토큰으로 찾는다. 의존 차트(charts/<dep>, charts/*.tgz)도 본다. 지금 쓰는 차트는 없다.
  const capsOk = (where: string, chartDir: string): boolean => {
    const caps = templateFiles(chartDir, tmp).filter((f) => /\bCapabilities\b/.test(readFileSync(f, "utf8")));
    if (caps.length === 0) return true;
    fail(where, `로컬 차트가 Capabilities를 쓴다(CI 렌더와 Argo CD 렌더가 달라진다): ${caps.map((f) => (f.startsWith(tmp) ? `(묶음 의존 차트) ${relative(join(tmp, "deps"), f)}` : relative(ROOT, f))).join(", ")}`);
    return false;
  };

  // Application 하나의 자기 저장소 source를 렌더한다. 렌더한 텍스트를 돌려준다(실패·외부 source면 undefined).
  const renderSource = (app: any, cluster: string, src: any): string | undefined => {
    const name = app.metadata?.name;
    if (!sameRepo(src.repoURL)) {
      // 외부 Helm 차트만 렌더하지 않는다(revision은 정책이 정확한 semver로 묶는다). 외부 git source는 렌더하지 않으면
      // 그 매니페스트가 검사 없이 배포되므로 받지 않는다. 필요해지면 이 파일이 그 SHA를 받아 렌더하도록 넓힌다.
      if (!src.chart) {
        fail(`${name}[${cluster}]`, `외부 git source(${src.repoURL})는 렌더 검사를 못 해 받지 않는다`);
        return undefined;
      }
      res.skipped.push(`${name}[${cluster}]: ${src.repoURL} ${src.chart}@${src.targetRevision ?? ""}`);
      return undefined;
    }
    if (src.ref && !src.path) return undefined; // 값 파일 참조용 source는 렌더 대상이 아니다
    const path: string = src.path;
    const where = `${name}[${cluster}]:${path}`;
    const unknownKeys = Object.keys(src).filter((k) => !SOURCE_KEYS.has(k));
    if (unknownKeys.length > 0) {
      fail(where, `render.ts가 재현하지 않는 source 필드: ${unknownKeys.join(", ")}. Argo CD와 같게 렌더하도록 이 파일을 넓힌다`);
      return undefined;
    }
    if (!path || !existsSync(join(ROOT, path))) {
      fail(where, "source path가 저장소에 없다");
      return undefined;
    }
    covered.add(path);
    const ns = app.spec?.destination?.namespace;
    // main이 아닌 revision(공유 차트 태그, 정책이 그것만 허용)은 그 태그의 트리로 렌더한다. 작업 트리로 렌더하면
    // 태그 뒤에 바뀐 차트를 검사해 Argo CD가 실제로 쓰는 옛 차트를 놓친다.
    let srcDir = path;
    if (src.targetRevision !== "main") {
      try {
        srcDir = pathAtRevision(String(src.targetRevision), path, tmp);
      } catch (e) {
        fail(where, (e as Error).message);
        return undefined;
      }
    }
    const isChart = existsSync(join(srcDir.startsWith("/") ? srcDir : join(ROOT, srcDir), "Chart.yaml"));
    if (src.helm && !isChart) {
      fail(where, "helm 필드가 있는데 Chart.yaml이 없다");
      return undefined;
    }
    let r: { ok: boolean; out: string };
    if (isChart) {
      // Argo CD는 대상 클러스터의 API 목록·버전을 Helm에 넘긴다. CI는 그것을 재현하지 않으므로 Capabilities 자체를 막는다.
      // 별칭($c := .Capabilities)이나 index로 돌아가도 이름은 남으므로 토큰으로 찾는다. 의존 차트(charts/)도 본다.
      // 지금 쓰는 차트는 없다.
      if (!capsOk(where, srcDir)) return undefined;
      const helm = src.helm ?? {};
      const unknown = Object.keys(helm).filter((k) => !HELM_KEYS.has(k));
      if (unknown.length > 0) {
        fail(where, `render.ts가 재현하지 않는 helm 필드: ${unknown.join(", ")}`);
        return undefined;
      }
      const files: string[] = [];
      for (const f of helm.valueFiles ?? []) {
        if (String(f).startsWith("$")) {
          fail(where, `ref 값 파일(${f})은 렌더하지 않는다. 같은 저장소의 다른 revision 참조는 Argo CD가 거부한다`);
          return undefined;
        }
        files.push(join(srcDir, f));
      }
      if (helm.valuesObject) {
        const vfile = join(tmp, `${name}-${cluster}-values.json`);
        writeFileSync(vfile, JSON.stringify(helm.valuesObject));
        files.push(vfile);
      }
      const release = helm.releaseName ?? name;
      const key = JSON.stringify(["helm", srcDir, ns, release, helm.valueFiles ?? [], helm.valuesObject ?? null]);
      r = cache.get(key) ?? helmTemplate(release, srcDir, ns, files);
      cache.set(key, r);
    } else if (srcDir !== path) {
      fail(where, "main이 아닌 revision은 공유 차트만 받는다");
      return undefined;
    } else if (isKustomizeDir(path)) {
      const key = JSON.stringify(["kustomize", path]);
      r = cache.get(key) ?? kustomizeBuild(path);
      cache.set(key, r);
    } else {
      r = plainDir(path);
    }
    if (!r.ok) {
      fail(where, r.out.trim());
      return undefined;
    }
    add(where, r.out, ns);
    return r.out;
  };

  // 1. root, 클러스터마다(root-<클러스터>.yaml의 선언대로)
  const rootFiles = gitFiles("platform/root/root-*.yaml");
  const valueFiles = new Set(gitFiles("platform/root/values-*.yaml"));
  if (rootFiles.length === 0) fail("platform/root", "root Application 파일(root-<클러스터>.yaml)이 0개다");
  const clusterFiles: string[] = [];
  for (const rf of rootFiles) {
    const text = readFileSync(join(ROOT, rf), "utf8");
    // root 파일 자체도 검사 대상이다(revision, kubeconform). templates/ 밖이라 root가 렌더하지 않는다.
    add(rf, text);
    const roots = parseAll(text).filter((d) => d?.kind === "Application");
    const cluster = rf.replace(/^platform\/root\/root-/, "").replace(/\.yaml$/, "");
    if (roots.length !== 1 || roots[0].metadata?.name !== `root-${cluster}`) {
      fail(rf, `Application root-${cluster} 하나만 둔다`);
      continue;
    }
    // spec.sources가 있으면 Argo CD는 단수 source를 무시한다. root는 source 하나로만 둔다.
    if (roots[0].spec?.sources !== undefined) {
      fail(rf, `root-${cluster}에 spec.sources를 두지 않는다(있으면 Argo CD가 spec.source를 무시한다)`);
      continue;
    }
    const src = roots[0].spec?.source ?? {};
    const want = `values-${cluster}.yaml`;
    if (src.path !== "platform/root" || JSON.stringify(src.helm?.valueFiles) !== JSON.stringify([want]) || src.helm?.valuesObject) {
      fail(rf, `root-${cluster}는 platform/root를 helm.valueFiles [${want}] 하나로만 렌더한다`);
      continue;
    }
    valueFiles.delete(`platform/root/${want}`);
    clusterFiles.push(`platform/root/${want}`);
    // 덧씌우기는 valuesObject로 넘긴다. Argo CD와 같이 valueFiles 위에 합쳐진다(renderSource). root 파일 검사는 위에서 끝났다.
    const out = renderSource(roots[0], cluster, opts.rootOverlay ? { ...src, helm: { ...src.helm, valuesObject: opts.rootOverlay } } : src);
    if (out === undefined) continue;
    // 2. root가 만든 Application의 자기 저장소 source. 렌더 결과에 다시 Application이 있으면(app-of-apps) 그것도 따라간다.
    const visit = (text: string, depth: number) => {
      // ApplicationSet이 만드는 Application도 검사해야 한다. 어느 단계에서 나오든 여기서 전개하는 것만 받는다(아래 5.).
      for (const set of parseAll(text).filter((d) => d?.kind === "ApplicationSet")) {
        const ok = APPSET_RENDERERS[set.metadata?.name]?.(set, clusterRestore(`platform/root/values-${cluster}.yaml`, opts.rootOverlay));
        if (ok !== true) fail(`${set.metadata?.name}[${cluster}]`, `ApplicationSet ${set.metadata?.name}: ${ok ?? "render.ts가 전개하지 않는 ApplicationSet이다"}`);
      }
      for (const app of parseAll(text).filter((d) => d?.kind === "Application")) {
        if (depth > 3) {
          fail(`${app.metadata?.name}[${cluster}]`, "Application 중첩이 너무 깊다(3단계까지)");
          continue;
        }
        const sources = effectiveSources(app.spec);
        for (const s2 of sources) {
          const t2 = renderSource(app, cluster, s2);
          if (t2 === undefined) continue;
          visit(t2, depth + 1);
        }
      }
    };
    visit(out, 1);
  }
  for (const vf of valueFiles) fail(vf, "이 값 파일을 읽는 root-<클러스터>.yaml이 없다");
  // 복구 멈춤 값의 이름이 등록된 앱인지. ApplicationSet은 없는 이름을 조용히 지나가 그 앱이 멈추지 않는다(빈 DB로 뜬다).
  const appDirs = new Set(gitFiles("apps/*/values.yaml").map((f) => basename(dirname(f))));
  const dataDirs = new Set(gitFiles("data/*/values.yaml").map((f) => basename(dirname(f))));
  for (const vf of clusterFiles) {
    const r = clusterRestore(vf);
    for (const a of r.suspendedApps.filter((a) => !appDirs.has(a))) fail(vf, `cluster.restore.suspendedApps의 ${a}: apps/${a}/values.yaml이 없다`);
    for (const a of Object.keys(r.valkey).filter((a) => !dataDirs.has(a))) fail(vf, `cluster.restore.valkey의 ${a}: data/${a}/values.yaml이 없다`);
  }

  // 3. 나머지 kustomization(덧씌운 렌더는 건너뛴다, RenderOptions)
  for (const f of plain ? gitFiles(...KUSTOMIZATION_FILES.map((n) => `:(glob)platform/**/${n}`)) : []) {
    const dir = dirname(f);
    if (covered.has(dir)) continue;
    covered.add(dir);
    const r = kustomizeBuild(dir);
    if (!r.ok) fail(`kustomize:${dir}`, r.out.trim());
    else add(`kustomize:${dir}`, r.out);
  }

  // 4. 로컬 차트의 시험 values(<차트>/ci/*.yaml). 공유 차트(platform/charts/*)는 늘 하나 이상 있어야 한다.
  //    root가 아직 렌더하지 않는 로컬 차트(꺼진 구성 요소)도 시험 values가 있어야 한다. 켜기 전에 틀린 템플릿이 들어오지 않게.
  for (const c of gitFiles(":(glob)platform/**/Chart.yaml")) {
    const dir = dirname(c);
    if (dir === "platform/root") continue;
    // 다른 차트의 의존 차트(<차트>/charts/<dep>)는 부모 차트 렌더에 들어간다. 따로 시험 values를 요구하지 않는다.
    if (dirname(dir).endsWith("/charts") && existsSync(join(ROOT, dirname(dirname(dir)), "Chart.yaml"))) continue;
    const ciFiles = gitFiles(`${dir}/ci/*.yaml`);
    if (ciFiles.length === 0) {
      // 덧씌운 렌더에서는 끄는 Application(Store 등)의 차트가 렌더되지 않는다. 이 검사는 켠 렌더가 한다.
      if (plain && (dir.startsWith("platform/charts/") || !covered.has(dir))) fail(dir, "차트 시험 values(ci/*.yaml)가 없다(공유 차트이거나 root가 아직 렌더하지 않는 차트)");
      continue;
    }
    const chart = relative(dirname(dir), dir);
    if (!capsOk(`chart:${relative("platform", dir)}`, dir)) continue;
    for (const f of ciFiles) {
      const origin = `chart:${relative("platform", dir)}/${relative(dir, f)}`;
      const files = [f];
      if (opts.chartOverlay) {
        const vfile = join(tmp, `chart-overlay-${relative("platform", dir).replaceAll("/", "_")}.json`);
        writeFileSync(vfile, JSON.stringify(opts.chartOverlay));
        files.push(vfile);
      }
      const key = JSON.stringify(["chart-ci", dir, f, opts.chartOverlay ?? null]);
      const r = cache.get(key) ?? helmTemplate(chart, dir, `app-${chart}`, files);
      cache.set(key, r);
      if (!r.ok) fail(origin, r.out.trim());
      else add(origin, r.out);
    }
  }

  // 5. 등록된 앱(apps/<앱>/values.yaml). ApplicationSet apps(platform/appsets/apps/files/applicationset.yaml)와
  //    같게 values.yaml + image.yaml + 클러스터 tailnet 접두를 values로, 차트는 그 앱의 태그로 렌더한다.
  //    그 클러스터의 복구 멈춤 목록(cluster.restore.suspendedApps)에 있으면 suspended: true로 덮는다.
  //    복구 스위치를 끈 클러스터에서 스위치를 모르는 옛 차트 앱은 렌더하지 않고 원인을 적어 실패로 둔다(ES_SWITCH_SINCE).
  //    값 합치기가 실제 templatePatch 실행 결과와 같은지는 tools/ci/appset-patch.ts가 본다.
  //    앱이 0개인 것은 정상이라 세지 않는다.
  for (const vf of gitFiles("apps/*/values.yaml")) {
    const app = basename(dirname(vf));
    for (const [cluster, prefix] of clusterPrefixes(clusterFiles)) {
      const where = `app:${app}[${cluster}]`;
      const restore = clusterRestore(`platform/root/values-${cluster}.yaml`, opts.rootOverlay);
      try {
        // ApplicationSet은 path·values를 생성기 변수로 덮고 tailnetPrefix는 클러스터 값으로 덮는다. 사람이 적은 같은 키는
        // 조용히 사라지므로(예: probe 경로를 최상위 path로 적음) 지우지 않고 실패로 둔다. 두 파일의 키도 서로 겹치지 않는다.
        const human = (Bun.YAML.parse(readFileSync(join(ROOT, vf), "utf8")) ?? {}) as Record<string, any>;
        const imageFile = join(ROOT, "apps", app, "image.yaml");
        const image = (existsSync(imageFile) ? Bun.YAML.parse(readFileSync(imageFile, "utf8")) ?? {} : {}) as Record<string, any>;
        // cacheServer는 차트 내부 값(공식 valkey 차트)이다. 앱 values가 덮으면 이미지·인증·크기를 바꿀 수 있다.
        // global도 의존 차트로 내려간다(global.imageRegistry가 고정한 이미지 레지스트리를 덮는다).
        // externalSecrets는 복구 스위치라 ApplicationSet만 넣는다. 공용 values에 적으면 운영 앱도 꺼진다.
        const reserved = ["path", "values", "tailnetPrefix", "cacheServer", "global", "externalSecrets"];
        const imageKeys = ["repository", "digest", "revision", "hold"];
        const badHuman = Object.keys(human).filter((k) => reserved.includes(k) || imageKeys.includes(k));
        const badImage = Object.keys(image).filter((k) => !imageKeys.includes(k));
        if (badHuman.length > 0) throw new Error(`values.yaml에 둘 수 없는 키: ${badHuman.join(", ")}(생성기 변수·클러스터 값·복구 스위치·image.yaml 키)`);
        if (badImage.length > 0) throw new Error(`image.yaml에는 ${imageKeys.join(", ")}만 둔다: ${badImage.join(", ")}`);
        const values = appValues(app, { ...human, ...image }, prefix, restore);
        const old = restore.externalSecretsOff ? esSwitchUnsupported("app", app, values.chartVersion) : undefined;
        if (old) {
          res.violations.push({ rule: ES_CHART_RULE, where, message: old });
          continue;
        }
        const chartDir = pathAtRevision(`app-chart-v${values.chartVersion}`, "platform/charts/app", tmp);
        const vfile = join(tmp, `app-${app}-${cluster}.json`);
        writeFileSync(vfile, JSON.stringify(values));
        const r = helmTemplate(app, chartDir, `app-${app}`, [vfile]);
        if (!r.ok) fail(where, r.out.trim());
        else add(where, r.out, `app-${app}`);
      } catch (e) {
        fail(where, (e as Error).message);
      }
    }
  }

  // 6. 등록된 데이터(data/<앱>/values.yaml). ApplicationSet data(platform/appsets/data/files/applicationset.yaml)와
  //    같게 values.yaml + 클러스터 백업 버킷을 values로, 릴리스 이름은 앱 이름, 차트는 그 앱의 태그로 렌더한다.
  //    그 클러스터의 복구 멈춤 맵(cluster.restore.valkey)에 있으면 valkey.running·restoreMode를 모드 값으로 다시 쓴다.
  //    복구 스위치와 옛 차트, templatePatch 실행 대조는 5.와 같다.
  for (const vf of gitFiles("data/*/values.yaml")) {
    const app = basename(dirname(vf));
    for (const [cluster, bucket] of clusterBuckets(clusterFiles)) {
      const where = `data:${app}[${cluster}]`;
      const restore = clusterRestore(`platform/root/values-${cluster}.yaml`, opts.rootOverlay);
      try {
        const human = (Bun.YAML.parse(readFileSync(join(ROOT, vf), "utf8")) ?? {}) as Record<string, any>;
        // valkeyServer·global은 차트 내부 값(공식 valkey 차트로 내려간다)이다. backup은 클러스터 값이라 ApplicationSet이 덮는다.
        // externalSecrets는 복구 스위치라 ApplicationSet만 넣는다(앱과 같은 이유).
        const bad = Object.keys(human).filter((k) => ["path", "values", "backup", "valkeyServer", "global", "externalSecrets"].includes(k));
        if (bad.length > 0) throw new Error(`data values.yaml에 둘 수 없는 키: ${bad.join(", ")}(생성기 변수·클러스터 값·차트 내부 값·복구 스위치)`);
        if (bucket === undefined) throw new Error(`platform/root/values-${cluster}.yaml에 cluster.backup.bucket이 없다`);
        const values = dataValues(app, human, bucket, restore);
        const old = restore.externalSecretsOff ? esSwitchUnsupported("data", app, values.chartVersion) : undefined;
        if (old) {
          res.violations.push({ rule: ES_CHART_RULE, where, message: old });
          continue;
        }
        const chartDir = pathAtRevision(`data-chart-v${values.chartVersion}`, "platform/charts/app-data", tmp);
        const vfile = join(tmp, `data-${app}-${cluster}.json`);
        writeFileSync(vfile, JSON.stringify(values));
        const r = helmTemplate(app, chartDir, `app-${app}`, [vfile]);
        if (!r.ok) fail(where, r.out.trim());
        else add(where, r.out, `app-${app}`);
      } catch (e) {
        fail(where, (e as Error).message);
      }
    }
  }

  if (res.targets.length === 0) fail("render", "렌더 대상이 0개다(찾는 식이 깨졌을 수 있다, L40)");
  if (plain) defaultResult = res;
  return res;
}

// 렌더 결과를 파일로 써서 kubeconform에 넘긴다. 스키마는 커밋 SHA로 고정한 주소에서 받는다(태그·브랜치는 움직인다).
// CRD 스키마가 없는 kind는 실패로 둔다. 빠뜨리면 CRD 오타가 초록으로 지나간다. 건너뛰는 kind는 없다.
const K8S_SCHEMAS =
  "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/93153a1458e24e93f386c50f9980d584fcba574b/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json";
// standalone 묶음에 없는 kind(CustomResourceDefinition)만 $ref를 쓰는 묶음에서 찾는다. 같은 커밋이다.
const K8S_SCHEMAS_REFS =
  "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/93153a1458e24e93f386c50f9980d584fcba574b/{{.NormalizedKubernetesVersion}}/{{.ResourceKind}}{{.KindSuffix}}.json";
const CRD_SCHEMAS =
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/501527ab9c40c827144c8f45945b25a023e344ce/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json";

export function kubeconform(targets: Rendered[]): Violation[] {
  const dir = tempDir("kubeconform");
  targets.forEach((t, i) => writeFileSync(join(dir, `${String(i).padStart(3, "0")}.yaml`), t.text));
  const cacheDir = process.env.KUBECONFORM_CACHE ?? tempDir("kubeconform-cache");
  const r = run([
    "kubeconform",
    "-strict",
    "-summary",
    "-output",
    "json",
    "-kubernetes-version",
    kubeVersion(),
    "-cache",
    cacheDir,

    "-schema-location",
    K8S_SCHEMAS,
    "-schema-location",
    CRD_SCHEMAS,
    "-schema-location",
    K8S_SCHEMAS_REFS,
    dir,
  ]);
  const out: Violation[] = [];
  let report: any;
  try {
    report = JSON.parse(r.stdout);
  } catch {
    return [{ rule: "kubeconform", where: "kubeconform", message: `출력을 읽지 못했다(exit ${r.code})\n${r.stderr}` }];
  }
  for (const res of report.resources ?? []) {
    if (res.status === "statusValid") continue;
    const idx = Number(String(res.filename).match(/(\d+)\.yaml$/)?.[1]);
    const origin = targets[idx]?.origin ?? res.filename;
    out.push({ rule: "kubeconform", where: `${origin} ${res.kind}/${res.name}`, message: `${res.status}: ${res.msg}` });
  }
  const summary = report.summary ?? {};
  console.log(`kubeconform: valid ${summary.valid ?? 0}, invalid ${summary.invalid ?? 0}, errors ${summary.errors ?? 0}, skipped ${summary.skipped ?? 0}`);
  if ((summary.valid ?? 0) === 0) out.push({ rule: "kubeconform", where: "kubeconform", message: "검사한 리소스가 0개다(L40)" });
  if (r.code !== 0 && out.length === 0) out.push({ rule: "kubeconform", where: "kubeconform", message: `exit ${r.code}\n${r.stderr}` });
  return out;
}
