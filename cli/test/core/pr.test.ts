// PR 작성기(D3) 시험. 02~04가 prStep을 쓰는 명령의 시험을 이 규칙 모양으로 만든다.
import { describe, expect, test } from "bun:test";
import { HOMELAB_REPO } from "../../src/core/github";
import { branchName, prStep } from "../../src/core/pr";
import { FAKE_SHA, expectPlanReadOnly, ghGet, ghResponse, ghSend, testCtx, type Rule } from "../harness";

const R = `repos/${HOMELAB_REPO}`;
const BRANCH = "cli/db-add-smoke";
const HEAD = "b".repeat(40);
const NEW_COMMIT = "c".repeat(40);
const PATH = "data/smoke/values.yaml";
const file = (content: string) => ({ type: "file", encoding: "base64", content: Buffer.from(content).toString("base64") });
const contents = (path: string, ref: string) => `${R}/contents/${path}?ref=${ref}`;
const pulls = `${R}/pulls?head=${encodeURIComponent(`ukyi-app:${BRANCH}`)}&state=open`;
const CLI_MSG = "feat(smoke): x\n\nHomelab-CLI: db add";

const CONTENT = "postgres:\n  enabled: true\n";
const spec = { command: "db add", app: "smoke", title: "feat(smoke): PostgreSQL 연결", body: "homelab db add smoke --apply", files: [PATH], edit: () => ({ [PATH]: CONTENT }) };

const mainAt = (sha = FAKE_SHA): Rule => ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha } });
const notOnMain = (): Rule => ghGet(contents(PATH, FAKE_SHA), 404, {});
const headMsg = (sha: string, message: string): Rule => ghGet(`${R}/git/commits/${sha}`, 200, { message, tree: { sha: "d".repeat(40) } });
const compare = (head: string, files: string[]): Rule => ghGet(`${R}/compare/${FAKE_SHA}...${head}`, 200, { files: files.map((filename) => ({ filename })) });
const openPr = (head: string, base = "main") => ghResponse(200, [{ number: 12, head: { sha: head }, base: { ref: base } }]);

// apply에서 공통으로 쓰는 쓰기 규칙.
const writes = (): Rule[] => [
  headMsg(FAKE_SHA, "main"),
  ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
  ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
];

describe("PR 작성기", () => {
  test("브랜치 이름은 cli/<동사>-<app>", () => {
    expect(branchName("db add", "smoke")).toBe(BRANCH);
    expect(branchName("app add", "memo")).toBe("cli/app-add-memo");
  });

  test("main과 같으면 same(PR 필요 없음)", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), ghGet(contents(PATH, FAKE_SHA), 200, file(CONTENT)), ghGet(pulls, 200, [])]);
    expect((await prStep(spec).read(ctx)).state).toBe("same");
    expectPlanReadOnly(calls());
  });

  test("main과 다르고 열린 PR이 없으면 missing/create", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), notOnMain(), ghGet(pulls, 200, [])]);
    const o = await prStep(spec).read(ctx);
    expect([o.state, o.action]).toEqual(["missing", "create"]);
    expectPlanReadOnly(calls());
  });

  test("열린 PR: CLI 머리 + 이 명령 파일만 + 내용 같음이면 same + 병합 대기", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), notOnMain(), ghGet(pulls, [openPr(HEAD)]), headMsg(HEAD, CLI_MSG), compare(HEAD, [PATH]), ghGet(contents(PATH, HEAD), 200, file(CONTENT))]);
    const o = await prStep(spec).read(ctx);
    expect([o.state, o.wait]).toEqual(["same", "PR #12 검토·병합 대기"]);
    expectPlanReadOnly(calls());
  });

  test("열린 PR에 이 명령 밖 파일이 있으면 내용이 같아도 differs(Connector 리뷰)", async () => {
    const { ctx } = testCtx("plan", [mainAt(), notOnMain(), ghGet(pulls, [openPr(HEAD)]), headMsg(HEAD, CLI_MSG), compare(HEAD, [PATH, "apps/smoke/values.yaml"]), ghGet(contents(PATH, HEAD), 200, file(CONTENT))]);
    const o = await prStep(spec).read(ctx);
    expect([o.state, o.action]).toEqual(["differs", "update"]);
    expect(o.detail).toContain("이 명령 밖 파일 1개");
  });

  test("열린 PR 머리가 사람 커밋이면 내용이 같아도 plan이 실패한다(같다고 보고하지 않는다)", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), notOnMain(), ghGet(pulls, [openPr(HEAD)]), headMsg(HEAD, "사람이 고친 커밋"), compare(HEAD, [PATH]), ghGet(contents(PATH, HEAD), 200, file(CONTENT))]);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("트레일러");
    expectPlanReadOnly(calls());
  });

  test("apply 새로: ref 없음 → tree(내용 직접) → commit(부모 main 하나, 트레일러) → ref 생성 → PR 생성 → waiting", async () => {
    const rules: Rule[] = [
      mainAt(),
      notOnMain(),
      // 전체 읽기·직전 읽기·apply 안 PR 찾기는 없음, 재조회는 PR 7(머리 NEW_COMMIT).
      ghGet(pulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), ghResponse(200, [{ number: 7, head: { sha: NEW_COMMIT }, base: { ref: "main" } }])]),
      headMsg(NEW_COMMIT, "feat(smoke): PostgreSQL 연결\n\nHomelab-CLI: db add"),
      compare(NEW_COMMIT, [PATH]),
      ghGet(contents(PATH, NEW_COMMIT), 200, file(CONTENT)),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 404, {}),
      ...writes(),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, 201, { number: 7 }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect([r.status, r.steps[0].result]).toEqual(["waiting", "waiting"]);
    const c = calls();
    expect(c.unmatched).toEqual([]);
    const sent = c.calls.filter((x) => x.stdin !== undefined).map((x) => JSON.parse(x.stdin!));
    expect(sent[0]).toEqual({ base_tree: "d".repeat(40), tree: [{ path: PATH, mode: "100644", type: "blob", content: CONTENT }] });
    expect(sent[1].parents).toEqual([FAKE_SHA]);
    expect(sent[1].message).toEndWith("\n\nHomelab-CLI: db add");
    expect(sent[2]).toEqual({ ref: `refs/heads/${BRANCH}`, sha: NEW_COMMIT });
    expect(sent[3]).toMatchObject({ head: BRANCH, base: "main" });
  });

  test("갱신은 force 없이 부모 [main, 확인한 머리]로 fast-forward, 열린 PR을 갱신", async () => {
    const rules: Rule[] = [
      mainAt(),
      notOnMain(),
      ghGet(pulls, [openPr(HEAD), openPr(HEAD), openPr(HEAD), openPr(NEW_COMMIT)]),
      headMsg(HEAD, CLI_MSG),
      headMsg(NEW_COMMIT, CLI_MSG),
      compare(HEAD, [PATH]),
      compare(NEW_COMMIT, [PATH]),
      ghGet(contents(PATH, HEAD), 200, file("old\n")),
      ghGet(contents(PATH, NEW_COMMIT), 200, file(CONTENT)),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: HEAD } }),
      ...writes(),
      ghSend("PATCH", `${R}/git/refs/heads/${BRANCH}`, 200, {}),
      ghSend("PATCH", `${R}/pulls/12`, 200, {}),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("waiting");
    const bodies = calls().calls.filter((x) => x.stdin !== undefined).map((x) => [x.argv[5], JSON.parse(x.stdin!)] as const);
    expect(bodies.find(([p]) => p === `${R}/git/commits`)![1].parents).toEqual([FAKE_SHA, HEAD]);
    expect(bodies.find(([p]) => p === `${R}/git/refs/heads/${BRANCH}`)![1]).toEqual({ sha: NEW_COMMIT, force: false });
  });

  test("확인 뒤 사람이 push하면(GitHub 422 fast forward 아님) 덮지 않고 실패한다(P1 경쟁 주입)", async () => {
    const rules: Rule[] = [
      mainAt(),
      notOnMain(),
      ghGet(pulls, [openPr(HEAD)]),
      headMsg(HEAD, CLI_MSG),
      compare(HEAD, [PATH]),
      ghGet(contents(PATH, HEAD), 200, file("old\n")),
      ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: HEAD } }),
      ...writes(),
      // 확인과 PATCH 사이에 머리가 H로 바뀐 상황: 새 커밋은 H의 자손이 아니라 GitHub가 거부한다.
      ghSend("PATCH", `${R}/git/refs/heads/${BRANCH}`, 422, { message: "Update is not a fast forward" }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("덮지 않았다");
    const c = calls().calls;
    expect(c.some((x) => x.argv.includes(`${R}/pulls/12`))).toBe(false);
    for (const x of c.filter((y) => y.stdin !== undefined)) expect(JSON.parse(x.stdin!).force).not.toBe(true);
  });

  test("브랜치 머리가 사람 커밋이면(트레일러 없음) 커밋을 만들기 전에 실패", async () => {
    const rules: Rule[] = [mainAt(), notOnMain(), ghGet(pulls, 200, []), ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: HEAD } }), headMsg(FAKE_SHA, "main"), headMsg(HEAD, "사람이 고친 커밋")];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("트레일러");
    expect(calls().writes).toEqual([]);
  });

  test("만들려는 브랜치가 그사이 생기면(422) 덮지 않고 실패", async () => {
    const rules: Rule[] = [mainAt(), notOnMain(), ghGet(pulls, 200, []), ghGet(`${R}/git/ref/heads/${BRANCH}`, 404, {}), ...writes(), ghSend("POST", `${R}/git/refs`, 422, { message: "Reference already exists" })];
    const { ctx } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("덮지 않았다");
  });

  test("apply 직전 main이 바뀌면 그 스냅샷에서 다시 계산해 동시 변경을 되돌리지 않는다(2라운드 P2 주입)", async () => {
    const LIST = "infra/github/app-repos.json";
    const B = "f".repeat(40);
    const addBeta = { command: "app new", app: "beta", title: "feat(beta): 앱 목록", body: "b", files: [LIST], edit: (cur: Record<string, string | null>) => ({ [LIST]: JSON.stringify([...JSON.parse(cur[LIST] ?? "[]"), "beta"]) }) };
    const lpulls = `${R}/pulls?head=${encodeURIComponent("ukyi-app:cli/app-new-beta")}&state=open`;
    const rules: Rule[] = [
      // 전체 읽기·직전 읽기는 main A, apply 안은 main B(그사이 alpha가 병합됨), 재조회는 B.
      ghGet(`${R}/git/ref/heads/main`, [ghResponse(200, { object: { sha: FAKE_SHA } }), ghResponse(200, { object: { sha: FAKE_SHA } }), ghResponse(200, { object: { sha: B } })]),
      ghGet(contents(LIST, FAKE_SHA), 200, file('["existing"]')),
      ghGet(contents(LIST, B), 200, file('["existing","alpha"]')),
      ghGet(lpulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), ghResponse(200, [{ number: 9, head: { sha: NEW_COMMIT }, base: { ref: "main" } }])]),
      headMsg(B, "main"),
      headMsg(NEW_COMMIT, "x\n\nHomelab-CLI: app new"),
      ghGet(`${R}/compare/${B}...${NEW_COMMIT}`, 200, { files: [{ filename: LIST }] }),
      ghGet(contents(LIST, NEW_COMMIT), 200, file('["existing","alpha","beta"]')),
      ghGet(`${R}/git/ref/heads/cli/app-new-beta`, 404, {}),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, 201, { number: 9 }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const r = await ctx.engine({ command: "app new", app: "beta", steps: [prStep(addBeta)] });
    expect(r.status).toBe("waiting");
    const bodies = calls().calls.filter((x) => x.stdin !== undefined).map((x) => JSON.parse(x.stdin!));
    expect(bodies[0]).toEqual({ base_tree: "d".repeat(40), tree: [{ path: LIST, mode: "100644", type: "blob", content: '["existing","alpha","beta"]' }] });
    expect(bodies[1].parents).toEqual([B]);
  });

  test("main에 이미 반영됐어도 열린 PR부터 본다: 밖 파일이 있으면 plan 실패, 없으면 same + 닫기 안내(Connector 2라운드)", async () => {
    const base = [mainAt(), ghGet(contents(PATH, FAKE_SHA), 200, file(CONTENT)), ghGet(pulls, [openPr(HEAD)]), headMsg(HEAD, CLI_MSG)];
    const extra = testCtx("plan", [...base, compare(HEAD, [PATH, "apps/smoke/values.yaml"])]);
    const r1 = await extra.ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r1.status).toBe("failed");
    expect(r1.error?.message).toContain("이 명령 밖 파일");
    const clean = testCtx("plan", [...base, compare(HEAD, [PATH])]);
    const r2 = await clean.ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r2.status).toBe("same");
    expect(r2.notes.join(" ")).toContain("gh pr close 12");
    expectPlanReadOnly(clean.calls());
  });

  test("열린 PR의 base가 main이 아니면 같다고 보지 않고 실패(Connector 3라운드)", async () => {
    const { ctx, calls } = testCtx("plan", [mainAt(), notOnMain(), ghGet(pulls, [openPr(HEAD, "release")])]);
    const r = await ctx.engine({ command: "db add", app: "smoke", steps: [prStep(spec)] });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toContain("base가 main이 아니다");
    expectPlanReadOnly(calls());
  });

  test("변경 검증: 경로·중복·빈 목록·edit 결과 키", async () => {
    expect(() => prStep({ ...spec, files: ["../x"] })).toThrow();
    expect(() => prStep({ ...spec, files: ["a\nb"] })).toThrow();
    expect(() => prStep({ ...spec, files: [PATH, PATH] })).toThrow();
    expect(() => prStep({ ...spec, files: [] })).toThrow();
    const { ctx } = testCtx("plan", [mainAt(), notOnMain()]);
    await expect(prStep({ ...spec, edit: () => ({ "other.yaml": "x" }) }).read(ctx)).rejects.toThrow("files의 파일마다");
  });
});
