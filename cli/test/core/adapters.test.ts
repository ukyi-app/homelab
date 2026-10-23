import { afterEach, describe, expect, test } from "bun:test";
import { argvFor, has, listFolder, projectId, removeKey, resetProjectCache, setValue } from "../../src/core/infisical";
import { kubectlArgv, secretHash } from "../../src/core/kubectl";
import { CliError } from "../../src/core/result";
import { Secret } from "../../src/core/secret";
import { FAKE_PROJECT, FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, infisicalList, infisicalSet, kubectlRule, rule, sha256, testCtx } from "../harness";

afterEach(() => resetProjectCache());

describe("Infisical 어댑터", () => {
  test("존재는 폴더 목록으로 본다(`secrets get`의 *not found* 함정 회피). 값은 출력에 없다", () => {
    const { ctx, calls } = testCtx("plan", [infisicalList("/apps/smoke/postgres", { PASSWORD: FAKE_SECRETS[0] })]);
    expect(has(ctx, "/apps/smoke/postgres", "PASSWORD")).toBe(true);
    expect(has(ctx, "/apps/smoke/postgres", "OTHER")).toBe(false);
    expect(String(listFolder(ctx, "/apps/smoke/postgres").get("PASSWORD"))).toBe("[secret]");
    expectPlanReadOnly(calls());
  });

  test("쓰기는 --file /dev/stdin에 KEY=값 한 줄, argv에 값이 없다", () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke/postgres")]);
    setValue(ctx, "/apps/smoke/postgres", "PASSWORD", new Secret(FAKE_SECRETS[1]));
    const c = calls();
    expect(c.calls.length).toBe(1);
    expect(c.calls[0].argv).toEqual(argvFor.set(FAKE_PROJECT, "/apps/smoke/postgres"));
    expect(c.calls[0].stdinSha256).toBe(sha256(`PASSWORD=${FAKE_SECRETS[1]}\n`));
    expectNoSecrets(c);
  });

  test("줄바꿈이 낀 값·키·경로는 쓰기 전에 거부(다음 줄이 다른 키가 된다)", () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke")]);
    expect(() => setValue(ctx, "/apps/smoke", "TOKEN", new Secret("fakevalue\nOTHER=x"))).toThrow("줄바꿈");
    expect(() => setValue(ctx, "/apps/smoke", "TOKEN\nX", new Secret("fakevalue-ok-1"))).toThrow();
    expect(() => setValue(ctx, "/apps/smoke\n/x", "TOKEN", new Secret("fakevalue-ok-1"))).toThrow();
    expect(calls().calls).toEqual([]);
  });

  test("plan에서 쓰기·삭제는 exec가 막는다", () => {
    const { ctx, calls } = testCtx("plan", [infisicalSet("/apps/smoke"), rule(argvFor.remove(FAKE_PROJECT, "/apps/smoke", "TOKEN"))]);
    expect(() => setValue(ctx, "/apps/smoke", "TOKEN", new Secret("fakevalue-ok-2"))).toThrow("plan-write-blocked");
    expect(() => removeKey(ctx, "/apps/smoke", "TOKEN")).toThrow("plan-write-blocked");
    expect(calls().calls).toEqual([]);
  });

  test("프로젝트 ID: 환경변수 없고 tty 아니면 CliError + 다음 행동, 형식이 틀려도 실패", () => {
    const { ctx } = testCtx("plan", [], { project: false });
    expect(() => projectId(ctx)).toThrow(CliError);
    const bad = testCtx("plan", [], { env: { HOMELAB_INFISICAL_PROJECT_ID: "not-a-uuid" } });
    expect(() => projectId(bad.ctx)).toThrow("UUID");
    const asked = testCtx("plan", [], { project: false });
    asked.ctx.isTTY = true;
    asked.ctx.ask = () => FAKE_PROJECT;
    expect(projectId(asked.ctx)).toBe(FAKE_PROJECT);
  });
});

describe("kubectl 어댑터", () => {
  test("secretHash는 해시 앞 12자만, 값은 원장·결과에 없다", () => {
    const data = { data: { password: Buffer.from(FAKE_SECRETS[0]).toString("base64") } };
    const { ctx, calls } = testCtx("plan", [kubectlRule(["-n", "database", "get", "secret", "pg-role-smoke", "-o", "json"], { stdout: JSON.stringify(data) })]);
    const h = secretHash(ctx, "database", "pg-role-smoke", "password");
    expect(h).toBe(sha256(FAKE_SECRETS[0]).slice(0, 12));
    expectPlanReadOnly(calls());
  });

  test("모든 호출에 --request-timeout", () => {
    expect(kubectlArgv(["get", "pods"]).at(-1)).toBe("--request-timeout=20s");
  });
});
