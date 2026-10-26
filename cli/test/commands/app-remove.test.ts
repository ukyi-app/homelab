import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, ghGet, ghResponse, runCli, type Rule } from "../harness";
import { MAIN, R, homelab, imageYaml, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

const APP = "memo";
const BRANCH = `cli/app-remove-${APP}`;
const V = `apps/${APP}/values.yaml`;
const I = `apps/${APP}/image.yaml`;
const gone = { [I]: null, [V]: null };
const listing = (names: string[] | null) => (names === null ? ghGet(`${R}/contents/apps/${APP}?ref=${MAIN}`, 404, {}) : ghGet(`${R}/contents/apps/${APP}?ref=${MAIN}`, 200, names.map((name) => ({ name, type: "file" }))));
const SLOT = "platform/bot-slot/values.yaml";
const slotText = (app: string) => `target:\n  namespace: x\n  app: ${app}\n`;
const botSlot = (app: string) => homelab({ [SLOT]: slotText(app) })[1];
const ro = { [SLOT]: slotText("bot-slot-probe") };

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
    const r = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prCreate(BRANCH, "app remove", gone, { readOnly: ro }) }));
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!;
    // bot-slot은 읽기만 해서 tree에 없다(#890 1라운드 P2-4).
    expect(JSON.parse(tree.stdin!).tree.map((t: any) => [t.path, t.sha])).toEqual([[I, null], [V, null]]);
    const failed = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prCreate(BRANCH, "app remove", gone, { treeCode: 500, readOnly: ro }) }));
    expect(failed.code).toBe(1);
  });

  test("이미 지웠으면 same, 열린 PR이면 대기", async () => {
    const done = await runCli(["app", "remove", APP, "--apply", "--json"], world({ names: null, pr: [noPr(BRANCH)] }));
    expect(done.code).toBe(0);
    expect(done.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(done.writes).toEqual([]);
    const open = await runCli(["app", "remove", APP, "--apply", "--json"], world({ pr: prOpen(BRANCH, "app remove", gone, undefined, ro) }));
    expect(open.code).toBe(3);
    expect(open.writes).toEqual([]);
  });

  test("확인 단계 뒤 PR 계산 때의 main에서 bot-slot target이 이 앱이 됐으면 삭제 PR을 만들지 않는다(#890 1라운드 P2-3)", async () => {
    const MAIN2 = "9".repeat(40);
    const rules: Rule[] = [
      // 명령 시작·전체 읽기·apply 직전 읽기의 main 조회(run 1 + 확인 두 단계 × 두 번 + PR 읽기 두 번)는 MAIN, apply 안의 PR 계산부터 MAIN2.
      ghGet(`${R}/git/ref/heads/main`, [...Array(7).fill(ghResponse(200, { object: { sha: MAIN } })), ghResponse(200, { object: { sha: MAIN2 } })]),
      ...homelab({ [V]: "kind: web\n", [I]: imageYaml(APP), [`data/${APP}/values.yaml`]: null }).slice(1),
      listing(["values.yaml", "image.yaml"]),
      botSlot("bot-slot-probe"),
      ghGet(`${R}/contents/${V}?ref=${MAIN2}`, 200, { type: "file", encoding: "base64", content: Buffer.from("kind: web\n").toString("base64") }),
      ghGet(`${R}/contents/${I}?ref=${MAIN2}`, 200, { type: "file", encoding: "base64", content: Buffer.from(imageYaml(APP)).toString("base64") }),
      ghGet(`${R}/contents/${SLOT}?ref=${MAIN2}`, 200, { type: "file", encoding: "base64", content: Buffer.from(slotText(APP)).toString("base64") }),
      ...prCreate(BRANCH, "app remove", gone, { readOnly: ro }),
    ];
    const r = await runCli(["app", "remove", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("bot-slot target");
    expect(r.writes).toEqual([]);
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
