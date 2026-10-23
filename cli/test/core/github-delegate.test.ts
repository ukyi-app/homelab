// github 위임 어댑터 시험. 04가 github plan·apply·verify를 이 어댑터로 구현한다.
// 스텁 git clone이 목적지에 tools/tf-github.sh 스텁을 만들고(materialize), 그 래퍼 스텁이 종료 코드를 낸다.
import { describe, expect, test } from "bun:test";
import { HOMELAB_URL } from "../../src/core/github";
import { REST, rule, testCtx } from "../harness";

const clone = (code = 0) => rule(["git", REST], { code, materialize: { "tools/tf-github.sh": "stub" } });

describe("github 위임", () => {
  test("plan: main을 core 임시 폴더로 clone(hook·전역 설정 끊음)하고 래퍼 종료 코드를 그대로 돌려준다", () => {
    const { ctx, calls } = testCtx("read", [clone(), rule(["tf-github.sh", "plan"], { code: 2 }, { noStdin: true })], { delegate: true, env: { GIT_DIR: "/elsewhere" } });
    expect(ctx.github!.run("plan")).toBe(2);
    const c = calls().calls;
    expect(c.map((x) => x.argv[0])).toEqual(["git", "tf-github.sh"]);
    const g = c[0].argv;
    expect(g).toContain("clone");
    expect(g).toContain(HOMELAB_URL);
    expect(g.some((a) => a.startsWith("core.hooksPath="))).toBe(true);
    expect(g.at(-1)).toMatch(/homelab-cli-github-[^/]+\/tree$/);
    expect(calls().writes).toEqual([]);
  });

  test("read 모드(plan·verify)에서 apply는 실행하지 않는다(래퍼 호출 0건)", () => {
    const { ctx, calls } = testCtx("read", [clone(), rule(["tf-github.sh", REST])], { delegate: true });
    expect(() => ctx.github!.run("apply")).toThrow("apply 문맥");
    expect(calls().calls.filter((x) => x.argv[0] === "tf-github.sh")).toEqual([]);
  });

  test("apply 모드에서는 래퍼 apply가 쓰기로 실행되고 --allow-destroy를 넘긴다", () => {
    const { ctx, calls } = testCtx("apply", [clone(), rule(["tf-github.sh", REST], { code: 0 }, { noStdin: true })], { delegate: true });
    expect(ctx.github!.run("apply", { allowDestroy: true })).toBe(0);
    const w = calls().calls.find((x) => x.argv[0] === "tf-github.sh")!;
    expect(w.argv.slice(1)).toEqual(["apply", "--allow-destroy"]);
  });

  test("clone 실패면 래퍼를 부르지 않고 실패", () => {
    const { ctx, calls } = testCtx("read", [clone(128), rule(["tf-github.sh", REST])], { delegate: true });
    expect(() => ctx.github!.run("verify")).toThrow("clone하지 못했다");
    expect(calls().calls.filter((x) => x.argv[0] === "tf-github.sh")).toEqual([]);
  });

  test("위임이 아닌 명령에는 github 어댑터가 없다", () => {
    const { ctx } = testCtx("read", []);
    expect(ctx.github).toBeUndefined();
  });
});
