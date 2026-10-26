import { describe, expect, test } from "bun:test";
import { matches } from "../../src/commands/rollback";
import { expectPlanReadOnly, ghGet, runCli, type Rule } from "../harness";
import { APP_HEAD, DIGEST, OLD_DIGEST, OLD_REV, R, contentsPath, fileJson, homelab, imageYaml, noPr, prCreate, prOpen, pullsPath } from "../fixtures/app-add-world/world";

const APP = "memo";
const P = `apps/${APP}/image.yaml`;
const BRANCH = `cli/rollback-${APP}`;
const C1 = "3".repeat(40);
const C2 = "4".repeat(40);
const NOW = imageYaml(APP);
const BACK = imageYaml(APP, OLD_DIGEST, OLD_REV, true);

function world(current: string, extra: Rule[], o: { deployPr?: boolean; packages?: string[] } = {}): Rule[] {
  return [
    ...homelab({ [P]: current }),
    ghGet(`${R}/commits?path=${P}&sha=main&per_page=30`, 200, [{ sha: C1 }, { sha: C2 }]),
    ghGet(contentsPath(P, C1), 200, fileJson(NOW)),
    ghGet(contentsPath(P, C2), 200, fileJson(imageYaml(APP, OLD_DIGEST, OLD_REV))),
    ghGet(`orgs/ukyi-app/packages/container/${APP}/versions?per_page=100`, 200, (o.packages ?? [DIGEST, OLD_DIGEST]).map((name) => ({ name }))),
    ghGet(pullsPath(`deploy/${APP}`), 200, o.deployPr ? [{ number: 40, head: { sha: "5".repeat(40) }, base: { ref: "main" } }] : []),
    ...extra,
  ];
}

describe("rollback", () => {
  test("plan --to <접두>: 이전 이미지 + hold true, 열린 배포 PR이면 경고", async () => {
    const r = await runCli(["rollback", APP, "--to", OLD_REV.slice(0, 7), "--json"], world(NOW, [noPr(BRANCH)], { deployPr: true }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain(`${APP_HEAD.slice(0, 7)} hold false → ${OLD_REV.slice(0, 7)} hold true`);
    expect(r.json.notes.join(" ")).toContain("gh pr close 40");
  });

  test("apply --to digest: PR, 다 된 상태는 same", async () => {
    const r = await runCli(["rollback", APP, "--to", OLD_DIGEST, "--apply", "--json"], world(NOW, prCreate(BRANCH, "rollback", { [P]: BACK })));
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!;
    expect(JSON.parse(tree.stdin!).tree[0].content).toBe(BACK);
    const done = await runCli(["rollback", APP, "--to", OLD_DIGEST, "--apply", "--json"], world(BACK, [noPr(BRANCH)]));
    expect(done.code).toBe(0);
    expect(done.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(done.writes).toEqual([]);
  });

  test("--release: hold false만, PR 쓰기 실패는 exit 1, 열린 PR은 대기", async () => {
    const plan = await runCli(["rollback", APP, "--release", "--json"], world(BACK, [noPr(BRANCH)]));
    expect(plan.json.steps.find((s: any) => s.id === "pr").detail).toContain("hold true → ");
    const failed = await runCli(["rollback", APP, "--release", "--apply", "--json"], world(BACK, prCreate(BRANCH, "rollback", { [P]: imageYaml(APP, OLD_DIGEST, OLD_REV, false) }, { treeCode: 500 })));
    expect(failed.code).toBe(1);
    const open = await runCli(["rollback", APP, "--release", "--apply", "--json"], world(BACK, prOpen(BRANCH, "rollback", { [P]: imageYaml(APP, OLD_DIGEST, OLD_REV, false) })));
    expect(open.code).toBe(3);
    expect(open.writes).toEqual([]);
  });

  test("기록에 없거나 GHCR에서 지워졌으면 쓰지 않고 멈춘다", async () => {
    const none = await runCli(["rollback", APP, "--to", "9999999", "--apply", "--json"], world(NOW, [noPr(BRANCH)]));
    expect(none.code).toBe(1);
    expect(none.writes).toEqual([]);
    const gone = await runCli(["rollback", APP, "--to", OLD_REV, "--apply", "--json"], world(NOW, [noPr(BRANCH)], { packages: [DIGEST] }));
    expect(gone.code).toBe(1);
    expect(gone.json.error.message).toContain("GHCR에");
  });

  test("사용법: --to와 --release는 하나만, 하나는 필수", async () => {
    expect((await runCli(["rollback", APP], [])).code).toBe(64);
    expect((await runCli(["rollback", APP, "--to", OLD_REV, "--release"], [])).code).toBe(64);
    expect((await runCli(["rollback", APP, "--to", "abc"], [])).code).toBe(64);
  });

  test("접두가 서로 다른 이미지 둘에 맞으면 고르지 않는다", () => {
    const a = { repository: "r", digest: DIGEST, revision: `abcdef1${"0".repeat(33)}`, hold: false };
    const b = { ...a, digest: OLD_DIGEST, revision: `abcdef1${"1".repeat(33)}` };
    expect(matches([a, b, a], "abcdef1").length).toBe(2);
    expect(matches([a, b, a], a.revision).length).toBe(1);
  });
});
