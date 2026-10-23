// PR 작성기(D3) 시험. 02~04가 prStep을 쓰는 명령의 시험을 이 규칙 모양으로 만든다.
import { describe, expect, test } from "bun:test";
import { HOMELAB_REPO } from "../../src/core/github";
import { branchName, prStep } from "../../src/core/pr";
import { FAKE_SHA, expectPlanReadOnly, ghGet, ghResponse, ghSend, testCtx, type Rule } from "../harness";

const R = `repos/${HOMELAB_REPO}`;
const BRANCH = "cli/db-add-smoke";
const PR_HEAD = "b".repeat(40);
const NEW_COMMIT = "c".repeat(40);
const file = (content: string) => ({ type: "file", encoding: "base64", content: Buffer.from(content).toString("base64") });
const contents = (path: string, ref: string) => `${R}/contents/${path}?ref=${ref}`;
const pulls = `${R}/pulls?head=${encodeURIComponent(`ukyi-app:${BRANCH}`)}&state=open`;

const spec = { command: "db add", app: "smoke", title: "feat(smoke): PostgreSQL 연결", body: "homelab db add smoke --apply", changes: [{ path: "data/smoke/values.yaml", content: "postgres:\n  enabled: true\n" }] };

function mainAt(sha = FAKE_SHA): Rule {
  return ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha } });
}

describe("PR 작성기", () => {
  test("브랜치 이름은 cli/<동사>-<app>", () => {
    expect(branchName("db add", "smoke")).toBe(BRANCH);
    expect(branchName("app add", "memo")).toBe("cli/app-add-memo");
  });

  test("main과 같으면 same(PR 필요 없음)", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 200, file(spec.changes[0].content))]);
    const o = await prStep(spec).read(ctx);
    expect(o.state).toBe("same");
    expectPlanReadOnly(calls());
  });

  test("main과 다르고 열린 PR이 없으면 missing/create", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 404, { message: "Not Found" }), ghGet(pulls, 200, [])]);
    const o = await prStep(spec).read(ctx);
    expect([o.state, o.action]).toEqual(["missing", "create"]);
    expectPlanReadOnly(calls());
  });

  test("열린 PR 내용이 같으면 same + 병합 대기, 다르면 differs/update", async () => {
    const base = [mainAt(), ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 404, {}), ghGet(pulls, 200, [{ number: 12, head: { sha: PR_HEAD } }])];
    const same = testCtx("plan", [...base, ghGet(contents("data/smoke/values.yaml", PR_HEAD), 200, file(spec.changes[0].content))]);
    const o1 = await prStep(spec).read(same.ctx);
    expect([o1.state, o1.wait]).toEqual(["same", "PR #12 검토·병합 대기"]);
    const diff = testCtx("plan", [...base, ghGet(contents("data/smoke/values.yaml", PR_HEAD), 200, file("old\n"))]);
    const o2 = await prStep(spec).read(diff.ctx);
    expect([o2.state, o2.action]).toEqual(["differs", "update"]);
  });

  test("apply 새로: tree(내용 직접) → commit(부모 main, 트레일러) → ref 생성 → PR 생성. 엔진 결과는 waiting(3)", async () => {
    const rules: Rule[] = [
      mainAt(),
      // 읽기(전체·직전) 두 번은 없음, 실행 뒤 재조회는 PR 브랜치에 있음.
      ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 404, {}),
      ghGet(pulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), ghResponse(200, [{ number: 7, head: { sha: NEW_COMMIT } }])]),
      ghGet(contents("data/smoke/values.yaml", NEW_COMMIT), 200, file(spec.changes[0].content)),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { tree: { sha: "d".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 404, {}),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, 201, { number: 7 }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("waiting");
    expect(r.steps[0].result).toBe("waiting");
    const c = calls();
    expect(c.unmatched).toEqual([]);
    const sent = c.calls.filter((x) => x.stdin !== undefined).map((x) => [x.argv[4], x.argv[5], JSON.parse(x.stdin!)]);
    expect(sent[0][2]).toEqual({ base_tree: "d".repeat(40), tree: [{ path: "data/smoke/values.yaml", mode: "100644", type: "blob", content: spec.changes[0].content }] });
    expect(sent[1][2].parents).toEqual([FAKE_SHA]);
    expect(sent[1][2].message).toEndWith("\n\nHomelab-CLI: db add");
    expect(sent[2][2]).toEqual({ ref: `refs/heads/${BRANCH}`, sha: NEW_COMMIT });
    expect(sent[3][2]).toMatchObject({ head: BRANCH, base: "main" });
  });

  test("브랜치 머리가 사람 커밋이면(트레일러 없음) 덮지 않고 실패", async () => {
    const rules: Rule[] = [
      mainAt(),
      ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 404, {}),
      ghGet(pulls, 200, []),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { tree: { sha: "d".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: PR_HEAD } }),
      ghGet(`${R}/git/commits/${PR_HEAD}`, 200, { message: "사람이 고친 커밋" }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("트레일러");
    expect(calls().calls.some((c) => c.argv.includes("PATCH"))).toBe(false);
  });

  test("CLI 커밋이면 최신 main 부모로 force 이동하고 열린 PR을 갱신", async () => {
    const rules: Rule[] = [
      mainAt(),
      ghGet(contents("data/smoke/values.yaml", FAKE_SHA), 404, {}),
      ghGet(pulls, [ghResponse(200, [{ number: 12, head: { sha: PR_HEAD } }]), ghResponse(200, [{ number: 12, head: { sha: PR_HEAD } }]), ghResponse(200, [{ number: 12, head: { sha: PR_HEAD } }]), ghResponse(200, [{ number: 12, head: { sha: NEW_COMMIT } }])]),
      ghGet(contents("data/smoke/values.yaml", PR_HEAD), 200, file("old\n")),
      ghGet(contents("data/smoke/values.yaml", NEW_COMMIT), 200, file(spec.changes[0].content)),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { tree: { sha: "d".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: PR_HEAD } }),
      ghGet(`${R}/git/commits/${PR_HEAD}`, 200, { message: "feat(smoke): x\n\nHomelab-CLI: db add" }),
      ghSend("PATCH", `${R}/git/refs/heads/${BRANCH}`, 200, {}),
      ghSend("PATCH", `${R}/pulls/12`, 200, {}),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("waiting");
    const patch = calls().calls.find((c) => c.argv.includes(`${R}/git/refs/heads/${BRANCH}`) && c.argv.includes("PATCH"));
    expect(JSON.parse(patch!.stdin!)).toEqual({ sha: NEW_COMMIT, force: true });
  });

  test("변경 검증: 경로·중복·시크릿", () => {
    expect(() => prStep({ ...spec, changes: [{ path: "../x", content: "" }] })).toThrow();
    expect(() => prStep({ ...spec, changes: [{ path: "a\nb", content: "" }] })).toThrow();
    expect(() => prStep({ ...spec, changes: [spec.changes[0], spec.changes[0]] })).toThrow();
    expect(() => prStep({ ...spec, changes: [] })).toThrow();
  });
});
