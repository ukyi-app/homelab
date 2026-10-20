// 저장소가 Argo CD에 내는 매니페스트를 Argo CD와 같은 방식으로 렌더한다(설계 C.4.6 "렌더 + 스키마").
//
// 대상은 디렉터리 목록을 적지 않고 찾는다.
// 1. root 차트를 클러스터 값 파일(platform/root/values-<클러스터>.yaml)마다 렌더한다.
// 2. 그 렌더의 Application 중 이 저장소를 가리키는 source를 그 Application이 넘기는 값(valuesObject 등)으로 렌더한다.
//    외부 Helm 저장소의 차트는 렌더하지 않는다. 외부 레지스트리 조회는 필수 검사에 넣지 않는다(설계 C.4.6, P27).
// 3. 위에서 안 다룬 추적 kustomization도 모두 build한다(꺼진 구성 요소도 깨지지 않게).
// 4. 차트의 시험 values(platform/charts/<차트>/ci/*.yaml)로 렌더한다. 공유 차트 PR은 어느 앱에도 바로 적용되지 않으므로
//    이것이 그 PR의 렌더 검사다(설계 C.4.5).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { type Doc, type Violation, ROOT, gitFiles, parseAll, run, sameRepo, tempDir, toolVersion } from "./lib";

export type Rendered = { origin: string; text: string };
export type RenderResult = { targets: Rendered[]; docs: Doc[]; violations: Violation[]; skipped: string[] };

const HELM_KEYS = new Set(["valuesObject", "valueFiles", "releaseName"]);

export function kubeVersion(): string {
  return toolVersion("kubectl");
}

function helmTemplate(release: string, chartDir: string, namespace: string | undefined, valueFiles: string[]): { ok: boolean; out: string } {
  const args = ["helm", "template", release, chartDir, "--kube-version", kubeVersion()];
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

function plainDir(dir: string): { ok: boolean; out: string } {
  // Argo CD directory 소스의 기본값(recurse 없음)과 같이 바로 아래 YAML만.
  const files = gitFiles(`${dir}/*.yaml`, `${dir}/*.yml`).filter((f) => dirname(f) === dir);
  if (files.length === 0) return { ok: false, out: `${dir}에 YAML이 없다` };
  return { ok: true, out: files.map((f) => readFileSync(join(ROOT, f), "utf8")).join("\n---\n") };
}

export function renderAll(): RenderResult {
  const res: RenderResult = { targets: [], docs: [], violations: [], skipped: [] };
  const tmp = tempDir("render");
  const cache = new Map<string, { ok: boolean; out: string }>();
  const covered = new Set<string>();

  const add = (origin: string, text: string) => {
    res.targets.push({ origin, text });
    try {
      for (const obj of parseAll(text)) {
        if (typeof obj === "object" && !Array.isArray(obj)) res.docs.push({ origin, obj });
      }
    } catch (e) {
      res.violations.push({ rule: "render", where: origin, message: `YAML 파싱 실패: ${(e as Error).message}` });
    }
  };
  const fail = (origin: string, message: string) => res.violations.push({ rule: "render", where: origin, message });

  // 1. root, 클러스터마다
  const clusterFiles = gitFiles("platform/root/values-*.yaml");
  if (clusterFiles.length === 0) fail("platform/root", "클러스터 값 파일(values-<클러스터>.yaml)이 0개다");
  for (const vf of clusterFiles) {
    const cluster = vf.replace(/^platform\/root\/values-/, "").replace(/\.yaml$/, "");
    const origin = `root[${cluster}]`;
    const r = helmTemplate("root", "platform/root", undefined, [vf]);
    if (!r.ok) {
      fail(origin, r.out.trim());
      continue;
    }
    add(origin, r.out);

    // 2. root가 만든 Application의 자기 저장소 source
    for (const app of parseAll(r.out).filter((d) => d?.kind === "Application")) {
      const name = app.metadata?.name;
      const sources: any[] = app.spec?.sources ?? (app.spec?.source ? [app.spec.source] : []);
      for (const src of sources) {
        if (!sameRepo(src.repoURL)) {
          res.skipped.push(`${name}[${cluster}]: ${src.repoURL} ${src.chart ?? src.path ?? ""}@${src.targetRevision ?? ""}`);
          continue;
        }
        if (src.ref && !src.path) continue; // 값 파일 참조용 source는 렌더 대상이 아니다
        const path: string = src.path;
        const where = `${name}[${cluster}]:${path}`;
        if (!path || !existsSync(join(ROOT, path))) {
          fail(where, `source path가 저장소에 없다`);
          continue;
        }
        covered.add(path);
        const ns = app.spec?.destination?.namespace;
        let r2: { ok: boolean; out: string };
        if (existsSync(join(ROOT, path, "Chart.yaml"))) {
          const helm = src.helm ?? {};
          const unknown = Object.keys(helm).filter((k) => !HELM_KEYS.has(k));
          if (unknown.length > 0) {
            fail(where, `render.ts가 모르는 helm 필드: ${unknown.join(", ")}. Argo CD와 같게 렌더하도록 이 파일을 넓힌다`);
            continue;
          }
          const files: string[] = [];
          for (const f of helm.valueFiles ?? []) {
            if (String(f).startsWith("$")) {
              fail(where, `ref 값 파일(${f})은 렌더하지 않는다. 같은 저장소의 다른 revision 참조는 Argo CD가 거부한다`);
              continue;
            }
            files.push(join(path, f));
          }
          if (helm.valuesObject) {
            const vfile = join(tmp, `${name}-${cluster}-values.json`);
            writeFileSync(vfile, JSON.stringify(helm.valuesObject));
            files.push(vfile);
          }
          const key = JSON.stringify(["helm", path, ns, helm.releaseName ?? name, helm.valueFiles ?? [], helm.valuesObject ?? null]);
          r2 = cache.get(key) ?? helmTemplate(helm.releaseName ?? name, path, ns, files);
          cache.set(key, r2);
        } else if (existsSync(join(ROOT, path, "kustomization.yaml"))) {
          const key = JSON.stringify(["kustomize", path]);
          r2 = cache.get(key) ?? kustomizeBuild(path);
          cache.set(key, r2);
        } else {
          r2 = plainDir(path);
        }
        if (!r2.ok) fail(where, r2.out.trim());
        else add(where, r2.out);
      }
    }
  }

  // root Application 파일 자체(templates/ 밖이라 렌더되지 않는다). 사람이 kubectl apply하는 파일도 revision을 본다.
  for (const f of gitFiles("platform/root/root-*.yaml")) add(f, readFileSync(join(ROOT, f), "utf8"));

  // 3. 나머지 kustomization
  for (const f of gitFiles(":(glob)platform/**/kustomization.yaml", ":(glob)platform/**/kustomization.yml")) {
    const dir = dirname(f);
    if (covered.has(dir)) continue;
    const r = kustomizeBuild(dir);
    if (!r.ok) fail(`kustomize:${dir}`, r.out.trim());
    else add(`kustomize:${dir}`, r.out);
  }

  // 4. 차트 시험 values
  for (const f of gitFiles(":(glob)platform/charts/*/ci/*.yaml")) {
    const chartDir = dirname(dirname(f));
    const chart = relative("platform/charts", chartDir);
    const origin = `chart:${chart}/${relative(chartDir, f)}`;
    const r = helmTemplate(chart, chartDir, `app-${chart}-ci`, [f]);
    if (!r.ok) fail(origin, r.out.trim());
    else add(origin, r.out);
  }

  if (res.targets.length === 0) fail("render", "렌더 대상이 0개다(찾는 식이 깨졌을 수 있다, L40)");
  return res;
}

// 렌더 결과를 파일로 써서 kubeconform에 넘긴다. 스키마는 커밋 SHA로 고정한 주소에서 받는다(태그·브랜치는 움직인다).
// CRD 스키마가 없는 kind는 실패로 둔다. 빠뜨리면 CRD 오타가 초록으로 지나간다.
// 예외는 CustomResourceDefinition 자체 하나다. 스키마 저장소가 그 kind를 싣지 않고, 렌더에 나오는 CRD는
// 버전을 고정한 상류 매니페스트(Argo CD install.yaml)뿐이다.
const K8S_SCHEMAS =
  "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/93153a1458e24e93f386c50f9980d584fcba574b/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json";
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
    "-skip",
    "CustomResourceDefinition",
    "-schema-location",
    K8S_SCHEMAS,
    "-schema-location",
    CRD_SCHEMAS,
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
