// 데이터 서비스(T11) 검사. 렌더 결과의 ExternalSecret 경로와, 공유 차트에 묶은 외부 차트(tgz)의 고정값을 본다.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { type Doc, type Violation, ROOT, gitFiles } from "./lib";

// 앱 store(infisical-apps)는 Free 플랜에 경로 RBAC가 없어 절대 키(/로 시작)로 프로젝트의 어느 경로든 읽는다
// (ESO v2.13.0 getSecretAddress는 /로 시작하는 키에 secretsPath를 붙이지 않는다). 그래서 절대 키는 R2 백업 자격
// 하나만, 그것을 받아야 하는 렌더(데이터 차트의 영속 Valkey, platform/cnpg의 database ns)에서만 허용한다(설계 C.3.8, C.6.3).
const APPS_STORE = "infisical-apps";
const ABSOLUTE_ALLOWED_PREFIX = "/platform/backup/";
// render.ts의 origin: 데이터 등록 렌더(data:<앱>[클러스터]), 데이터 차트 시험 values(chart:charts/app-data/...),
// root가 렌더한 platform/cnpg 아래 source(<Application>[클러스터]:platform/cnpg...), 그 차트의 시험 values(chart:cnpg/...).
const ABSOLUTE_ALLOWED_ORIGINS = [/^data:/, /^chart:charts\/app-data\//, /:platform\/cnpg(\/|$)/, /^chart:cnpg(\/|$)/];

export function checkSecretPaths(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  for (const d of docs) {
    if (d.obj?.kind !== "ExternalSecret") continue;
    const ref = d.obj.spec?.secretStoreRef ?? {};
    if (ref.name !== APPS_STORE) continue;
    const where = `${d.origin} ExternalSecret/${d.obj.metadata?.namespace ? `${d.obj.metadata.namespace}/` : ""}${d.obj.metadata?.name}`;
    const keys: unknown[] = [
      ...(d.obj.spec?.data ?? []).map((x: any) => x?.remoteRef?.key),
      ...(d.obj.spec?.dataFrom ?? []).flatMap((x: any) => [x?.extract?.key, x?.find?.path]),
    ];
    for (const k of keys) {
      if (typeof k !== "string" || !k.startsWith("/")) continue;
      if (!k.startsWith(ABSOLUTE_ALLOWED_PREFIX)) {
        out.push({ rule: "secret-path", where, message: `${APPS_STORE}의 절대 키 ${k}는 ${ABSOLUTE_ALLOWED_PREFIX} 아래만 된다` });
      } else if (!ABSOLUTE_ALLOWED_ORIGINS.some((re) => re.test(d.origin))) {
        out.push({ rule: "secret-path", where, message: `${APPS_STORE}의 절대 키 ${k}는 데이터 차트와 platform/cnpg 렌더에서만 쓴다` });
      }
    }
  }
  return out;
}

// 공유 차트에 커밋한 외부 차트 묶음(platform/charts/<차트>/charts/<이름>-<버전>.tgz). Chart.yaml의 dependencies와
// 버전이 맞고, 주석 "<버전> tgz sha256: <hex>"(공식 index.yaml의 digest를 옮긴 값)와 파일 해시가 같아야 한다.
// 버전을 올리며 tgz만 바꾸거나 주석만 고치면 여기서 걸린다.
export function checkVendoredCharts(): Violation[] {
  const out: Violation[] = [];
  let seen = 0;
  for (const chartFile of gitFiles(":(glob)platform/charts/*/Chart.yaml")) {
    const dir = dirname(chartFile);
    const text = readFileSync(join(ROOT, chartFile), "utf8");
    const deps: any[] = (Bun.YAML.parse(text) as any)?.dependencies ?? [];
    const tgzs = gitFiles(`${dir}/charts/*.tgz`);
    for (const dep of deps) {
      const want = `${dir}/charts/${dep.name}-${dep.version}.tgz`;
      if (!tgzs.includes(want)) {
        out.push({ rule: "vendored-chart", where: chartFile, message: `의존 차트 ${dep.name} ${dep.version}의 묶음 ${want}가 없다(CI·Argo CD 렌더는 외부 저장소를 받지 않는다)` });
        continue;
      }
      seen++;
      const pinned = text.match(new RegExp(`^# ${dep.version.replaceAll(".", "\\.")} tgz sha256: ([0-9a-f]{64})$`, "m"))?.[1];
      const got = createHash("sha256").update(readFileSync(join(ROOT, want))).digest("hex");
      if (!pinned) out.push({ rule: "vendored-chart", where: chartFile, message: `주석 "# ${dep.version} tgz sha256: <공식 index.yaml digest>"가 없다` });
      else if (pinned !== got) out.push({ rule: "vendored-chart", where: want, message: `sha256 ${got}가 Chart.yaml에 적은 ${pinned}와 다르다` });
    }
    for (const t of tgzs) {
      if (!deps.some((dep) => basename(t) === `${dep.name}-${dep.version}.tgz`)) {
        out.push({ rule: "vendored-chart", where: t, message: "Chart.yaml dependencies에 없는 묶음이다(옛 버전을 남겼다)" });
      }
    }
  }
  if (seen === 0) out.push({ rule: "vendored-chart", where: "platform/charts", message: "검사한 묶음이 0개다(L40)" });
  return out;
}

// 앱의 Valkey 배선(설계 C.5.6). 캐시(apps/<앱>의 cache.enabled)와 영속(data/<앱>의 valkey.persistent)은 둘 다
// 같은 ns에 Service <앱>-valkey와 ExternalSecret <앱>-valkey-auth를 만든다. 둘을 함께 켜면 두 Application이 같은
// 리소스를 서로 고친다. uses.valkey만 켜면 VALKEY_URL이 없는 Service를 가리킨다.
export function checkValkeyWiring(): Violation[] {
  const out: Violation[] = [];
  const read = (f: string) => (Bun.YAML.parse(readFileSync(join(ROOT, f), "utf8")) ?? {}) as any;
  const persistent = new Set(gitFiles("data/*/values.yaml").filter((f) => read(f)?.valkey?.persistent === true).map((f) => basename(dirname(f))));
  for (const f of gitFiles("apps/*/values.yaml")) {
    const app = basename(dirname(f));
    const v = read(f);
    const cache = v?.cache?.enabled === true;
    if (cache && persistent.has(app)) {
      out.push({ rule: "valkey-wiring", where: f, message: `캐시(cache.enabled)와 영속(data/${app}의 valkey.persistent)을 함께 켰다. 둘 다 Service ${app}-valkey를 만든다` });
    }
    if (v?.uses?.valkey === true && !cache && !persistent.has(app)) {
      out.push({ rule: "valkey-wiring", where: f, message: `uses.valkey인데 Valkey가 없다(cache.enabled나 data/${app}의 valkey.persistent)` });
    }
  }
  return out;
}

// PUBLIC CONNECT hook(pg-acl, 데이터 차트 templates/postgres.yaml)의 순서(설계 C.5.3). Database가 적용된 뒤 이 hook보다 먼저
// Healthy를 기다리는 리소스가 있으면, 그것이 늦는 동안(Pending PVC 등) 새 DB가 PUBLIC CONNECT를 가진 채 남는다(PR #968 리뷰).
// 그래서 hook은 Sync 단계이고(PostSync는 모든 Sync 리소스가 Healthy여야 돈다) Database 뒤 wave이며, Database wave 이상
// hook wave 미만에는 Database 말고 Sync 단계 리소스가 없어야 한다. wave 해석은 Argo CD와 같다(정수가 아니면 0).
// data:<앱> 렌더는 chartVersion 태그(바꿀 수 없다, 1.0.3 이하는 PostSync)라 보지 않는다. 차트는 시험 values 렌더로 본다.
const HOOK = "argocd.argoproj.io/hook";
export function checkPgAclOrder(docs: Doc[]): Violation[] {
  const out: Violation[] = [];
  const byOrigin = new Map<string, Doc[]>();
  for (const d of docs) {
    if (d.origin.startsWith("data:")) continue;
    byOrigin.set(d.origin, [...(byOrigin.get(d.origin) ?? []), d]);
  }
  const ann = (d: Doc, k: string): string | undefined => d.obj.metadata?.annotations?.[k];
  const wave = (d: Doc) => {
    const w = ann(d, "argocd.argoproj.io/sync-wave") ?? "";
    return /^[+-]?\d+$/.test(w) ? Number(w) : 0;
  };
  // Sync 단계에서 도는 것: hook이 아닌 리소스와 Sync hook. Skip은 적용하지 않고, Helm hook은 다른 단계로 옮겨진다.
  const syncPhase = (d: Doc) => {
    const h = ann(d, HOOK);
    if (h !== undefined) return h.split(",").map((t) => t.trim()).includes("Sync");
    return ann(d, "helm.sh/hook") === undefined;
  };
  const name = (d: Doc) => `${d.obj.kind}/${d.obj.metadata?.namespace ? `${d.obj.metadata.namespace}/` : ""}${d.obj.metadata?.name}`;
  for (const [origin, ds] of byOrigin) {
    const acl = ds.find((d) => d.obj.kind === "Job" && d.obj.spec?.template?.metadata?.labels?.["homelab.ukyi.app/role"] === "pg-acl");
    if (!acl) continue;
    const where = `${origin} ${name(acl)}`;
    if (ann(acl, HOOK) !== "Sync") {
      out.push({ rule: "pg-acl-order", where, message: `hook이 Sync가 아니다(${ann(acl, HOOK) ?? "hook 주석 없음"}). PostSync는 Pending PVC 같은 Sync 리소스를 기다려 새 DB의 PUBLIC CONNECT가 남는다` });
    }
    const db = ds.filter((d) => d.obj.kind === "Database" && String(d.obj.apiVersion ?? "").startsWith("postgresql.cnpg.io/"));
    if (db.length !== 1) {
      out.push({ rule: "pg-acl-order", where, message: `같은 렌더의 CNPG Database가 ${db.length}개다(1개여야 순서를 본다)` });
      continue;
    }
    const d = wave(db[0]);
    const a = wave(acl);
    if (a <= d) {
      out.push({ rule: "pg-acl-order", where, message: `Database보다 뒤 wave가 아니다(pg-acl ${a}, Database ${d}). DB가 생기기 전에 hook이 끝날 수 있다` });
      continue;
    }
    for (const x of ds) {
      if (x === acl || x === db[0] || !syncPhase(x)) continue;
      const w = wave(x);
      if (w >= d && w < a) {
        out.push({ rule: "pg-acl-order", where, message: `${name(x)}(wave ${w})가 Database(wave ${d})와 pg-acl(wave ${a}) 사이에 있다. Healthy가 늦으면 새 DB의 PUBLIC CONNECT가 남는다` });
      }
    }
  }
  return out;
}
