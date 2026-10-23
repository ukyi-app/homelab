import { describe, expect, test } from "bun:test";
import { PLAN_WRITE_BLOCKED } from "../../src/core/exec";
import { Secret } from "../../src/core/secret";
import { REST, rule, sha256, testCtx } from "../harness";

describe("exec seam", () => {
  test("plan·read에서 쓰기 argv는 실행하지 않고 막는다(스텁 원장 0건)", () => {
    for (const mode of ["plan", "read"] as const) {
      const { ctx, calls } = testCtx(mode, [rule(["gh", REST])]);
      expect(() => ctx.exec(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
      expect(() => ctx.exec(["kubectl", "delete", "pod", "x"])).toThrow(PLAN_WRITE_BLOCKED);
      expect(calls().calls).toEqual([]);
    }
  });

  test("apply에서는 쓰기가 스텁에 닿고, 원장 판정이 쓰기로 센다", () => {
    const { ctx, calls } = testCtx("apply", [rule(["gh", REST])]);
    expect(ctx.exec(["gh", "pr", "create"]).code).toBe(0);
    expect(calls().writes.length).toBe(1);
  });

  test("github apply(delegate)는 래퍼 밖 쓰기를 막는다", () => {
    const { ctx } = testCtx("apply", [rule(["tf-github.sh", REST]), rule(["gh", REST])], { delegate: true });
    expect(ctx.exec(["tf-github.sh", "apply"]).code).toBe(0);
    expect(() => ctx.exec(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
  });

  test("시크릿 원문을 argv로 넘기면 실행하지 않는다. stdin으로는 넘긴다", () => {
    const { ctx, calls } = testCtx("apply", [rule(["infisical", REST])]);
    const s = new Secret("fakevalue-exec-0001");
    expect(() => ctx.exec(["infisical", "secrets", "set", `K=${s.reveal()}`])).toThrow("명령행 인자");
    ctx.exec(["infisical", "secrets", "set", "--file", "/dev/stdin"], { input: s });
    const c = calls().calls;
    expect(c.length).toBe(1);
    expect(c[0].stdinSha256).toBe(sha256("fakevalue-exec-0001"));
    expect(JSON.stringify(c)).not.toContain("fakevalue-exec-0001");
  });

  test("없는 명령은 not-found, 시간 초과는 timeout(재시도 없음)", () => {
    const { ctx, calls } = testCtx("read", [rule(["gh", REST], { sleepMs: 5000 })], { env: { HOMELAB_TEST_TIMEOUT_MS: "300" } });
    expect(ctx.exec(["kubectl", "get", "x"]).errKind).toBeUndefined();
    const { ctx: bare } = testCtx("read", [], { tools: [] });
    expect(bare.exec(["kubectl", "get", "x"]).errKind).toBe("not-found");
    expect(ctx.exec(["gh", "pr", "list"]).errKind).toBe("timeout");
    expect(calls().calls.filter((c) => c.argv[0] === "gh").length).toBe(1);
  });

  test("git에는 GIT_DIR·GIT_WORK_TREE·GIT_INDEX_FILE을 넘기지 않고 GIT_TERMINAL_PROMPT=0(hook 안 상속 함정)", () => {
    const names = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_TERMINAL_PROMPT"];
    const env = { GIT_DIR: "/elsewhere/.git", GIT_WORK_TREE: "/elsewhere", GIT_INDEX_FILE: "/x" };
    const { ctx } = testCtx("read", [rule(["git", REST], { echoEnv: names }), rule(["gh", REST], { echoEnv: names })], { env });
    expect(JSON.parse(ctx.exec(["git", "rev-parse", "HEAD"]).stdout)).toEqual({ GIT_DIR: null, GIT_WORK_TREE: null, GIT_INDEX_FILE: null, GIT_TERMINAL_PROMPT: "0" });
    // 대조군: git이 아닌 도구에는 그대로 간다.
    expect(JSON.parse(ctx.exec(["gh", "pr", "list"]).stdout).GIT_DIR).toBe("/elsewhere/.git");
  });
});
