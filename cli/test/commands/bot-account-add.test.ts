import { describe, expect, test } from "bun:test";
import { argvFor as infArgv } from "../../src/core/infisical";
import { FAKE_PROJECT, expectNoSecrets, expectPlanReadOnly, infisicalList, infisicalSet, rule, runCli, type Rule } from "../harness";
import { folderJson } from "../fixtures/app-add-world/world";
import { CHAT, FOLDER, TASK, adminArgv, execCalls, pod, pods, report } from "../fixtures/bot-account";

// homelab bot account add(봇 COLLEAGUE_SPEC §4.8 "계정 등록", AC-21). 경계 S3: 실제 프로세스 + PATH 스텁(가짜 infisical·kubectl).
// 시험은 파이프 입력 경로(stdin 두 줄)를 본다. tty의 `claude setup-token` 실제 동작은 시험하지 않는다(브라우저 로그인·실토큰).
describe("bot account add", () => {
  // 폴더 /bot-accounts/main은 있고 키는 없다. 레인마다 valueHash가 목록을 한 번 읽는다(전체 읽기 2, apply 전 읽기 2, 실행 뒤 2).
  const world = (after: Record<string, string>): Rule[] => [
    rule(infArgv.folders(FAKE_PROJECT, "/bot-accounts"), { stdout: folderJson("/bot-accounts", ["main"]) }),
    infisicalList(FOLDER, [{ stdout: "null" }, { stdout: "null" }, { stdout: "null" }, { stdout: "null" }, { stdout: JSON.stringify(Object.entries(after).map(([secretKey, secretValue]) => ({ secretKey, secretValue }))) }]),
    { ...infisicalSet(FOLDER), captureStdin: true },
    pods(pod()),
    rule(adminArgv("account", "record", "main", "subscription"), { stdout: report("account record", "recorded") }),
  ];
  const BOTH = { CLAUDE_CODE_OAUTH_TOKEN: CHAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: TASK };

  test("plan: stdin을 읽지 않고 쓰기·exec 0건", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--json"], world(BOTH), { stdin: `${CHAT}\n${TASK}\n` });
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(execCalls(r)).toEqual([]);
    expect(r.json.steps.map((s: any) => s.state)).toEqual(["missing", "differs"]);
  });

  test("apply: 두 레인 토큰은 stdin → Infisical 요청 본문으로만 가고 argv·출력에 없으며, 봇 DB에 계정을 기록한다", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--apply", "--json"], world(BOTH), { stdin: `${CHAT}\n${TASK}\n` });
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("done");
    const sets = r.calls.filter((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, FOLDER).join(" "));
    expect(sets.map((c) => c.stdin)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${CHAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${TASK}\n`]);
    expectNoSecrets({ ...r, calls: r.calls.filter((c) => !sets.includes(c)) });
    expect(execCalls(r)).toEqual([adminArgv("account", "record", "main", "subscription")]);
    expect(r.json.next).toBe("봇이 이 계정을 쓰게 하려면: homelab bot account use main");
  });

  test("같은 토큰을 두 레인에 넣거나 줄 수가 레인 수와 다르면 아무것도 쓰지 않고 실패한다", async () => {
    for (const stdin of [`${CHAT}\n${CHAT}\n`, `${CHAT}\n`, `${CHAT}\n${TASK}\n${CHAT}\n`, `${CHAT}\nshort\n`]) {
      const r = await runCli(["bot", "account", "add", "main", "--apply", "--json"], world(BOTH), { stdin });
      expect([stdin.length, r.code]).toEqual([stdin.length, 1]);
      expect(r.writes).toEqual([]);
      expectNoSecrets(r);
    }
  });

  test("계정 이름은 소문자·숫자·하이픈 32자 이하만 받는다(Infisical 경로·지표 라벨)", async () => {
    for (const name of ["Main", "-main", "main-", "a".repeat(33), "../x", "main/x"]) {
      const r = await runCli(["bot", "account", "add", name, "--json"], []);
      expect([name, r.code]).toEqual([name, 64]);
      expect(r.calls).toEqual([]);
    }
  });
});
