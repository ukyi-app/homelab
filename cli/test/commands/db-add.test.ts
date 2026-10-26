import { describe, expect, test } from "bun:test";
import { appUsesPostgres, dbValues } from "../../src/commands/db-add";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, infisicalSet, runCli, type Rule } from "../harness";
import { chartTags, folders, homelab, infisicalList, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

// 타임아웃 주입(스텁 5초 지연 > exec 상한 3초)이 든 시험은 3초를 넘는다. bun 기본 시험 제한(5초)에 걸리지 않게 늘린다.
const SLOW = 20_000;
const APP = "memo";
const BRANCH = `cli/db-add-${APP}`;
const A = `apps/${APP}/values.yaml`;
const D = `data/${APP}/values.yaml`;
const PG = `/apps/${APP}/postgres`;
const APP_VALUES = "# 사람 주석\nchartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\n";
const want = { [D]: dbValues(null, "1.0.1")!, [A]: appUsesPostgres(APP_VALUES)! };
const fold = () => folders({ "/apps": [APP], [`/apps/${APP}`]: ["postgres"] });

function world(o: { done?: boolean; setCode?: number; setSleep?: number; tree?: number; open?: boolean } = {}): Rule[] {
  const none = { stdout: "[]" };
  const has = { stdout: JSON.stringify([{ secretKey: "PASSWORD", secretValue: FAKE_SECRETS[0] }]) };
  return [
    ...homelab(o.done ? want : { [A]: APP_VALUES, [D]: null }),
    ...chartTags(),
    ...fold(),
    infisicalList(PG, o.done || o.open ? [has] : [none, none, none, has]),
    infisicalSet(PG, { code: o.setCode ?? 0, sleepMs: o.setSleep }),
    ...(o.done ? [noPr(BRANCH)] : o.open ? prOpen(BRANCH, "db add", want) : prCreate(BRANCH, "db add", want, { treeCode: o.tree })),
  ];
}

describe("db add", () => {
  test("plan: 비밀번호 없음 → 생성, data 생성, uses.postgres false → true", async () => {
    const r = await runCli(["db", "add", APP, "--json"], world());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    const pr = r.json.steps.find((s: any) => s.id === "pr");
    expect(pr.detail).toContain(`${D}: 생성 (postgres)`);
    expect(pr.detail).toContain(`${A}: uses.postgres: false → true`);
    expect(r.json.steps.find((s: any) => s.id === "infisical-password").state).toBe("missing");
  });

  test("apply: 비밀번호 → PR → 대기, 앱 values의 사람 주석은 남는다", async () => {
    const r = await runCli(["db", "add", APP, "--apply", "--json"], world());
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes("repos/ukyi-app/homelab/git/trees"))!;
    const files = Object.fromEntries(JSON.parse(tree.stdin!).tree.map((t: any) => [t.path, t.content]));
    expect(files[A]).toBe("# 사람 주석\nchartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nuses: { postgres: true }\n");
    expect(files[D]).toContain("postgres: { enabled: true }");
    expectNoSecrets(r);
  });

  test("다 된 상태 apply: 모두 same, 쓰기 0건", async () => {
    const r = await runCli(["db", "add", APP, "--apply", "--json"], world({ done: true }));
    expect(r.code).toBe(0);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("중간 실패 → exit 1, PR not-run. 재실행(비밀번호 있음, PR 열림)은 대기로 이어진다", async () => {
    const r = await runCli(["db", "add", APP, "--apply", "--json"], world({ setCode: 1 }));
    expect(r.code).toBe(1);
    expect(r.json.steps.find((s: any) => s.id === "pr").result).toBe("not-run");
    const again = await runCli(["db", "add", APP, "--apply", "--json"], world({ open: true }));
    expect(again.code).toBe(3);
    expect(again.writes).toEqual([]);
  });

  test("Infisical 쓰기 타임아웃은 재조회로 확인한다", async () => {
    const r = await runCli(["db", "add", APP, "--apply", "--json"], world({ setSleep: 5000 }));
    expect(r.code).toBe(3);
    expect(r.json.notes.join(" ")).toContain("시간 초과 뒤 다시 읽어");
  }, SLOW);

  test("PR tree 실패는 exit 1", async () => {
    const r = await runCli(["db", "add", APP, "--apply", "--json"], world({ tree: 500 }));
    expect(r.code).toBe(1);
    expect(r.json.steps.find((s: any) => s.id === "pr").result).toBe("failed");
  });

  test("등록 전이면 app add로 안내하고 쓰지 않는다", async () => {
    const rules = [...homelab({ [A]: null, [D]: null }), ...chartTags(), ...fold(), infisicalList(PG, {}), noPr(BRANCH)];
    const r = await runCli(["db", "add", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab app add ${APP} --postgres`);
    expect(r.writes).toEqual([]);
  });

  test("env 이름 충돌(values env.DATABASE_URL)은 쓰기 전에 멈춘다(#884 2라운드 P2-4)", async () => {
    const withEnv = `${APP_VALUES}env: { DATABASE_URL: postgres://x }\n`;
    const r = await runCli(["db", "add", APP, "--apply", "--json"], [...homelab({ [A]: withEnv, [D]: null }), ...chartTags(), ...fold(), infisicalList(PG, {}), noPr(BRANCH)]);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("DATABASE_URL");
    expect(r.writes).toEqual([]);
  });

  test("기존 data values(영속 Valkey)에는 postgres 키만 더한다", () => {
    const cur = "# T11\nchartVersion: 1.0.1\nvalkey: { persistent: true }\n";
    expect(dbValues(cur, "1.0.1")).toBe("# T11\nchartVersion: 1.0.1\nvalkey: { persistent: true }\npostgres: { enabled: true }\n");
    expect(dbValues("chartVersion: 1.0.1\npostgres: { enabled: true }\n", "1.0.1")).toBe("chartVersion: 1.0.1\npostgres: { enabled: true }\n");
  });
});
