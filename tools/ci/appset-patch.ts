// ApplicationSet apps·data의 templatePatch를 실제로 실행해 본다(T23 할 일 1, 복구 스위치·복구 멈춤 주입).
// render.ts 5.·6.은 생성될 Application의 values를 직접 만들어(appValues, dataValues) 공유 차트를 렌더하고, APPSET_RENDERERS는
// templatePatch에 주입 줄이 들어 있는지만 본다. 그 줄을 {{- if false }}로 감싸 실행되지 않게 해도 둘 다 통과한다.
// 그래서 렌더된 ApplicationSet의 templatePatch를 견본 입력으로 실행하고 다음을 본다.
// 1. 결과 helm.valuesObject가 render.ts의 재현과 같다. 함께 넣는 값(tailnetPrefix·suspended, backup.bucket·valkey.running·
//    restoreMode)과 복구 스위치 값은 재현과 따로 한 번 더 본다. 재현과 patch가 같은 방향으로 틀리면 1.만으로는 못 잡는다.
// 2. 그 valuesObject로 작업 트리 공유 차트를 렌더하면 스위치를 끈 경우 ExternalSecret 0개, 켠 경우 0이 아니다(0건 통과 금지).
// 3. 끈 경우가 apps·data 모두 있고, 복구 멈춤과 함께 쓰는 경우(suspendedApps, valkey stopped·restoreMode)도 있다.
//    ApplicationSet 차트 시험 values(platform/appsets/*/ci)가 빠지면 조용히 덜 보지 않게 실패로 둔다.
//
// 실행기는 Helm tpl(임시 차트)이다. Argo CD v3.5.5는 templatePatch를 text/template + sprig v3.3.0으로 실행해 그 YAML을
// Application에 strategic merge patch한다(applicationset/controllers/template/template.go renderTemplatePatch,
// patch.go applyTemplatePatch). Helm 4.2.1도 sprig v3.3.0이다. 차이와 대응:
// - 함수: Argo CD는 sprig GenericFuncMap에서 env·expandenv·getHostByName을 빼고 normalize·slugify·toYaml·fromYaml·
//   fromYamlArray를 더한다(applicationset/utils/utils.go init). Helm은 env·expandenv만 빼고 include·tpl·required·lookup·
//   toToml 등을 더한다(pkg/engine/funcs.go, engine.go). Helm에만 있는 함수는 여기서 돌고 Argo CD에서는 생성 오류로 모든 앱
//   갱신을 멈추므로 HELM_ONLY로 막는다. Argo CD에만 있는 normalize·slugify는 여기서 실패한다(CI가 빨개지는 안전한 쪽).
// - toYaml: 둘 다 sigs.k8s.io/yaml Marshal 뒤 끝 줄바꿈을 뗀다. 직렬화 오류 때 Argo CD는 실패, Helm은 빈 문자열이다.
// - 없는 키: Argo CD는 goTemplateOptions가 없으면 "<no value>"를 그대로 내고, Helm tpl은 missingkey=zero에 빈 문자열이다.
//   견본 입력은 patch가 읽는 키(.values.app)를 갖는다. 새 patch가 다른 키를 읽으면 견본에도 넣는다.
// - 입력: Argo CD git 생성기는 파일을 sigs.k8s.io/yaml로 읽어 map(숫자 float64, null 유지)으로 넘긴다. 여기서는 JSON 문자열을
//   fromJson으로 풀어 같은 모양으로 넘긴다. Helm values로 넘기면 병합이 null 키를 지운다.
// - 적용: 생성 템플릿의 source.helm에는 valuesObject가 없어(data는 releaseName만) 병합 결과가 patch 값 그대로다.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Doc, type Violation, parseAll, readText, tempDir } from "./lib";
import { type Restore, type RootOverlay, appValues, clusterRestore, dataValues, helmTemplate } from "./render";

type Kind = "apps" | "data";
// 견본 입력. 공유 차트 시험 values 중 ExternalSecret을 모두 내는 것(앱: 앱 시크릿·DB·Valkey URL·캐시 인증, 데이터: DB 역할·영속 Valkey).
const SAMPLE: Record<Kind, { chart: string; values: string; dir: string }> = {
  apps: { chart: "platform/charts/app", values: "platform/charts/app/ci/web-full.yaml", dir: "apps" },
  data: { chart: "platform/charts/app-data", values: "platform/charts/app-data/ci/persistent.yaml", dir: "data" },
};
// 복구 목록에 없는 앱 이름. 복구 스위치는 목록과 상관없이 모든 앱에 들어가야 한다.
const OTHER = "patch-probe";
// Helm 4.2.1 tpl에는 있고 Argo CD v3.5.5 ApplicationSet에는 없는 함수(위 머리 주석).
const HELM_ONLY = new Set(["include", "tpl", "required", "lookup", "toToml", "mustToToml", "fromToml", "mustToYaml", "toYamlPretty", "fromJsonArray", "getHostByName"]);

// 렌더 한 벌과 그 렌더에 얹은 값(tools/ci/switch.ts의 기본·켬·끔).
export type PatchRender = { label: string; docs: Doc[]; rootOverlay?: RootOverlay; chartOverlay?: Record<string, unknown> };
type Context = { kind: Kind; where: string; patch: string; restore: Restore; prefix: unknown; bucket: unknown };

function canon(v: unknown): string {
  const walk = (x: unknown): unknown => {
    if (Array.isArray(x)) return x.map(walk);
    if (x && typeof x === "object") return Object.fromEntries(Object.keys(x as object).sort().map((k) => [k, walk((x as any)[k])]));
    return x;
  };
  return JSON.stringify(walk(v));
}

// Helm -f 병합처럼 맵은 키마다 합치고 나머지는 덮는다.
function merge(a: any, b: any): any {
  if (!a || typeof a !== "object" || Array.isArray(a) || !b || typeof b !== "object" || Array.isArray(b)) return b === undefined ? a : b;
  const out = { ...a };
  for (const [k, v] of Object.entries(b)) out[k] = merge(a[k], v);
  return out;
}

// Go 템플릿 동작 안의 함수 이름 중 HELM_ONLY. 주석과 문자열은 빼고, .필드·$변수는 함수가 아니라 뺀다.
function helmOnly(patch: string): string[] {
  const found = new Set<string>();
  const body = patch.replace(/\{\{-?\s*\/\*[\s\S]*?\*\/\s*-?\}\}/g, "");
  for (const [, action] of body.matchAll(/\{\{([\s\S]*?)\}\}/g)) {
    const code = action.replace(/"(?:\\.|[^"\\])*"|`[^`]*`/g, "");
    for (const m of code.matchAll(/(^|[^.$\w])([A-Za-z_]\w*)/g)) if (HELM_ONLY.has(m[2])) found.add(m[2]);
  }
  return [...found];
}

function contexts(r: PatchRender, out: Violation[]): Context[] {
  const ctx: Context[] = [];
  for (const d of r.docs) {
    const kind = d.obj?.metadata?.name;
    if (d.obj?.kind !== "ApplicationSet" || (kind !== "apps" && kind !== "data")) continue;
    const where = `${r.label}:${d.origin}`;
    const patch = String(d.obj.spec?.templatePatch ?? "");
    // root 아래 렌더: 클러스터 값 파일(+ 이 렌더의 덧씌우기)이 기대값이다. root가 ApplicationSet 차트에 넘기는 단계까지 함께 본다.
    const root = /^[^:[]+\[([a-z0-9-]+)\]:/.exec(d.origin);
    if (root) {
      const vf = `platform/root/values-${root[1]}.yaml`;
      const c = (Bun.YAML.parse(readText(vf)) as any)?.cluster ?? {};
      ctx.push({ kind, where, patch, restore: clusterRestore(vf, r.rootOverlay), prefix: c.tailscale?.prefix, bucket: c.backup?.bucket });
      continue;
    }
    // ApplicationSet 차트 시험 values: 그 파일(+ 이 렌더의 차트 덧씌우기)이 기대값이다.
    const ci = /^chart:(appsets\/(apps|data)\/ci\/[^/]+\.yaml)$/.exec(d.origin);
    if (!ci || ci[2] !== kind) {
      out.push({ rule: "appset-patch", where, message: "templatePatch를 실행할 기대값을 모르는 출처다(root 아래 렌더 또는 platform/appsets/<apps|data>/ci만)" });
      continue;
    }
    const v = merge(Bun.YAML.parse(readText(`platform/${ci[1]}`)) ?? {}, r.chartOverlay ?? {});
    const restore: Restore = {
      suspendedApps: Array.isArray(v.suspendedApps) ? v.suspendedApps.map(String) : [],
      valkey: v.valkeyRestore && typeof v.valkeyRestore === "object" ? v.valkeyRestore : {},
      externalSecretsOff: v.externalSecrets?.enabled === false,
    };
    ctx.push({ kind, where, patch, restore, prefix: v.tailscale?.prefix, bucket: v.backup?.bucket });
  }
  return ctx;
}

// templatePatch 여러 개를 Helm 한 번으로 실행한다. 결과는 case 번호 순서의 patch 객체다.
function execute(cases: { patch: string; params: unknown }[], tmp: string): { ok: true; patches: any[] } | { ok: false; error: string } {
  const chart = join(tmp, "patch-runner");
  mkdirSync(join(chart, "templates"), { recursive: true });
  writeFileSync(join(chart, "Chart.yaml"), "apiVersion: v2\nname: patch-runner\nversion: 0.1.0\n");
  writeFileSync(
    join(chart, "templates", "run.yaml"),
    '{{- range $i, $c := .Values.cases }}\n---\ncase: {{ $i }}\npatch:\n{{ tpl $c.patch ($c.params | fromJson) | indent 2 }}\n{{- end }}\n',
  );
  const vfile = join(tmp, "patch-cases.json");
  writeFileSync(vfile, JSON.stringify({ cases: cases.map((c) => ({ patch: c.patch, params: JSON.stringify(c.params) })) }));
  const r = helmTemplate("patch-runner", chart, undefined, [vfile]);
  if (!r.ok) return { ok: false, error: r.out.trim() };
  const patches: any[] = [];
  for (const d of parseAll(r.out)) if (d && typeof d.case === "number") patches[d.case] = d.patch;
  return { ok: true, patches };
}

export function checkAppsetPatches(renders: PatchRender[]): Violation[] {
  const out: Violation[] = [];
  const v = (where: string, message: string) => out.push({ rule: "appset-patch", where, message });
  const tmp = tempDir("appset-patch");

  // 같은 patch·기대값은 한 번만 실행한다(기본 렌더와 켠 렌더는 대개 같다).
  const seen = new Set<string>();
  const ctx = renders.flatMap((r) => contexts(r, out)).filter((c) => {
    const k = canon([c.kind, c.patch, c.restore, c.prefix, c.bucket]);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  for (const p of new Set(ctx.map((c) => c.patch))) {
    const bad = helmOnly(p);
    if (bad.length > 0) v(ctx.find((c) => c.patch === p)!.where, `templatePatch에 Argo CD ApplicationSet에 없는 함수(Helm 전용): ${bad.join(", ")}`);
  }

  const sample = Object.fromEntries(
    (Object.keys(SAMPLE) as Kind[]).map((k) => {
      const values = (Bun.YAML.parse(readText(SAMPLE[k].values)) ?? {}) as Record<string, any>;
      // 작업 트리 차트로 렌더하므로 그 버전을 적는다(이 PR이 태그로 낼 차트).
      values.chartVersion = String((Bun.YAML.parse(readText(`${SAMPLE[k].chart}/Chart.yaml`)) as any)?.version);
      return [k, values];
    }),
  ) as Record<Kind, Record<string, any>>;

  type Case = { c: Context; app: string; params: unknown; want: Record<string, any> };
  const cases: Case[] = [];
  for (const c of ctx) {
    if (typeof c.prefix !== "string" && c.kind === "apps") {
      v(c.where, "tailscale 접두(클러스터 값)를 찾지 못했다");
      continue;
    }
    if (typeof c.bucket !== "string" && c.kind === "data") {
      v(c.where, "백업 버킷(클러스터 값)을 찾지 못했다");
      continue;
    }
    const names = [...new Set([...(c.kind === "apps" ? c.restore.suspendedApps : Object.keys(c.restore.valkey)), OTHER])];
    for (const app of names) {
      // image.yaml의 repository는 앱 이름을 따른다(앱 차트가 ghcr.io/ukyi-app/<앱>을 요구한다).
      const human = c.kind === "apps" ? { ...sample.apps, repository: `ghcr.io/ukyi-app/${app}` } : sample.data;
      const dir = SAMPLE[c.kind].dir;
      // git 생성기가 넘기는 변수 모양(goTemplate: path는 객체, values는 생성기 values). merge 생성기가 두 파일 키를 합친다.
      const params = {
        ...human,
        values: { app },
        path: { path: `${dir}/${app}`, basename: app, filename: "values.yaml", basenameNormalized: app, filenameNormalized: "values.yaml", segments: [dir, app] },
      };
      const want = c.kind === "apps" ? appValues(app, human, c.prefix as string, c.restore) : dataValues(app, human, c.bucket as string, c.restore);
      cases.push({ c, app, params, want });
    }
  }
  const r = execute(cases.map((x) => ({ patch: x.c.patch, params: x.params })), tmp);
  if (!r.ok) {
    v("appset-patch", `templatePatch 실행 실패: ${r.error}`);
    return out;
  }

  const offCount: Record<Kind, number> = { apps: 0, data: 0 };
  const onEs: Record<Kind, number> = { apps: 0, data: 0 };
  let offSuspended = 0;
  const offModes = new Set<string>();
  const renderCache = new Map<string, number | string>();
  cases.forEach(({ c, app, want }, i) => {
    const where = `${c.where} (앱 ${app})`;
    const got = r.patches[i]?.spec?.source?.helm?.valuesObject;
    if (!got || typeof got !== "object") {
      v(where, "templatePatch 결과에 spec.source.helm.valuesObject가 없다");
      return;
    }
    if (c.restore.externalSecretsOff) offCount[c.kind]++;
    // 1. render.ts 재현과 같은가.
    if (canon(got) !== canon(want)) {
      const keys = [...new Set([...Object.keys(got), ...Object.keys(want)])].filter((k) => canon(got[k]) !== canon(want[k]));
      v(where, `templatePatch 실행 결과가 render.ts의 재현(${c.kind === "apps" ? "appValues" : "dataValues"})과 다르다: ${keys.join(", ")}`);
    }
    // 1. 함께 넣는 값과 복구 스위치 값(재현과 따로).
    const es = got.externalSecrets;
    if (c.restore.externalSecretsOff ? es?.enabled !== false : es !== undefined) v(where, `복구 스위치 값이 틀렸다(externalSecrets: ${JSON.stringify(es)}, 기대 ${c.restore.externalSecretsOff ? "{enabled: false}" : "없음"})`);
    if (c.kind === "apps") {
      if (got.tailnetPrefix !== c.prefix) v(where, `tailnetPrefix ${JSON.stringify(got.tailnetPrefix)}가 클러스터 값 ${JSON.stringify(c.prefix)}와 다르다`);
      const s = c.restore.suspendedApps.includes(app);
      if ((got.suspended === true) !== s) v(where, `suspended가 ${s ? "true가 아니다" : "들어갔다"}`);
      if (c.restore.externalSecretsOff && s) offSuspended++;
    } else {
      if (got.backup?.bucket !== c.bucket) v(where, `backup.bucket ${JSON.stringify(got.backup?.bucket)}가 클러스터 값 ${JSON.stringify(c.bucket)}와 다르다`);
      const mode = c.restore.valkey[app];
      if (mode !== undefined) {
        if (got.valkey?.running !== (mode === "restoreMode")) v(where, `valkey.running ${JSON.stringify(got.valkey?.running)}가 ${mode}와 맞지 않는다`);
        if ((got.valkey?.restoreMode === true) !== (mode === "restoreMode")) v(where, `valkey.restoreMode ${JSON.stringify(got.valkey?.restoreMode)}가 ${mode}와 맞지 않는다`);
        if (c.restore.externalSecretsOff) offModes.add(mode);
      }
    }
    // 2. 실행 결과로 작업 트리 공유 차트를 렌더한다. 릴리스 이름 = 앱, ns app-<앱>(ApplicationSet 템플릿과 같다).
    const key = canon([c.kind, app, got]);
    let n = renderCache.get(key);
    if (n === undefined) {
      const vfile = join(tmp, `values-${renderCache.size}.json`);
      writeFileSync(vfile, JSON.stringify(got));
      const rr = helmTemplate(app, SAMPLE[c.kind].chart, `app-${app}`, [vfile]);
      n = rr.ok ? parseAll(rr.out).filter((d) => d?.kind === "ExternalSecret" && String(d?.apiVersion ?? "").startsWith("external-secrets.io/")).length : rr.out.trim();
      renderCache.set(key, n);
    }
    if (typeof n === "string") {
      v(where, `templatePatch 결과로 ${SAMPLE[c.kind].chart}를 렌더하지 못했다: ${n}`);
      return;
    }
    if (!c.restore.externalSecretsOff) onEs[c.kind] += n;
    else if (n > 0) v(where, `복구 스위치를 껐는데 templatePatch 결과로 렌더한 ${SAMPLE[c.kind].chart}에 ExternalSecret이 ${n}개 남았다`);
  });

  // 3. 0건 통과 금지.
  for (const k of ["apps", "data"] as Kind[]) {
    if (offCount[k] === 0) v(`appset-patch:${k}`, "복구 스위치를 끈 templatePatch 실행이 0건이다(끈 렌더에 ApplicationSet이 없다)");
    if (onEs[k] === 0) v(`appset-patch:${k}`, `켠 templatePatch 결과의 ExternalSecret이 0개다. 견본(${SAMPLE[k].values})이 시크릿을 내지 않으면 끈 검사가 아무것도 보지 않는다`);
  }
  if (offSuspended === 0) v("appset-patch:apps", "복구 스위치와 suspendedApps를 함께 쓰는 실행이 0건이다(platform/appsets/apps/ci)");
  for (const m of ["stopped", "restoreMode"]) if (!offModes.has(m)) v("appset-patch:data", `복구 스위치와 valkeyRestore ${m}를 함께 쓰는 실행이 0건이다(platform/appsets/data/ci)`);
  const n = (k: Kind) => cases.filter((x) => x.c.kind === k).length;
  console.log(`templatePatch 실행: apps ${n("apps")}건(끔 ${offCount.apps}), data ${n("data")}건(끔 ${offCount.data})`);
  return out;
}
