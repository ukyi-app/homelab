// app add의 파일 계산(순수 함수). prStep의 edit가 읽을 때와 apply 때 같은 결과를 내야 해서 바깥을 읽지 않는다.
import { fullMatch, GIT_SHA, IMAGE_DIGEST } from "../core/names";
import { parseYaml, setTopLevel } from "../core/values";

export type CacheMode = "none" | "cache" | "persistent";
export type AddFlags = { public?: string; internal?: string; postgres: boolean; cache: CacheMode };
export type Image = { repository: string; digest: string; revision: string; hold: boolean };
export type Obj = Record<string, any>;

// 템플릿 homelab-app-template의 Dockerfile이 PORT=8080·EXPOSE 8080이다. 메모리는 사람이 앱에 맞춰 고친다.
export const DEFAULTS = { kind: "web", port: 8080, resources: { cpu: "50m", memory: "128Mi" } };
// 캐시 Valkey(cache.enabled)는 앱 차트 1.1.0부터다(설계 C.5.6).
export const CACHE_MIN_CHART = "1.1.0";
const HEADER = "# homelab app add가 만들었다(설계 C.7). 이 파일은 사람이 고쳐도 된다. CLI는 다루는 키만 바꾼다.\n";
const DATA_HEADER = "# homelab CLI가 만들었다(설계 C.5). 이 앱 데이터는 앱을 지워도 남는다(data purge로만 지운다).\n";

export function cmpVersion(a: string, b: string): number {
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

// matching-refs 응답에서 가장 높은 <prefix>X.Y.Z.
export function latestVersion(refs: unknown, prefix: string): string | null {
  if (!Array.isArray(refs)) return null;
  const re = new RegExp(`^refs/tags/${prefix.replaceAll(".", "\\.")}([0-9]+\\.[0-9]+\\.[0-9]+)$`);
  const found = refs.map((r) => (typeof r?.ref === "string" ? re.exec(r.ref)?.[1] : undefined)).filter((v): v is string => !!v);
  return found.sort(cmpVersion).at(-1) ?? null;
}

// 키 순서와 무관한 비교. 같은 값이면 키를 다시 쓰지 않아야 사람이 쓴 꼴(블록·주석)이 남고 재실행이 same이 된다.
function canon(v: unknown): string {
  const sort = (x: unknown): unknown => {
    if (Array.isArray(x)) return x.map(sort);
    if (x && typeof x === "object") return Object.fromEntries(Object.keys(x).sort().map((k) => [k, sort((x as Obj)[k])]));
    return x;
  };
  return JSON.stringify(sort(v)) ?? "undefined";
}

export const sameValue = (a: unknown, b: unknown) => canon(a) === canon(b);

export function parseObj(text: string, path: string): Obj {
  const v = parseYaml(text);
  if (v === null || v === undefined) return {};
  if (typeof v !== "object" || Array.isArray(v)) throw new Error(`${path}: 최상위가 매핑이 아니다`);
  return v as Obj;
}

// 바뀌는 키만 setTopLevel에 넘긴다. 없던 파일이면 머리 주석 아래에 순서대로 쓴다.
export function applyEdits(current: string | null, header: string, edits: Obj): string | null {
  const before = current === null ? {} : parseObj(current, "values");
  const changed = Object.fromEntries(Object.entries(edits).filter(([k, v]) => !sameValue(before[k], v)));
  if (current !== null && Object.keys(changed).length === 0) return current;
  return setTopLevel(current ?? header, changed);
}

// 앱 차트 app.env와 같은 규칙(platform/charts/app/templates/_helpers.tpl): PORT(web)·DATABASE_URL(uses.postgres)·
// VALKEY_URL(uses.valkey)은 차트가 넣고, env 키와 secrets는 그것들과도 서로도 겹치면 렌더가 막힌다(#884 2라운드 P2-4).
// 병합할 수 없는 PR을 만들지 않게 쓰기 전에 멈춘다. 덮거나 조용히 빼지 않는다.
export function envProblem(v: Record<string, any>): string | null {
  const names = [...(v.kind === "web" ? ["PORT"] : []), ...(v.uses?.postgres ? ["DATABASE_URL"] : []), ...(v.uses?.valkey ? ["VALKEY_URL"] : []), ...Object.keys(v.env ?? {}), ...(Array.isArray(v.secrets) ? v.secrets : [])];
  const dup = names.filter((n, i) => names.indexOf(n) !== i);
  return dup.length ? `env 이름 ${[...new Set(dup)].join(", ")}가 두 번 나온다(차트가 넣는 PORT·DATABASE_URL·VALKEY_URL, values env, secrets가 겹친다). 겹치는 쪽을 정리한 뒤 다시 실행한다` : null;
}

export function appValues(current: string | null, flags: AddFlags, ctx: { secrets: string[]; latestChart: string }): string | null {
  const now = current === null ? {} : parseObj(current, "apps values");
  // worker는 schema가 port·public·internal을 막는다(values.schema.json allOf). 노출 플래그 하나로 web으로 바꾸지도 않는다
  // (포트·probe를 정해야 한다, #884 2라운드 P2-5). PR 계산 때의 main에서도 본다.
  if (now.kind === "worker" && (flags.public || flags.internal)) throw new Error("worker 앱에는 --public·--internal을 붙이지 않는다(web으로 바꾸려면 values의 kind·port·probes를 사람이 고친다)");
  // 캐시와 영속 Valkey는 이름이 같아 함께 둘 수 없다. 시작 뒤 그사이 병합된 캐시를 이 PR이 보게 한다(#884 2라운드 P2-2).
  if (flags.cache === "persistent" && now.cache?.enabled === true) throw new Error("그사이 main에 캐시 Valkey가 켜졌다(같은 이름이라 영속과 함께 둘 수 없다). homelab cache add <app> --persistent로 전환한다");
  const edits: Obj = {};
  if (current === null) Object.assign(edits, { chartVersion: ctx.latestChart, ...DEFAULTS });
  else if (flags.cache === "cache" && typeof now.chartVersion === "string" && cmpVersion(now.chartVersion, CACHE_MIN_CHART) < 0) edits.chartVersion = ctx.latestChart;
  if (flags.public) edits.public = { ...(now.public ?? {}), host: flags.public };
  if (flags.internal) edits.internal = { ...(now.internal ?? {}), name: flags.internal };
  const secrets = [...new Set([...(Array.isArray(now.secrets) ? now.secrets : []), ...ctx.secrets])].sort();
  if (secrets.length > 0) edits.secrets = secrets;
  const uses = { ...(now.uses ?? {}) };
  if (flags.postgres) uses.postgres = true;
  if (flags.cache !== "none") uses.valkey = true;
  if (Object.keys(uses).length > 0) edits.uses = uses;
  if (flags.cache === "cache") edits.cache = { ...(now.cache ?? {}), enabled: true };
  const out = applyEdits(current, HEADER, edits);
  const problem = out === null ? null : envProblem(parseObj(out, "apps values"));
  if (problem) throw new Error(problem);
  return out;
}

// 데이터가 필요 없으면(postgres도 영속 Valkey도 아님) 지금 내용 그대로(없으면 null).
export function dataValues(current: string | null, flags: AddFlags, latestChart: string): string | null {
  const now = current === null ? {} : parseObj(current, "data values");
  if (flags.cache === "cache" && now.valkey?.persistent === true) throw new Error("그사이 main에 영속 Valkey가 켜졌다(캐시와 함께 둘 수 없다). --cache 없이 다시 실행한다");
  if (!flags.postgres && flags.cache !== "persistent") return current;
  const edits: Obj = {};
  if (current === null) edits.chartVersion = latestChart;
  if (flags.postgres) edits.postgres = { ...(now.postgres ?? {}), enabled: true };
  if (flags.cache === "persistent") edits.valkey = { ...(now.valkey ?? {}), persistent: true };
  return applyEdits(current, DATA_HEADER, edits);
}

// image.yaml은 4줄 고정이다(app-build의 read_image와 ci가 같은 형식을 강제한다).
export function imageText(i: Image): string {
  return `repository: ${i.repository}\ndigest: ${i.digest}\nrevision: ${i.revision}\nhold: ${i.hold}\n`;
}

export function parseImage(text: string, app: string): Image {
  const lines = text.split("\n").filter((l) => !/^\s*(#.*)?$/.test(l));
  const field = (k: string) => {
    const hits = lines.filter((l) => l.startsWith(`${k}: `));
    return hits.length === 1 ? hits[0].slice(k.length + 2) : undefined;
  };
  const repository = field("repository");
  const digest = field("digest");
  const revision = field("revision");
  const hold = field("hold");
  if (lines.length !== 4 || repository !== `ghcr.io/ukyi-app/${app}` || !digest || !fullMatch(IMAGE_DIGEST, digest) || !revision || !fullMatch(GIT_SHA, revision) || (hold !== "true" && hold !== "false")) {
    throw new Error(`apps/${app}/image.yaml 형식이 아니다(4줄: repository·digest·revision·hold)`);
  }
  return { repository, digest, revision, hold: hold === "true" };
}

// 사람용 요약. 값(digest 전체 등)은 앞부분만.
export function describeFile(path: string, before: string | null, after: string | null): string {
  if (after === null) return "삭제";
  if (path.endsWith("image.yaml")) {
    const m = /digest: sha256:([0-9a-f]{12})[\s\S]*revision: ([0-9a-f]{7})[\s\S]*hold: (true|false)/.exec(after);
    return `${before === null ? "생성" : "수정"} (sha256:${m?.[1]}…, revision ${m?.[2]}, hold ${m?.[3]})`;
  }
  const a = parseObj(after, path);
  const b = before === null ? {} : parseObj(before, path);
  const keys = Object.keys(a).filter((k) => !sameValue(a[k], b[k]));
  const parts = keys.map((k) => (k === "public" ? `public ${a.public?.host}` : k === "internal" ? `internal ${a.internal?.name}` : k === "uses" ? `uses ${Object.keys(a.uses).filter((u) => a.uses[u]).join("·")}` : k === "chartVersion" ? `chart ${a.chartVersion}` : k));
  return `${before === null ? "생성" : "수정"} (${parts.join(", ")})`;
}
