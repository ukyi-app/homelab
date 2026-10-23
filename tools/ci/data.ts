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
