import { afterEach, describe, expect, test } from "bun:test";
import { argvFor, getValue, has, listKeys, projectId, removeKey, resetProjectCache, setValue } from "../../src/core/infisical";
import { runWithWrites } from "../../src/core/exec";
import { render } from "../../src/core/output";
import { getJson, listJson, secretExists } from "../../src/core/kubectl";
import { prStep } from "../../src/core/pr";
import { ghSend } from "../../src/core/github";
import { kubectlArgv, secretHash } from "../../src/core/kubectl";
import { CliError } from "../../src/core/result";
import { Secret } from "../../src/core/secret";
import { FAKE_PROJECT, FAKE_SECRETS, REST, expectNoSecrets, expectPlanReadOnly, infisicalList, infisicalSet, kubectlRule, rule, sha256, testCtx } from "../harness";

afterEach(() => resetProjectCache());

describe("Infisical 어댑터", () => {
  test("존재는 폴더 목록으로 본다(`secrets get`의 *not found* 함정 회피). 값은 출력에 없다", () => {
    const { ctx, calls } = testCtx("plan", [infisicalList("/apps/smoke/postgres", { PASSWORD: FAKE_SECRETS[0] })]);
    expect(has(ctx, "/apps/smoke/postgres", "PASSWORD")).toBe(true);
    expect(has(ctx, "/apps/smoke/postgres", "OTHER")).toBe(false);
    expect([...listKeys(ctx, "/apps/smoke/postgres")]).toEqual(["PASSWORD"]);
    expect(String(getValue(ctx, "/apps/smoke/postgres", "PASSWORD"))).toBe("[secret]");
    expectPlanReadOnly(calls());
  });

  test("쓰기는 --file /dev/stdin에 KEY=값 한 줄, argv에 값이 없다", async () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke/postgres")]);
    await runWithWrites(async () => setValue(ctx, "/apps/smoke/postgres", "PASSWORD", new Secret(FAKE_SECRETS[1])));
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

describe("짧은 시크릿(P1: 길이와 관계없이 보호)", () => {
  test("5자 값의 쓰기 실패 오류에 값이 실려도 오류 메시지·출력에 없다", async () => {
    const short = "q7x2z";
    const { ctx } = testCtx("apply", [infisicalSet("/apps/smoke", { code: 1, stderr: `error: invalid value ${short}\n` })]);
    let message = "";
    await runWithWrites(async () => {
      try {
        setValue(ctx, "/apps/smoke", "PIN", new Secret(short));
      } catch (e) {
        message = (e as Error).message;
      }
    });
    expect(message).toContain("오류 원문을 버렸다");
    expect(message).not.toContain(short);
    const out = render({ command: "secret set", mode: "apply", status: "failed", steps: [], notes: [], next: null, error: { message, next: "x" } }, true);
    expect(out).not.toContain(short);
  });

  test("5자 값이 출력·PR 내용·요청 본문에 섞이면 막는다", () => {
    const short = "k9m3w";
    new Secret(short);
    expect(() => render({ command: "t", mode: "plan", status: "same", steps: [], notes: [`값 ${short}`], next: null }, false)).toThrow("시크릿");
    expect(() => prStep({ command: "db add", app: "smoke", title: "t", body: "b", changes: [{ path: "apps/smoke/values.yaml", content: `pin: ${short}\n` }] })).toThrow("시크릿");
    const { ctx, calls } = testCtx("apply", []);
    expect(() => ghSend(ctx, "POST", "repos/x/pulls", { body: `pin ${short}` })).toThrow("시크릿");
    expect(calls().calls).toEqual([]);
  });
});

describe("kubectl 어댑터", () => {
  test("범용 조회는 Secret을 거부한다(단건·목록·표기 변형, P1)", () => {
    const { ctx, calls } = testCtx("read", [rule(["kubectl", REST])]);
    for (const kind of ["secret", "secrets", "Secret", "secrets.v1", "secret.v1.", "pods,secrets"]) {
      expect(() => getJson(ctx, "app-smoke", kind, "x")).toThrow("Secret");
      expect(() => listJson(ctx, "app-smoke", kind)).toThrow("Secret");
    }
    expect(calls().calls).toEqual([]);
  });

  test("secretExists는 키 이름만, 값은 결과·원장에 없다", () => {
    const data = { data: { password: Buffer.from(FAKE_SECRETS[0]).toString("base64"), user: Buffer.from("smoke-user").toString("base64") } };
    const { ctx, calls } = testCtx("read", [kubectlRule(["-n", "database", "get", "secret", "pg-role-smoke", "-o", "json"], { stdout: JSON.stringify(data) })]);
    const r = secretExists(ctx, "database", "pg-role-smoke");
    expect(r).toEqual({ exists: true, keys: ["password", "user"] });
    expect(JSON.stringify(r)).not.toContain(FAKE_SECRETS[0]);
    expectPlanReadOnly(calls());
  });

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
