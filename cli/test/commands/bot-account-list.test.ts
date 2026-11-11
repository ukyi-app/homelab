import { describe, expect, test } from "bun:test";
import { expectNoSecrets, expectPlanReadOnly, rule, runCli, runCliTty } from "../harness";
import { ACCOUNTS, adminArgv, execCalls, pod, pods, report } from "../fixtures/bot-account";

// homelab bot account list(봇 COLLEAGUE_SPEC §4.8 "계정 목록", AC-21). 경계 S3: 실제 프로세스 + 가짜 kubectl.
describe("bot account list", () => {
  test("plan: 실행하지 않고 대상 파드와 argv만 보인다", async () => {
    const r = await runCli(["bot", "account", "list", "--json"], [pods(pod())]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(execCalls(r)).toEqual([]);
    expect(r.json.steps[0].detail).toContain(adminArgv("account", "list").join(" "));
  });

  test("apply: 이름·방식·지금 계정·만료일·마지막 사용률·멈춘 작업 수를 보이고 값은 없다", async () => {
    const paused = { rate_limit: 0, auth_expired: 1, billing: 2 };
    const r = await runCli(["bot", "account", "list", "--apply", "--json"], [pods(pod()), rule(adminArgv("account", "list"), { stdout: report("account list", "accounts", { accounts: ACCOUNTS, paused }) })]);
    expect(r.code).toBe(0);
    expect(r.json.body).toBe([
      "지금 계정: main(구독)",
      "- main(구독, 지금 계정) · 토큰 만료 2027-11-11 09:00 KST · 사용률 97%(five_hour, allowed_warning) · 풀리는 시각 2026-11-11 14:00 KST · 관측 2026-11-11 12:00 KST",
      "- spare(구독) · 토큰 만료 모름(CLI 밖에서 등록) · 사용률 관측 없음",
      "모델 멈춤 작업: 한도 0 · 인증 만료 1 · 결제 2",
      "결제 멈춤은 원인을 푼 뒤 homelab bot account use <이름> --apply로 해제한다(지금 계정이면 main)",
    ].join("\n"));
  });

  test("터미널 요약: 목록만 몇 줄(지금 계정이 머리) 보이고 단계 표·kubectl 줄은 없다. --verbose면 단계 표도", async () => {
    const paused = { rate_limit: 0, auth_expired: 0, billing: 0 };
    const world = [pods(pod()), rule(adminArgv("account", "list"), { stdout: report("account list", "accounts", { accounts: ACCOUNTS, paused }) })];
    const r = await runCliTty(["bot", "account", "list", "--apply"], world);
    expect(r.code).toBe(0);
    expect(r.screen).toContain("◆  지금 계정: main(구독)\r\n│  - main(구독, 지금 계정) · 토큰 만료 2027-11-11 09:00 KST");
    expect(r.screen).toContain("│  모델 멈춤 작업: 한도 0 · 인증 만료 0 · 결제 0\r\n");
    for (const noise of ["kubectl", "admin-main.js", "실행\r\n", "다음: 없음"]) expect([noise, r.screen.includes(noise)]).toEqual([noise, false]);
    const v = await runCliTty(["bot", "account", "list", "--apply", "--verbose"], world);
    expect(v.screen).toContain("  1 봇 모델 계정 목록");
    expect(v.screen).toContain("admin-main.js account list");
  }, 30_000);

  test("터미널 요약(실패): 봇이 목록을 내지 않으면 실패한 단계 이름과 다음 행동이 보인다", async () => {
    const r = await runCliTty(["bot", "account", "list", "--apply"], [pods(pod()), rule(adminArgv("account", "list"), { stdout: report("account list", "usage"), code: 64 })]);
    expect(r.code).toBe(1);
    expect(r.screen).toContain("■  실패: 봇 계정 목록 읽기\r\n│  봇이 목록을 내지 않았다: usage");
    expect(r.screen).toContain("└  다음: 지금 봇 이미지의 관리 진입점이 계정 명령을 받지 않는다");
  }, 30_000);

  test("봇 출력에 정해진 꼴 밖의 칸이 있으면(값처럼 보이는 문자열) 옮기지 않고 실패한다", async () => {
    // 토큰처럼 대문자·밑줄이 섞인 문자열. 계정 이름·상태 이름 규칙을 통과하지 못한다.
    const LEAK = "fakevalue-Leak_Token_0000";
    const none = { rate_limit: 0, auth_expired: 0, billing: 0 };
    const bad: object[] = [{ accounts: [{ ...ACCOUNTS[0], name: LEAK }], paused: none },
      { accounts: [{ ...ACCOUNTS[0], limit: { ...ACCOUNTS[0].limit, status: LEAK } }], paused: none },
      { accounts: [{ ...ACCOUNTS[0], issuedAt: LEAK }], paused: none },
      { accounts: ACCOUNTS, paused: { ...none, rate_limit: LEAK } }];
    for (const extra of bad) {
      const r = await runCli(["bot", "account", "list", "--apply", "--json"], [pods(pod()), rule(adminArgv("account", "list"), { stdout: report("account list", "accounts", extra) })]);
      expect(r.code).toBe(1);
      expectNoSecrets(r, [LEAK]);
    }
  });

  test("잘못된 파드·네임스페이스 대상이면 실행 전에 멈춘다(exec 0건)", async () => {
    for (const items of [[], [pod(), pod({ name: "homelab-bot-6f7c9d5b8-zzzzz" })], [pod({ namespace: "app-other" })], [pod({ app: "other" })]]) {
      const r = await runCli(["bot", "account", "list", "--apply", "--json"], [pods(...items), rule(adminArgv("account", "list"), { stdout: report("account list", "accounts", { accounts: [], paused: { rate_limit: 0, auth_expired: 0, billing: 0 } }) })]);
      expect(r.code).toBe(1);
      expect(execCalls(r)).toEqual([]);
    }
  });
});
