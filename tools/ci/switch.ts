// 복구 스위치 cluster.restore.externalSecrets 검사(T23, 설계 C.6.4 "클러스터 유실 + Infisical 장애").
// 같은 저장소를 스위치를 켠 값과 끈 값으로 한 번씩 더 렌더해(render.ts RenderOptions) 다음을 본다.
// 1. 끄면 ExternalSecret·ClusterSecretStore가 0개(root 아래 전부, 등록 앱·데이터, 로컬 차트 시험 values).
// 2. 켬과 끔의 차이는 그 둘과 허용한 Application 하나(Store), 스위치 값 자리뿐이다. Deployment 같은 것이 함께
//    빠지면 복구 때 그 구성 요소가 뜨지 않는다.
// 3. 값 파일에 스위치가 없는 클러스터는 기본 렌더가 켠 렌더와 같고, 어느 Application에도 스위치 값이 들어가지 않는다.
//    운영 Application spec이 스위치 전과 같다는 장치를 지킨다.
// 4. 끈 렌더도 정책을 통과한다(복구 PR이 가장 급할 때 막히지 않게). kubeconform은 리소스를 빼기만 하므로 생략한다.
// 5. ApplicationSet apps·data의 templatePatch를 실제로 실행해 위 렌더의 재현과 같은지, 끄면 공유 차트 ES가 0인지 본다
//    (tools/ci/appset-patch.ts). 위 1.~3.의 등록 앱·데이터 렌더는 render.ts의 재현이라 그 단계를 대신 보지 못한다.
// 등록 앱·데이터가 스위치를 모르는 옛 차트(render.ts ES_SWITCH_SINCE)면 가상 끔 렌더에서는 정보 줄만 낸다. 기존 앱은 옛 태그에
// 머물 수 있다(설계 C.4.5). 값 파일에서 스위치를 실제로 끈 클러스터는 기본 렌더(render 단계)와 여기서 함께 실패한다.
// 끌 때 빠지는 것(Store와 ExternalSecret 대상 Secret)을 출력한다. 손으로 만들 Secret은 이 중 Store를 뺀 것이다
// (앱 0개일 때 13개 중 10개, restore.md 3.1).
import { checkAppsetPatches } from "./appset-patch";
import { checkSecretPaths } from "./data";
import { type Doc, type Violation, gitFiles, readText } from "./lib";
import { checkAll } from "./policy";
import { ES_CHART_RULE, EXTERNAL_SECRETS_OFF, renderAll } from "./render";

const SECRET_KINDS = new Set(["ExternalSecret", "ClusterSecretStore"]);
// 끌 때 Application째 빠지는 것(platform/root/templates/external-secrets.yaml).
const REMOVED_APPS = new Set(["external-secrets-stores"]);
const ES_PATCH = "externalSecrets";

const isSecret = (d: Doc) => SECRET_KINDS.has(d.obj?.kind) && String(d.obj?.apiVersion ?? "").startsWith("external-secrets.io/");

// root 아래 렌더의 출처는 "<Application>[<클러스터>]:<path>"다. source가 바뀌어도(관측 ES를 Helm source로 옮김) 같은
// Application이면 같은 묶음으로 본다. 그 밖(root 파일, chart:, app:, data:)은 출처 그대로다.
function group(origin: string): { key: string; app?: string; cluster?: string } {
  const m = /^([^:[]+)\[([a-z0-9-]+)\]:/.exec(origin);
  if (m) return { key: `${m[1]}[${m[2]}]`, app: m[1], cluster: m[2] };
  const c = /^(?:app|data):[^[]+\[([a-z0-9-]+)\]$/.exec(origin);
  return { key: origin, cluster: c?.[1] };
}

function docKey(d: Doc): string {
  return `${d.obj?.kind}/${d.obj?.metadata?.namespace ?? d.ns ?? ""}/${d.obj?.metadata?.name}`;
}

function sources(spec: any): any[] {
  return [spec?.source, ...(Array.isArray(spec?.sources) ? spec.sources : [])].filter((s) => s && typeof s === "object");
}

// 스위치 값 자리만 지운 사본. Application은 source의 valuesObject.externalSecrets(그것만 담은 helm 블록 포함),
// ApplicationSet은 templatePatch(주입 모양은 render.ts APPSET_RENDERERS가 따로 본다)를 뺀다.
function normalize(obj: any): any {
  const o = structuredClone(obj);
  if (o?.kind === "Application") {
    for (const s of sources(o.spec)) {
      const vo = s.helm?.valuesObject;
      if (vo && typeof vo === "object" && ES_PATCH in vo) {
        delete vo[ES_PATCH];
        if (Object.keys(vo).length === 0) delete s.helm.valuesObject;
        if (Object.keys(s.helm).length === 0) delete s.helm;
      }
    }
  }
  if (o?.kind === "ApplicationSet") delete o.spec?.templatePatch;
  return o;
}

function canon(v: unknown): string {
  const walk = (x: unknown): unknown => {
    if (Array.isArray(x)) return x.map(walk);
    if (x && typeof x === "object") return Object.fromEntries(Object.keys(x as object).sort().map((k) => [k, walk((x as any)[k])]));
    return x;
  };
  return JSON.stringify(walk(v));
}

function byGroup(docs: Doc[]): Map<string, Map<string, Doc>> {
  const out = new Map<string, Map<string, Doc>>();
  for (const d of docs) {
    const g = group(d.origin).key;
    if (!out.has(g)) out.set(g, new Map());
    out.get(g)!.set(docKey(d), d);
  }
  return out;
}

// 스위치 값이 Application·ApplicationSet에 들어갔는지(켠 렌더에는 없어야 한다).
function carriesSwitch(d: Doc): boolean {
  if (d.obj?.kind === "Application") return sources(d.obj.spec).some((s) => s.helm?.valuesObject && ES_PATCH in s.helm.valuesObject);
  if (d.obj?.kind === "ApplicationSet") return String(d.obj.spec?.templatePatch ?? "").includes(`"${ES_PATCH}"`);
  return false;
}

export function checkExternalSecretsSwitch(): Violation[] {
  const out: Violation[] = [];
  const v = (where: string, message: string) => out.push({ rule: "external-secrets-switch", where, message });
  const onOverlay = { cluster: { restore: { externalSecrets: true } } };
  const offOverlay = { cluster: { restore: { externalSecrets: false } } };
  const base = renderAll();
  const on = renderAll({ rootOverlay: onOverlay });
  const off = renderAll({ rootOverlay: offOverlay, chartOverlay: EXTERNAL_SECRETS_OFF });
  // 값 파일에서 스위치를 이미 끈 클러스터(복구 PR). 렌더가 아니라 값 파일로 판정한다(아래 3. 주석).
  const switchedOff = new Set(
    gitFiles("platform/root/values-*.yaml")
      .filter((f) => (Bun.YAML.parse(readText(f)) as any)?.cluster?.restore?.externalSecrets === false)
      .map((f) => f.replace(/^platform\/root\/values-/, "").replace(/\.yaml$/, "")),
  );
  for (const c of switchedOff) console.log(`참고: ${c}는 값 파일에서 복구 스위치가 꺼져 있다. 복구 PR이면 정상이다`);
  for (const x of on.violations) v(`켬:${x.where}`, x.message);
  // 스위치를 모르는 옛 차트 앱·데이터: 스위치를 끈 클러스터만 실패, 나머지는 앱마다 정보 줄 한 번.
  const unsupported = new Map<string, { message: string; clusters: string[] }>();
  for (const x of off.violations) {
    const cluster = /\[([a-z0-9-]+)\]$/.exec(x.where)?.[1];
    if (x.rule !== ES_CHART_RULE || !cluster || switchedOff.has(cluster)) {
      v(`끔:${x.where}`, x.message);
      continue;
    }
    const app = x.where.replace(/\[[a-z0-9-]+\]$/, "");
    const u = unsupported.get(app) ?? { message: x.message, clusters: [] };
    u.clusters.push(cluster);
    unsupported.set(app, u);
  }
  for (const [app, u] of unsupported) console.log(`참고: ${app}: ${u.message}. 스위치를 끄지 않은 클러스터(${u.clusters.join(", ")})라 실패로 두지 않는다`);
  const offFailed = new Set(off.violations.map((x) => x.where));

  // 1. 끄면 0개, 켜면 0이 아님(0건 통과 금지, 설계 B.8 E7).
  for (const d of off.docs.filter(isSecret)) v(`끔:${d.origin}`, `${docKey(d)}가 남았다. 이 ExternalSecret·Store도 복구 스위치로 꺼지게 한다(platform/root/templates/_helpers.tpl)`);
  const clusters = [...new Set(on.docs.map((d) => group(d.origin).cluster).filter(Boolean))] as string[];
  if (clusters.length === 0) v("켬", "root 아래 렌더가 0개다");
  for (const c of clusters) {
    const n = on.docs.filter((d) => isSecret(d) && group(d.origin).cluster === c && group(d.origin).app).length;
    if (n === 0) v(`켬[${c}]`, "켠 렌더에 ExternalSecret·Store가 0개다(검사가 아무것도 보지 않는다)");
  }
  if (!on.docs.some((d) => isSecret(d) && d.origin.startsWith("chart:charts/"))) v("켬:chart", "공유 차트 시험 렌더에 ExternalSecret이 0개다");

  // 2. 켬과 끔의 차이는 시크릿 문서, 허용한 Application, 스위치 값 자리뿐.
  const onG = byGroup(on.docs);
  const offG = byGroup(off.docs);
  for (const [g, onDocs] of onG) {
    const info = group([...onDocs.values()][0].origin);
    const offDocs = offG.get(g);
    if (!offDocs) {
      if (!(info.app && REMOVED_APPS.has(info.app)) && !offFailed.has(g)) v(g, "끄면 이 렌더가 통째로 사라진다(허용: external-secrets-stores)");
      continue;
    }
    for (const [k, d] of onDocs) {
      if (isSecret(d)) continue;
      const o = offDocs.get(k);
      if (!o) {
        if (!(d.obj?.kind === "Application" && REMOVED_APPS.has(d.obj?.metadata?.name))) v(g, `끄면 ${k}가 빠진다(시크릿만 빠져야 한다)`);
        continue;
      }
      if (canon(normalize(d.obj)) !== canon(normalize(o.obj))) v(g, `끄면 ${k}가 바뀐다(스위치 값 자리 말고는 같아야 한다)`);
    }
    for (const k of offDocs.keys()) if (!onDocs.has(k)) v(g, `끄면 ${k}가 새로 생긴다`);
  }
  for (const g of offG.keys()) if (!onG.has(g)) v(g, "끈 렌더에만 있다");

  // 3. 값 파일에 스위치가 없는 클러스터는 기본 렌더 = 켠 렌더, 스위치 값 없음.
  // 값 파일이 이미 끈 클러스터(복구 PR)는 기본 렌더가 끈 렌더라 비교하지 않는다. 판정은 렌더가 아니라 값 파일로 한다.
  // 렌더로 판정하면 스위치 값이 새는 실수(늘 넘기는 템플릿)가 "복구 PR"로 보여 이 검사를 건너뛴다.
  const baseG = byGroup(base.docs.filter((d) => !d.origin.startsWith("kustomize:")));
  for (const [g, baseDocs] of baseG) {
    const info = group([...baseDocs.values()][0].origin);
    if (info.cluster && switchedOff.has(info.cluster)) continue;
    // 시험 values(chart:)는 스위치를 일부러 끈 것이 있어 보지 않는다. root 아래 렌더에 들어가면 운영 spec이 바뀐 것이다.
    const switched = info.cluster ? [...baseDocs.values()].filter(carriesSwitch) : [];
    if (switched.length > 0) v(g, `스위치가 없는데 ${switched.map(docKey).join(", ")}에 복구 스위치 값이 들어갔다`);
    const onDocs = onG.get(g);
    if (!onDocs) {
      v(g, "기본 렌더에 있는데 켠 렌더에 없다");
      continue;
    }
    for (const [k, d] of baseDocs) {
      const o = onDocs.get(k);
      if (!o || canon(d.obj) !== canon(o.obj)) v(g, `${k}: 스위치가 없는 기본 렌더와 cluster.restore.externalSecrets: true 렌더가 다르다`);
    }
  }

  // 4. 끈 렌더의 정책.
  for (const x of [...checkAll(off.docs), ...checkSecretPaths(off.docs)]) v(`끔:${x.where}`, `${x.rule}: ${x.message}`);

  // 5. templatePatch 실행. 기본·켬 렌더는 복구 멈춤만 쓰는 경우와 주입 없는 경우, 끔 렌더는 스위치 단독·동시 사용을 낸다.
  for (const x of checkAppsetPatches([
    { label: "기본", docs: base.docs },
    { label: "켬", docs: on.docs, rootOverlay: onOverlay },
    { label: "끔", docs: off.docs, rootOverlay: offOverlay, chartOverlay: EXTERNAL_SECRETS_OFF },
  ]))
    v(x.where, x.message);

  // 끌 때 빠지는 것(클러스터별, root 아래와 등록 앱·데이터). 손 Secret과 같지 않다(파일 머리 주석). 옛 차트 앱은 끄기 전에
  // 올려야 해 빼고 위 정보 줄로 낸다.
  for (const c of clusters) {
    const targets = on.docs
      .filter((d) => isSecret(d) && group(d.origin).cluster === c && !unsupported.has(d.origin.replace(/\[[a-z0-9-]+\]$/, "")))
      .map((d) => (d.obj.kind === "ClusterSecretStore" ? `Store ${d.obj.metadata?.name}` : `${d.obj.metadata?.namespace ?? d.ns}/${d.obj.spec?.target?.name ?? d.obj.metadata?.name}`))
      .sort();
    console.log(`끌 때 빠지는 것[${c}] ${targets.length}개: ${targets.join(", ")}`);
  }
  return out;
}
