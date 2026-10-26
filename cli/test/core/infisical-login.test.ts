// T12-05 F9: Infisical 세션 만료·인증 거부를 정해진 낱말로만 분류해 next를 infisical login으로 둔다.
// 값이 실릴 수 있는 호출의 오류 원문은 그대로 버린다(메시지·출력에 원문이 없다).
import { describe, expect, test } from "bun:test";
import type { WriteCtx } from "../../src/core/command";
import { LOGIN_NEXT, argvFor } from "../../src/core/infisical";
import { CliError } from "../../src/core/result";
import { Secret } from "../../src/core/secret";
import { FAKE_PROJECT, FAKE_SECRETS, applyWith, expectNoSecrets, infisicalList, infisicalSet, kubectlRule, rule, runCli, testCtx, type Resp } from "../harness";
import { folders, homelab } from "../fixtures/app-add-world/world";

// 0.44.2 바이너리의 문구(infisical.ts 주석). 원문이 새면 잡히도록 가짜 시크릿을 함께 싣는다.
const PHRASES = [
  "Your login session has expired. Please run [infisical login]",
  "You must be logged in to run this command. To login, run [infisical login]",
  "we couldn't find your logged in details, try running [infisical login] then try again",
  "CallGetAllSecretsV3: Unsuccessful response [GET https://app.infisical.com/api/v3/secrets/raw] [status-code=401] [request-id=x]",
  'error: {"statusCode":401,"message":"Token expired","error":"Unauthorized"}',
];
const fail = (stderr: string): Resp => ({ code: 1, stderr: `${stderr}\n${FAKE_SECRETS[0]}\n` });

function caught(fn: () => unknown): Error {
  try {
    fn();
  } catch (e) {
    return e as Error;
  }
  throw new Error("던지지 않았다");
}

describe("Infisical 로그인 만료 분류(T12-05 F9)", () => {
  test("목록(값이 실릴 수 있는 호출): 정해진 낱말이면 CliError + infisical login, 메시지에 원문 없음", () => {
    for (const phrase of PHRASES) {
      const { ctx } = testCtx("plan", [infisicalList("/apps/memo", [fail(phrase)])]);
      const e = caught(() => ctx.infisical.listKeys("/apps/memo"));
      expect(e).toBeInstanceOf(CliError);
      expect((e as CliError).next).toBe(LOGIN_NEXT);
      expect(e.message).toBe("Infisical /apps/memo 목록: Infisical 로그인이 만료됐거나 거부됐다");
    }
  });

  test("다른 실패는 지금처럼 원문을 버린 일반 오류다(로그인으로 오분류하지 않는다)", () => {
    const { ctx } = testCtx("plan", [infisicalList("/apps/memo", [fail("error: Forbidden: project access denied [status-code=403]")])]);
    const e = caught(() => ctx.infisical.listKeys("/apps/memo"));
    expect(e).not.toBeInstanceOf(CliError);
    expect(e.message).toBe("Infisical /apps/memo 목록: exit 1(값이 실릴 수 있는 호출이라 오류 원문을 버렸다)");
  });

  test("성공한 목록의 값에 그 낱말이 있어도 판정하지 않는다(실패일 때만 본다)", () => {
    const { ctx } = testCtx("plan", [infisicalList("/apps/memo", { NOTE: "Unauthorized [infisical login] status-code=401" })]);
    expect(ctx.infisical.listKeys("/apps/memo")).toEqual(["NOTE"]);
  });

  test("폴더 목록·쓰기·폴더 만들기·삭제도 같은 분류", async () => {
    const expired = fail(PHRASES[0]);
    const read = testCtx("plan", [rule(argvFor.folders(FAKE_PROJECT, "/apps"), expired)]);
    const e = caught(() => read.ctx.infisical.folderExists("/apps/memo"));
    expect([e instanceof CliError, (e as CliError).next]).toEqual([true, LOGIN_NEXT]);

    const writes: [string, (w: WriteCtx) => unknown][] = [
      ["쓰기", (w) => w.infisical.setValue("/apps/memo", "API_TOKEN", new Secret(FAKE_SECRETS[1]))],
      ["폴더 만들기", (w) => w.infisical.createFolder("/apps/memo")],
      ["삭제", (w) => w.infisical.removeKey("/apps/memo", "API_TOKEN")],
    ];
    for (const [what, fn] of writes) {
      const { ctx } = testCtx("apply", [
        infisicalSet("/apps/memo", expired),
        rule(argvFor.folders(FAKE_PROJECT, "/"), { stdout: JSON.stringify([{ folderId: "f", folderName: "apps", folderPath: "/apps" }]) }),
        rule(argvFor.folders(FAKE_PROJECT, "/apps"), { stdout: "null" }),
        rule(argvFor.createFolder(FAKE_PROJECT, "/apps", "memo"), expired),
        rule(argvFor.remove(FAKE_PROJECT, "/apps/memo", "API_TOKEN"), expired),
      ]);
      const err = await applyWith(ctx, fn).then(
        () => null,
        (x: Error) => x,
      );
      expect([what, err instanceof CliError, (err as CliError).next, err!.message.includes(FAKE_SECRETS[0])]).toEqual([what, true, LOGIN_NEXT, false]);
    }
  });

  test("명령 끝까지: secret sync가 '읽지 못함'에 더해 next로 infisical login을 안내하고 원문을 내지 않는다", async () => {
    const values = "chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nsecrets: [API_TOKEN]\n";
    const notFound = { code: 1, stderr: 'Error from server (NotFound): x "y" not found\n' };
    const rules = [
      ...homelab({ "apps/memo/values.yaml": values }),
      ...folders({ "/apps": ["memo"] }),
      infisicalList("/apps/memo", [fail(PHRASES[0])]),
      kubectlRule(["-n", "app-memo", "get", "externalsecrets.external-secrets.io", "memo-app", "-o", "json"], notFound),
    ];
    for (const args of [["secret", "sync", "memo", "--json"], ["secret", "sync", "memo"]]) {
      const r = await runCli(args, rules);
      expect(r.code).toBe(1);
      expectNoSecrets(r);
      if (r.json) {
        expect(r.json.steps.find((s: any) => s.id === "infisical-keys").detail).toBe("읽지 못함");
        expect(r.json.error.next).toBe(LOGIN_NEXT);
      } else {
        expect(r.stdout + r.stderr).toContain(`다음: ${LOGIN_NEXT}`);
        expect(r.stdout + r.stderr).not.toContain("session has expired");
      }
    }
  });
});
