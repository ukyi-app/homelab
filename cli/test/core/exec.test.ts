// exec seam 안전 계약 시험(#873 1라운드). 각 계약마다 어기는 호출을 주입해 막히는지, 스텁 원장에 실제 호출이 없는지 본다.
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { PLAN_WRITE_BLOCKED, runWithWrites } from "../../src/core/exec";
import { Secret } from "../../src/core/secret";
import { REST, rule, sha256, stubSandbox, testCtx } from "../harness";

describe("쓰기 창(P1: read는 apply 모드에서도 읽기 전용)", () => {
  test("plan·read에서 쓰기 argv는 실행하지 않는다. 창을 열어도 마찬가지", async () => {
    for (const mode of ["plan", "read"] as const) {
      const { ctx, calls } = testCtx(mode, [rule(["gh", REST])]);
      expect(() => ctx.exec(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
      await expect(runWithWrites(async () => ctx.exec(["kubectl", "delete", "pod", "x"]))).rejects.toThrow(PLAN_WRITE_BLOCKED);
      expect(calls().calls).toEqual([]);
    }
  });

  test("apply 모드라도 창 밖 쓰기는 막고, 창 안에서만 스텁에 닿는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["gh", REST])]);
    expect(() => ctx.exec(["gh", "pr", "create"])).toThrow("Step.apply 밖");
    expect(calls().calls).toEqual([]);
    await runWithWrites(async () => expect(ctx.exec(["gh", "pr", "create"]).code).toBe(0));
    expect(calls().writes.length).toBe(1);
  });

  test("창 안에서 붙잡아 둔 exec를 창이 닫힌 뒤 써도 막힌다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["gh", REST])]);
    let stash: typeof ctx.exec | undefined;
    await runWithWrites(async () => {
      stash = ctx.exec;
    });
    expect(() => stash!(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(calls().calls).toEqual([]);
  });

  test("github apply(delegate)는 창 안에서도 래퍼 밖 쓰기를 막는다", async () => {
    const { ctx } = testCtx("apply", [rule(["tf-github.sh", REST]), rule(["gh", REST])], { delegate: true });
    await runWithWrites(async () => {
      expect(ctx.exec(["tf-github.sh", "apply"]).code).toBe(0);
      expect(() => ctx.exec(["gh", "pr", "create"])).toThrow("래퍼 밖");
    });
  });
});

describe("직접 stdio(P1: 출력 계층 우회 금지)", () => {
  test("일반 명령은 inherit·stdout-to-stderr를 쓸 수 없다", () => {
    const { ctx, calls } = testCtx("read", [rule(["gh", REST])]);
    expect(() => ctx.exec(["gh", "pr", "list"], { stdio: "inherit" })).toThrow("github 위임 명령만");
    expect(() => ctx.exec(["gh", "pr", "list"], { stdio: "stdout-to-stderr" })).toThrow("github 위임 명령만");
    expect(calls().calls).toEqual([]);
  });

  test("위임 명령도 직접 stdio에 시크릿 입출력을 섞지 못한다", () => {
    const { ctx } = testCtx("read", [rule(["gh", REST])], { delegate: true });
    expect(() => ctx.exec(["gh", "auth", "token"], { stdio: "inherit", secretStdout: true })).toThrow("시크릿 입출력");
    expect(() => ctx.exec(["gh", "pr", "list"], { stdio: "inherit", input: new Secret("fakevalue-stdio-01") })).toThrow("시크릿 입출력");
  });

  test("위임 stdout-to-stderr는 부모 stdin을 래퍼에 넘기고 stdout을 지킨다(P2)", async () => {
    const sb = stubSandbox([rule(["tf-github.sh", "apply"], { stdout: "WRAPPER-OUT\n" })]);
    const p = Bun.spawn([process.execPath, "--no-env-file", join(import.meta.dir, "..", "fixtures", "core", "delegate-child.ts")], { env: sb.env, stdin: new TextEncoder().encode("yes\n"), stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    const c = sb.calls().calls;
    expect(c.length).toBe(1);
    expect(c[0].stdinSha256).toBe(sha256("yes\n"));
    expect(stdout).toBe('{"code":0}\n');
    expect(stderr).toContain("WRAPPER-OUT");
  });
});

describe("값을 내는 호출(P1: secretStdout 강제, stderr 원문 금지)", () => {
  test("Secret 조회·Infisical 목록·토큰은 secretStdout 없이 실행하지 않는다", () => {
    const { ctx, calls } = testCtx("read", [rule(["kubectl", REST]), rule(["infisical", REST]), rule(["gh", REST])]);
    for (const argv of [["kubectl", "get", "secret", "x", "-o", "json"], ["kubectl", "get", "secrets.v1", "x"], ["infisical", "secrets", "--path", "/apps/x"], ["gh", "auth", "token"]]) {
      expect(() => ctx.exec(argv)).toThrow("secretStdout");
    }
    expect(calls().calls).toEqual([]);
    expect(ctx.exec(["gh", "auth", "token"], { secretStdout: true }).stdout).toBe("");
  });

  test("짧은 시크릿(5자)도 argv에 실리면 막고, 민감 호출의 stderr 원문은 버린다", async () => {
    const short = new Secret("ab3de");
    const { ctx, calls } = testCtx("apply", [rule(["infisical", REST], { code: 1, stderr: "error: bad value ab3de for key\n" })]);
    expect(() => ctx.exec(["infisical", "secrets", "set", "K=ab3de"])).toThrow("명령행 인자");
    const r = await runWithWrites(async () => ctx.exec(["infisical", "secrets", "set", "--file", "/dev/stdin"], { input: short }));
    expect(r.stderr).toBe("");
    expect(r.stderrHidden).toBe(true);
    expect(calls().calls.length).toBe(1);
  });
});

describe("기타", () => {
  test("시크릿 원문은 stdin으로만, 원장에는 sha256만", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["infisical", REST])]);
    await runWithWrites(async () => ctx.exec(["infisical", "secrets", "set", "--file", "/dev/stdin"], { input: new Secret("fakevalue-exec-0001") }));
    const c = calls().calls;
    expect(c[0].stdinSha256).toBe(sha256("fakevalue-exec-0001"));
    expect(JSON.stringify(c)).not.toContain("fakevalue-exec-0001");
  });

  test("없는 명령은 not-found, 시간 초과는 timeout(재시도 없음)", () => {
    const { ctx, calls } = testCtx("read", [rule(["gh", REST], { sleepMs: 5000 })], { env: { HOMELAB_TEST_TIMEOUT_MS: "300" } });
    const { ctx: bare } = testCtx("read", [], { tools: [] });
    expect(bare.exec(["kubectl", "get", "x"]).errKind).toBe("not-found");
    expect(ctx.exec(["gh", "pr", "list"]).errKind).toBe("timeout");
    expect(calls().calls.filter((c) => c.argv[0] === "gh").length).toBe(1);
  });

  test("git에는 GIT_DIR 등을 넘기지 않는다. 절대 경로로 불러도 같다(Connector 리뷰)", () => {
    const names = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_TERMINAL_PROMPT"];
    const env = { GIT_DIR: "/elsewhere/.git", GIT_WORK_TREE: "/elsewhere", GIT_INDEX_FILE: "/x" };
    const { ctx, bin } = testCtx("read", [rule(["git", REST], { echoEnv: names }), rule(["gh", REST], { echoEnv: names })], { env });
    const scrubbed = { GIT_DIR: null, GIT_WORK_TREE: null, GIT_INDEX_FILE: null, GIT_TERMINAL_PROMPT: "0" };
    expect(JSON.parse(ctx.exec(["git", "rev-parse", "HEAD"]).stdout)).toEqual(scrubbed);
    expect(JSON.parse(ctx.exec([join(bin, "git"), "rev-parse", "HEAD"]).stdout)).toEqual(scrubbed);
    // 대조군: git이 아닌 도구에는 그대로 간다.
    expect(JSON.parse(ctx.exec(["gh", "pr", "list"]).stdout).GIT_DIR).toBe("/elsewhere/.git");
  });
});
