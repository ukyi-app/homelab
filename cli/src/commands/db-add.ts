// homelab db add: PostgreSQL 연결(설계 C.7, G 시나리오 2). 손 절차는 T11 #854(앱)·#855(데이터).
// 데이터 values(역할·DB)와 앱 values(uses.postgres)를 한 PR에 넣는다. 데이터 Application이 늦으면 마이그레이션 Job이
// 한 번 실패하고 retry로 수렴한다(T11 05:00~05:08 실측). 마이그레이션 명령은 앱 values의 몫이라 건드리지 않는다.
// 명령끼리 도우미를 나눌 수 없어(정적 시험: 자기 접두만 import) app add와 같은 작은 조각을 여기 다시 둔다.
import { defineCommand, type Observation, type ReadCtx, type Step } from "../core/command";
import { APP_NAME, appNameProblem } from "../core/names";
import { prStep } from "../core/pr";
import { CliError, UsageError } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

type Obj = Record<string, any>;
const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const HEADER = "# homelab CLI가 만들었다(설계 C.5). 이 앱 데이터는 앱을 지워도 남는다(data purge로만 지운다).\n";

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

// 바뀌는 키만 고친다. 같은 값을 다시 쓰면 사람이 쓴 블록 꼴이 flow로 바뀌어 재실행이 same이 되지 않는다.
function edit(text: string | null, header: string, edits: Obj): string | null {
  const now = obj(text);
  const changed = Object.fromEntries(Object.entries(edits).filter(([k, v]) => canon(now[k]) !== canon(v)));
  if (text !== null && Object.keys(changed).length === 0) return text;
  return setTopLevel(text ?? header, changed);
}

export function dbValues(current: string | null, latestChart: string): string | null {
  const now = obj(current);
  return edit(current, HEADER, { ...(current === null ? { chartVersion: latestChart } : {}), postgres: { ...(now.postgres ?? {}), enabled: true } });
}

export function appUsesPostgres(current: string): string | null {
  const now = obj(current);
  return edit(current, "", { uses: { ...(now.uses ?? {}), postgres: true } });
}

function latestData(ctx: ReadCtx): string {
  const r = ctx.gh.get("repos/ukyi-app/homelab/git/matching-refs/tags/data-chart-v");
  const vs = (Array.isArray(r.json) ? r.json : []).map((x: any) => /^refs\/tags\/data-chart-v([0-9]+\.[0-9]+\.[0-9]+)$/.exec(String(x?.ref))?.[1]).filter(Boolean) as string[];
  const cmp = (a: string, b: string) => a.split(".").map(Number).reduce((d, n, i) => d || n - Number(b.split(".")[i]), 0);
  const v = vs.sort(cmp).at(-1);
  if (r.status !== 200 || !v) throw new CliError(`차트 태그 data-chart-v*를 읽지 못했다(HTTP ${r.status})`, "gh auth status로 로그인을 확인한 뒤 다시 실행한다");
  return v;
}

export default defineCommand({
  path: ["db", "add"],
  summary: "PostgreSQL 연결(Infisical 비밀번호, data·apps PR)",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [],
  async run(ctx, input) {
    const app = input.args.app as string;
    const problem = appNameProblem(app);
    if (problem) throw new UsageError(problem);
    const appPath = `apps/${app}/values.yaml`;
    const dataPath = `data/${app}/values.yaml`;
    const folder = `/apps/${app}/postgres`;
    const chart = latestData(ctx);
    const registered = ctx.repo.readFile(appPath, ctx.repo.mainSha()) !== null;

    const steps: Step[] = [
      {
        id: "registered",
        target: `등록 ${appPath}`,
        async read() {
          return !registered ? { state: "missing", action: "none", detail: "없음(등록 전)", next: `homelab app add ${app} --postgres` } : same("있음");
        },
      },
      {
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
      },
      prStep({
        command: "db add",
        app,
        title: `db add: ${app}`,
        body: `homelab db add가 만든 PR이다(설계 C.7). ${app}에 공유 PostgreSQL 역할·DB(data)와 DATABASE_URL(앱)을 연결한다. 비밀번호는 Infisical ${folder}/PASSWORD에만 있다.`,
        files: [dataPath, appPath],
        edit(cur) {
          // 등록 전이면(앱 values 없음) 등록 단계가 막는다. 여기서는 내용을 바꾸지 않는다.
          return { [dataPath]: dbValues(cur[dataPath], chart), [appPath]: cur[appPath] === null ? null : appUsesPostgres(cur[appPath]) };
        },
        describe: (path, before, after) => (path === dataPath ? (before === null ? "생성 (postgres)" : "postgres.enabled → true") : `uses.postgres: ${obj(before).uses?.postgres === true} → ${obj(after).uses?.postgres === true}`),
      }),
    ];
    return ctx.engine({ command: "db add", app, steps, notes: ["데이터 Application이 늦으면 마이그레이션 Job이 한 번 실패하고 retry로 수렴한다(시나리오 2)"] });
  },
});
