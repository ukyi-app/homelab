// homelab cache add: Valkey 연결(설계 C.7·C.5.6, G 시나리오 3·4). 손 절차는 T11 #858(캐시), #859·#860(캐시 → 영속).
// 캐시(앱 차트)와 영속(데이터 차트) Valkey는 이름이 같다(<앱>-valkey Service·Deployment, <앱>-valkey-auth).
// 그래서 한 revision에 둘을 두지 못하고, 캐시를 쓰던 앱의 --persistent는 PR 둘이다: A 캐시 끄기 → 병합·동기화 →
// 같은 명령 재실행 → B 영속 켜기. 어느 단계인지는 main의 앱 values(cache 키)로 고른다. 두 PR은 같은 브랜치를 차례로 쓴다.
// 비밀번호 원본은 둘 다 /apps/<앱>/valkey/PASSWORD라 B는 캐시 때 값을 재사용한다.
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";
import { APP_NAME, appNameProblem } from "../core/names";
import { prStep } from "../core/pr";
import { CliError, UsageError } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

type Obj = Record<string, any>;
const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
const HEADER = "# homelab CLI가 만들었다(설계 C.5). 이 앱 데이터는 앱을 지워도 남는다(data purge로만 지운다).\n";
// 캐시 Valkey(cache.enabled)는 앱 차트 1.1.0부터다.
const CACHE_MIN_CHART = "1.1.0";

const cmp = (a: string, b: string) => a.split(".").map(Number).reduce((d, n, i) => d || n - Number(b.split(".")[i]), 0);

// 앱 차트 app.env와 같은 규칙(platform/charts/app/templates/_helpers.tpl): PORT(web)·DATABASE_URL(uses.postgres)·
// VALKEY_URL(uses.valkey)은 차트가 넣고, env 키와 secrets는 그것들과도 서로도 겹치면 렌더가 막힌다(#884 2라운드 P2-4).
// 병합할 수 없는 PR을 만들지 않게 쓰기 전에 멈춘다. 덮거나 조용히 빼지 않는다.
function envProblem(v: Record<string, any>): string | null {
  const names = [...(v.kind === "web" ? ["PORT"] : []), ...(v.uses?.postgres ? ["DATABASE_URL"] : []), ...(v.uses?.valkey ? ["VALKEY_URL"] : []), ...Object.keys(v.env ?? {}), ...(Array.isArray(v.secrets) ? v.secrets : [])];
  const dup = names.filter((n, i) => names.indexOf(n) !== i);
  return dup.length ? `env 이름 ${[...new Set(dup)].join(", ")}가 두 번 나온다(차트가 넣는 PORT·DATABASE_URL·VALKEY_URL, values env, secrets가 겹친다). 겹치는 쪽을 정리한 뒤 다시 실행한다` : null;
}

function canon(v: unknown): string {
  const sort = (x: unknown): unknown => (Array.isArray(x) ? x.map(sort) : x && typeof x === "object" ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, sort((x as Obj)[k])])) : x);
  return JSON.stringify(sort(v)) ?? "undefined";
}

function obj(text: string | null): Obj {
  const v = text === null ? null : parseYaml(text);
  if (v === null || v === undefined) return {};
  if (typeof v !== "object" || Array.isArray(v)) throw new Error("values: 최상위가 매핑이 아니다");
  return v as Obj;
}

// edits 값이 undefined면 그 키를 지운다. 바뀌는 키만 넘긴다(재실행 same).
function edit(text: string | null, header: string, edits: Obj): string | null {
  const now = obj(text);
  const changed = Object.fromEntries(Object.entries(edits).filter(([k, v]) => canon(now[k]) !== canon(v)));
  if (text !== null && Object.keys(changed).length === 0) return text;
  return setTopLevel(text ?? header, changed);
}

function checked(text: string | null): string | null {
  const problem = text === null ? null : envProblem(obj(text));
  if (problem) throw new Error(problem);
  return text;
}

// 계획·실행 표의 PR 줄. cacheOn이 바꾸는 키를 모두 적는다. cache.enabled만 적으면 VALKEY_URL을 켜는 uses.valkey
// 변경이 표에서 안 보였다(T13 S3 #932).
export function cacheOnSummary(before: string | null, after: string | null): string {
  const b = obj(before);
  const a = obj(after);
  const flags: [string, (v: Obj) => boolean][] = [
    ["cache.enabled", (v) => v.cache?.enabled === true],
    ["uses.valkey", (v) => v.uses?.valkey === true],
  ];
  const parts = flags.filter(([, f]) => f(b) !== f(a)).map(([k, f]) => `${k} ${f(b)} → ${f(a)}`);
  if (b.chartVersion !== a.chartVersion) parts.push(`chart ${a.chartVersion}`);
  return parts.join(", ");
}

export function cacheOn(current: string, latestApp: string): string | null {
  const now = obj(current);
  const chart = typeof now.chartVersion === "string" && cmp(now.chartVersion, CACHE_MIN_CHART) < 0 ? latestApp : now.chartVersion;
  return checked(edit(current, "", { chartVersion: chart, uses: { ...(now.uses ?? {}), valkey: true }, cache: { ...(now.cache ?? {}), enabled: true } }));
}

// 꺼진 캐시(cache: { enabled: false })는 캐시가 아니다. 키 존재로 보면 이미 영속인 앱의 연결(uses.valkey)을 지운다
// (#884 2라운드 P2-1, Connector 4373412607).
export const cacheEnabled = (text: string | null) => obj(text).cache?.enabled === true;

// 단계 A(T11 #859): 캐시 서버와 VALKEY_URL을 함께 끈다. uses가 비면 키째 지운다.
// PR 계산 때 main에서 캐시가 이미 꺼졌으면 그대로 둔다(그사이 누가 껐다. 재실행이 단계 B를 고른다).
export function cacheOff(current: string): string | null {
  if (!cacheEnabled(current)) return current;
  const now = obj(current);
  const uses = { ...(now.uses ?? {}) };
  delete uses.valkey;
  return edit(current, "", { cache: undefined, uses: Object.keys(uses).length ? uses : undefined });
}

// 단계 B(T11 #860).
export function persistentData(current: string | null, latestData: string): string | null {
  const now = obj(current);
  return edit(current, HEADER, { ...(current === null ? { chartVersion: latestData } : {}), valkey: { ...(now.valkey ?? {}), persistent: true } });
}

// 단계 B. PR 계산 때 main에 그사이 캐시가 켜졌으면 멈춘다(시작 때의 단계 선택이 낡았다, #884 2라운드 P2-2).
export function usesValkey(current: string): string | null {
  if (cacheEnabled(current)) throw new Error("그사이 main에 캐시 Valkey가 켜졌다. 같은 명령을 다시 실행해 단계를 다시 고른다");
  const now = obj(current);
  return checked(edit(current, "", { uses: { ...(now.uses ?? {}), valkey: true } }));
}

function latest(ctx: ReadCtx, prefix: "app-chart-v" | "data-chart-v"): string {
  const r = ctx.gh.get(`repos/ukyi-app/homelab/git/matching-refs/tags/${prefix}`);
  const re = new RegExp(`^refs/tags/${prefix}([0-9]+\\.[0-9]+\\.[0-9]+)$`);
  const v = ((Array.isArray(r.json) ? r.json : []).map((x: any) => re.exec(String(x?.ref))?.[1]).filter(Boolean) as string[]).sort(cmp).at(-1);
  if (r.status !== 200 || !v) throw new CliError(`차트 태그 ${prefix}*를 읽지 못했다(HTTP ${r.status})`, "gh auth status로 로그인을 확인한 뒤 다시 실행한다");
  return v;
}

function passwordStep(app: string): Step {
  const folder = `/apps/${app}/valkey`;
  return {
    id: "infisical-password",
    target: `Infisical homelab/prod ${folder}/PASSWORD`,
    async read(c) {
      if (!c.infisical.folderExists(`/apps/${app}`) || !c.infisical.folderExists(folder)) return { state: "missing", action: "create", detail: "없음 → 생성(폴더 포함)" };
      return c.infisical.has(folder, "PASSWORD") ? same("있음 (그대로 사용)") : { state: "missing", action: "create", detail: "없음 → 생성" };
    },
    async apply(w) {
      if (!w.infisical.folderExists(`/apps/${app}`) || !w.infisical.folderExists(folder)) w.infisical.createFolder(folder);
      if (!w.infisical.has(folder, "PASSWORD")) w.infisical.setValue(folder, "PASSWORD", w.generatePassword());
    },
  };
}

// 단계 B 앞의 대기: 앱 Application이 아직 캐시 서버 리소스를 갖고 있으면 영속을 켜지 않는다.
// 캐시 렌더(app 차트 1.1.0): <앱>-valkey(Deployment·Service), -valkey-auth, -valkey-config, -valkey-init-scripts,
// -valkey-url. 이 가운데 -valkey-url(연결 ExternalSecret)은 uses.valkey가 있으면 영속에서도 앱 Application 몫이라 기다릴
// 대상이 아니다(#884 리뷰 P2-1: 넣으면 다 된 재실행이 영원히 대기). 영속 서버는 데이터 Application(<앱>-data) 몫이다.
export function cacheGoneStep(app: string): Step {
  return {
    id: "cache-gone",
    target: `Argo CD ${app}의 캐시 Valkey 정리`,
    async read(c) {
      const a = c.k8s.get("application", "argocd", app);
      const left = (Array.isArray(a?.status?.resources) ? a.status.resources : []).filter((r: { name?: string }) => typeof r?.name === "string" && r.name !== `${app}-valkey-url` && (r.name === `${app}-valkey` || r.name.startsWith(`${app}-valkey-`)));
      if (left.length === 0) return same("캐시 리소스 없음");
      return same(`캐시 리소스 ${left.length}개 남음`, { hold: "캐시 Valkey 정리 대기(Argo CD 동기화)" });
    },
  };
}

export default defineCommand({
  path: ["cache", "add"],
  summary: "Valkey 연결(캐시, --persistent면 영속)",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [{ name: "persistent", kind: "bool", help: "영속 Valkey(데이터 차트, 백업)" }],
  async run(ctx, input) {
    const app = input.args.app as string;
    const persistent = input.flags.persistent === true;
    const problem = appNameProblem(app, persistent ? { persistent: true } : { cache: true });
    if (problem) throw new UsageError(problem);
    // 데이터 차트도 영속 Valkey 앱 이름의 valkey를 막는다. core appNameProblem은 캐시에서만 본다(#884 2라운드 P2-3).
    if (persistent && app.includes("valkey")) throw new UsageError("영속 Valkey를 쓰는 앱 이름에 valkey를 넣지 않는다(데이터 차트가 렌더를 막는다)");
    const appPath = `apps/${app}/values.yaml`;
    const dataPath = `data/${app}/values.yaml`;
    const main = ctx.repo.mainSha();
    const appNow = ctx.repo.readFile(appPath, main);
    const dataNow = ctx.repo.readFile(dataPath, main);

    const registered: Step = {
      id: "registered",
      target: `등록 ${appPath}`,
      async read() {
        if (appNow === null) return { state: "missing", action: "none", detail: "없음(등록 전)", next: `homelab app add ${app} --cache${persistent ? "=persistent" : ""}` };
        if (!persistent && obj(dataNow).valkey?.persistent === true) return { state: "differs", action: "none", detail: "이미 영속 Valkey다(data values valkey.persistent)", next: "할 일 없음(영속 Valkey가 VALKEY_URL을 준다)" };
        return same("있음");
      },
    };

    if (!persistent) {
      const appChart = latest(ctx, "app-chart-v");
      const steps: Step[] = [
        registered,
        passwordStep(app),
        prStep({
          command: "cache add",
          app,
          title: `cache add: ${app}`,
          body: `homelab cache add가 만든 PR이다(설계 C.5.6). ${app} ns에 캐시 Valkey(PVC 없음, allkeys-lru)와 VALKEY_URL을 켠다.`,
          // 데이터 파일을 늘 함께 읽어(내용 그대로) PR 계산 때 영속 Valkey가 그사이 켜졌는지 본다. 시작 때 없던 파일도
          // 본다(#890 1라운드 P2-1). 바뀌지 않은 파일은 core가 tree에서 뺀다.
          files: [appPath, dataPath],
          edit: (cur) => {
            if (obj(cur[dataPath]).valkey?.persistent === true) throw new Error("그사이 main에 영속 Valkey가 켜졌다(캐시와 함께 둘 수 없다)");
            return { [appPath]: cur[appPath] === null ? null : cacheOn(cur[appPath], appChart), [dataPath]: cur[dataPath] };
          },
          describe: (_p, before, after) => cacheOnSummary(before, after),
        }),
      ];
      return ctx.engine({ command: "cache add", app, steps });
    }

    // 영속: 단계 A(캐시가 켜져 있음) 또는 B.
    if (cacheEnabled(appNow)) {
      const steps: Step[] = [
        registered,
        prStep({
          command: "cache add",
          app,
          title: `cache add: ${app} 캐시 Valkey 끄기(영속 전환 1/2)`,
          body: `homelab cache add --persistent의 첫 PR이다. 캐시와 영속 Valkey는 이름이 같아 캐시를 먼저 끈다(T11 #859). 병합·동기화 뒤 같은 명령을 다시 실행하면 영속 Valkey PR을 만든다. 그사이 앱은 Valkey 없이 돈다.`,
          files: [appPath],
          edit: (cur) => ({ [appPath]: cur[appPath] === null ? null : cacheOff(cur[appPath]) }),
          describe: () => "cache·uses.valkey 지움",
        }),
      ];
      return ctx.engine({ command: "cache add", app, steps, notes: ["영속 전환 1/2: 병합·동기화 뒤 같은 명령을 다시 실행하면 2/2(영속 Valkey) PR을 만든다"] });
    }
    const dataChart = latest(ctx, "data-chart-v");
    const steps: Step[] = [
      registered,
      cacheGoneStep(app),
      passwordStep(app),
      prStep({
        command: "cache add",
        app,
        title: `cache add: ${app} 영속 Valkey`,
        body: `homelab cache add --persistent가 만든 PR이다(설계 C.5.6). 데이터 차트가 영속 Valkey(PVC valkey-data, 하루 1회 R2 백업)를 만들고 앱에 VALKEY_URL을 켠다.`,
        files: [dataPath, appPath],
        edit: (cur) => ({ [dataPath]: persistentData(cur[dataPath], dataChart), [appPath]: cur[appPath] === null ? null : usesValkey(cur[appPath]) }),
        describe: (path, before) => (path === dataPath ? (before === null ? "생성 (valkey persistent)" : "valkey.persistent → true") : "uses.valkey → true"),
      }),
    ];
    return ctx.engine({ command: "cache add", app, steps });
  },
});
