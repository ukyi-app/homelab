import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, ghGet, runCli, type Rule } from "../harness";
import { MAIN, R, homelab, imageYaml, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

const APP = "memo";
const BRANCH = `cli/app-remove-${APP}`;
const V = `apps/${APP}/values.yaml`;
const I = `apps/${APP}/image.yaml`;
const gone = { [I]: null, [V]: null };
const listing = (names: string[] | null) => (names === null ? ghGet(`${R}/contents/apps/${APP}?ref=${MAIN}`, 404, {}) : ghGet(`${R}/contents/apps/${APP}?ref=${MAIN}`, 200, names.map((name) => ({ name, type: "file" }))));
const botSlot = (app: string) => homelab({ "platform/bot-slot/values.yaml": `target:\n  namespace: x\n  app: ${app}\n` })[1];

function world(o: { names?: string[] | null; bot?: string; data?: boolean; pr: Rule[] }): Rule[] {
  const present = o.names === null ? gone : { [V]: "kind: web\n", [I]: imageYaml(APP) };
  return [...homelab({ ...present, [`data/${APP}/values.yaml`]: o.data ? "postgres: { enabled: true }\n" : null }), listing(o.names === undefined ? ["values.yaml", "image.yaml"] : o.names), botSlot(o.bot ?? "bot-slot-probe"), ...o.pr];
}

describe("app remove", () => {
  test("plan: 두 파일 삭제, 데이터는 남는다고 알린다", async () => {
    const r = await runCli(["app", "remove", APP, "--json"], world({ data: true, pr: [noPr(BRANCH)] }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain(`${I}: 삭제`);
    expect(r.json.notes.join(" ")).toContain(`homelab data purge ${APP} --confirm ${APP}`);
  });

  test("apply: 삭제 PR(sha null) → 대기, 실패 주입 → exit 1", async () => {
    const r = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prCreate(BRANCH, "app remove", gone) }));
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!;
    expect(JSON.parse(tree.stdin!).tree.every((t: any) => t.sha === null)).toBe(true);
    const failed = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prCreate(BRANCH, "app remove", gone, { treeCode: 500 }) }));
    expect(failed.code).toBe(1);
  });

  test("이미 지웠으면 same, 열린 PR이면 대기", async () => {
    const done = await runCli(["app", "remove", APP, "--apply", "--json"], world({ names: null, pr: [noPr(BRANCH)] }));
    expect(done.code).toBe(0);
    expect(done.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(done.writes).toEqual([]);
    const open = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prOpen(BRANCH, "app remove", gone) }));
    expect(open.code).toBe(3);
    expect(open.writes).toEqual([]);
  });

  test("모르는 파일이 있거나 bot-slot target이면 쓰지 않는다", async () => {
    const extra = await runCli(["app", "remove", APP, "--apply", "--json"], world({ names: ["values.yaml", "image.yaml", "notes.md"], pr: [noPr(BRANCH)] }));
    expect(extra.code).toBe(1);
    expect(extra.writes).toEqual([]);
    const bot = await runCli(["app", "remove", APP, "--apply", "--json"], world({ bot: APP, pr: [noPr(BRANCH)] }));
    expect(bot.code).toBe(1);
    expect(bot.json.error.next).toContain("probe: true");
  });
});
