import { describe, expect, test } from "bun:test";
import { argvFor as infArgv } from "../../src/core/infisical";
import { FAKE_PROJECT, expectNoSecrets, expectPlanReadOnly, infisicalList, infisicalSet, rule, runCli, runCliTty, type Rule } from "../harness";
import { folderJson } from "../fixtures/app-add-world/world";
import { API_CHAT, API_TASK, CHAT, FOLDER, OAT, OAT2, OAUTH_URL, TASK, adminArgv, execCalls, leaks, pod, pods, report, setupScreen } from "../fixtures/bot-account";

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

  test("apply(파이프): 토큰 한 줄을 대화용·작업용 두 자리에 쓴다. 값은 Infisical 요청 본문으로만 가고 argv·출력에 없으며, 봇 DB에 계정을 기록한다", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--apply", "--json"], world({ CLAUDE_CODE_OAUTH_TOKEN: CHAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: CHAT }), { stdin: `${CHAT}\n` });
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("done");
    const sets = r.calls.filter((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, FOLDER).join(" "));
    expect(sets.map((c) => c.stdin)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${CHAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${CHAT}\n`]);
    expectNoSecrets({ ...r, calls: r.calls.filter((c) => !sets.includes(c)) });
    expect(execCalls(r)).toEqual([adminArgv("account", "record", "main", "subscription")]);
    expect(r.json.next).toBe("봇이 이 계정을 쓰게 하려면: homelab bot account use main");
  });

  test("apply(파이프) --separate-tokens: 두 줄을 대화용·작업용에 따로 쓴다", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--separate-tokens", "--apply", "--json"], world(BOTH), { stdin: `${CHAT}\n${TASK}\n` });
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${CHAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${TASK}\n`]);
    expectNoSecrets({ ...r, calls: r.calls.filter((c) => c.stdin === undefined) });
  });

  test("줄 수가 맞지 않거나(기본 한 줄, --separate-tokens 두 줄) 따로 받기인데 두 값이 같거나 짧으면 아무것도 쓰지 않고 실패한다", async () => {
    const cases: [string[], string, string][] = [
      [[], `${CHAT}\n${TASK}\n`, "한 줄이어야"],
      [[], `${CHAT}\nshort\n`, "한 줄이어야"],
      [[], "short\n", "16자"],
      [["--separate-tokens"], `${CHAT}\n${CHAT}\n`, "--separate-tokens를 골랐는데 두 토큰이 같다"],
      [["--separate-tokens"], `${CHAT}\n`, "2줄이어야"],
      [["--separate-tokens"], `${CHAT}\n${TASK}\n${CHAT}\n`, "2줄이어야"],
      [["--separate-tokens"], `${CHAT}\nshort\n`, "작업용 토큰"],
    ];
    for (const [flags, stdin, message] of cases) {
      const r = await runCli(["bot", "account", "add", "main", ...flags, "--apply", "--json"], world(BOTH), { stdin });
      expect([stdin.length, r.code]).toEqual([stdin.length, 1]);
      expect(r.json.error.message).toContain(message);
      expect(r.writes).toEqual([]);
      expectNoSecrets(r);
    }
  });

  test("--replace(파이프): 이미 따로 받은 두 값이 있어도 한 줄로 다시 받아 두 자리를 같은 값으로 바꾼다", async () => {
    const rules: Rule[] = [
      rule(infArgv.folders(FAKE_PROJECT, "/bot-accounts"), { stdout: folderJson("/bot-accounts", ["main"]) }),
      infisicalList(FOLDER, [{ stdout: JSON.stringify([{ secretKey: "CLAUDE_CODE_OAUTH_TOKEN", secretValue: CHAT }, { secretKey: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secretValue: TASK }]) },
        { stdout: JSON.stringify([{ secretKey: "CLAUDE_CODE_OAUTH_TOKEN", secretValue: CHAT }, { secretKey: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secretValue: TASK }]) },
        { stdout: JSON.stringify([{ secretKey: "CLAUDE_CODE_OAUTH_TOKEN", secretValue: CHAT }, { secretKey: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secretValue: TASK }]) },
        { stdout: JSON.stringify([{ secretKey: "CLAUDE_CODE_OAUTH_TOKEN", secretValue: CHAT }, { secretKey: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secretValue: TASK }]) },
        { stdout: JSON.stringify([{ secretKey: "CLAUDE_CODE_OAUTH_TOKEN", secretValue: OAT }, { secretKey: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secretValue: OAT }]) }]),
      { ...infisicalSet(FOLDER), captureStdin: true },
      pods(pod()),
      rule(adminArgv("account", "record", "main", "subscription"), { stdout: report("account record", "recorded") }),
    ];
    const r = await runCli(["bot", "account", "add", "main", "--replace", "--apply", "--json"], rules, { stdin: `${OAT}\n` });
    expect(r.code).toBe(0);
    expect(r.json.steps.map((s: any) => s.result)).toEqual(["applied", "applied"]);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${OAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${OAT}\n`]);
  });

  // API 크레딧 방식(AC-22): Console API 키를 레인마다 하나씩, 보이지 않는 입력(파이프면 stdin 두 줄)으로 받는다.
  const apiWorld = (after: Record<string, string>): Rule[] => [
    ...world(after).slice(0, 3),
    pods(pod()),
    rule(adminArgv("account", "record", "main", "api"), { stdout: report("account record", "recorded") }),
  ];
  const API_BOTH = { ANTHROPIC_API_KEY: API_CHAT, ANTHROPIC_API_KEY_TASK: API_TASK };

  test("--by api apply: API 키 한 줄을 두 자리에 쓰고(구독과 같은 기본), --separate-tokens면 두 줄을 따로. claude를 띄우지 않고 봇 DB에 api로 기록한다", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--by", "api", "--apply", "--json"], apiWorld({ ANTHROPIC_API_KEY: API_CHAT, ANTHROPIC_API_KEY_TASK: API_CHAT }), { stdin: `${API_CHAT}\n` });
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("done");
    expect(sets(r)).toEqual([`ANTHROPIC_API_KEY=${API_CHAT}\n`, `ANTHROPIC_API_KEY_TASK=${API_CHAT}\n`]);
    expectNoSecrets({ ...r, calls: r.calls.filter((c) => c.stdin === undefined) }, [API_CHAT, API_TASK]);
    expect(r.calls.some((c) => c.argv[0] === "claude")).toBe(false);
    expect(execCalls(r)).toEqual([adminArgv("account", "record", "main", "api")]);
    expect(r.json.next).toBe("봇이 이 계정을 쓰게 하려면: homelab bot account use main --by api");

    const s = await runCli(["bot", "account", "add", "main", "--by", "api", "--separate-tokens", "--apply", "--json"], apiWorld(API_BOTH), { stdin: `${API_CHAT}\n${API_TASK}\n` });
    expect(s.code).toBe(0);
    expect(sets(s)).toEqual([`ANTHROPIC_API_KEY=${API_CHAT}\n`, `ANTHROPIC_API_KEY_TASK=${API_TASK}\n`]);
  });

  test("--by api: 줄 수가 다르거나 따로 받기인데 같은 키거나 짧으면 아무것도 쓰지 않고 실패한다", async () => {
    const cases: [string[], string][] = [[[], `${API_CHAT}\n${API_TASK}\n`], [[], "short\n"], [["--separate-tokens"], `${API_CHAT}\n${API_CHAT}\n`], [["--separate-tokens"], `${API_CHAT}\n`], [["--separate-tokens"], `${API_CHAT}\nshort\n`]];
    for (const [flags, stdin] of cases) {
      const r = await runCli(["bot", "account", "add", "main", "--by", "api", ...flags, "--apply", "--json"], apiWorld(API_BOTH), { stdin });
      expect([stdin.length, r.code]).toEqual([stdin.length, 1]);
      expect(r.writes).toEqual([]);
      expectNoSecrets(r, [API_CHAT, API_TASK]);
    }
  });

  // 터미널 판(C35): claude setup-token을 가짜 터미널에서 띄워 CLI가 화면에서 토큰 줄을 골라 받는다. 브라우저 로그인 한 번으로
  // 대화용·작업용 두 자리를 채우고, 토큰은 화면 어디에도 없다(로그인 안내 URL은 보인다).
  const claude = (...screens: string[]) => rule(["claude", "setup-token"], screens.map((s) => ({ stdout: s })), { noStdin: true });
  const sets = (r: { calls: { argv: string[]; stdin?: string }[] }) => r.calls.filter((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, FOLDER).join(" ")).map((c) => c.stdin);
  const ONE = { CLAUDE_CODE_OAUTH_TOKEN: OAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: OAT };
  // 가짜 터미널 시험은 CLI와 스텁을 각각 띄워 기본 5초보다 오래 걸릴 수 있다.
  const TTY_MS = 30_000;

  test("터미널: 로그인 한 번으로 토큰 하나를 대화용·작업용 두 자리에 쓰고, 토큰은 화면에 보이지 않는다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(ONE), claude(setupScreen(OAT))]);
    expect(r.code).toBe(0);
    expect(r.calls.filter((c) => c.argv[0] === "claude").length).toBe(1);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${OAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${OAT}\n`]);
    expect(leaks(r.screen, OAT)).toBe(false);
    expect(r.screen).toContain(OAUTH_URL);
    expect(r.screen).toContain("[토큰을 받아 화면에서 가렸다]");
  }, TTY_MS);

  test("터미널 요약: 끝나면 무엇이 바뀌었나·다음 할 일 몇 줄만 보이고 단계 표·kubectl 줄은 없다. --verbose면 지금의 전체 표", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(ONE), claude(setupScreen(OAT))]);
    expect(r.code).toBe(0);
    const tail = r.screen.slice(r.screen.indexOf("Store this token securely"));
    expect(tail).toContain("계정 main 등록 끝(구독)");
    expect(tail).toContain("토큰 하나를 대화용·작업용에 함께 저장했다");
    expect(tail).toContain("다음: homelab bot account use main --apply");
    for (const noise of ["kubectl", "admin-main.js", "Infisical homelab/prod", "주의:", "레인"]) expect([noise, tail.includes(noise)]).toEqual([noise, false]);

    const v = await runCliTty(["bot", "account", "add", "main", "--apply", "--verbose"], [...world(ONE), claude(setupScreen(OAT))]);
    expect(v.code).toBe(0);
    expect(v.screen).toContain("  1 Infisical homelab/prod /bot-accounts/main");
    expect(v.screen).toContain("admin-main.js account record main subscription");
  }, TTY_MS);

  test("터미널 요약: plan이면 할 일과 실행 줄만, 실패면 실패한 단계 이름과 다음 행동이 보인다", async () => {
    const p = await runCliTty(["bot", "account", "add", "main"], world(ONE));
    expect(p.code).toBe(0);
    expect(p.screen).toContain("계획만 봤다(아무것도 바꾸지 않았다)");
    expect(p.screen).toContain("할 일: 토큰 받아 저장 → 봇 DB에 계정 기록");
    expect(p.screen).toContain("다음: homelab bot account add main --apply");
    expect(p.screen).not.toContain("admin-main.js");

    const fail = [...world(ONE).slice(0, 4), rule(adminArgv("account", "record", "main", "subscription"), { stdout: report("account record", "usage"), code: 64 }), claude(setupScreen(OAT))];
    const f = await runCliTty(["bot", "account", "add", "main", "--apply"], fail);
    expect(f.code).toBe(1);
    const tail = f.screen.slice(f.screen.indexOf("Store this token securely"));
    expect(tail).toContain("실패: 봇 DB에 계정 기록");
    expect(tail).toContain("봇이 계정을 기록하지 않았다: usage");
    expect(tail).toContain("다음: 지금 봇 이미지의 관리 진입점이 이 계정 명령을 받지 않는다");
    expect(leaks(f.screen, OAT)).toBe(false);
  }, TTY_MS);

  test("파이프·--json 출력은 터미널 요약을 쓰지 않는다(단계 표 그대로, JSON에 summary 칸 없음)", async () => {
    const r = await runCli(["bot", "account", "add", "main", "--apply"], world(ONE), { stdin: `${OAT}\n` });
    expect(r.code).toBe(0);
    expect(r.stdout).toStartWith("실행\n  1 Infisical homelab/prod /bot-accounts/main");
    expect(r.stdout).toContain("다음: 봇이 이 계정을 쓰게 하려면: homelab bot account use main\n");
    const j = await runCli(["bot", "account", "add", "main", "--apply", "--json"], world(ONE), { stdin: `${OAT}\n` });
    expect(Object.keys(j.json)).toEqual(["schema", "command", "mode", "status", "steps", "notes", "next"]);
  });

  test("터미널: 프로젝트 ID가 환경에 없으면 한 실행에 한 번만 묻고, 묻지 않게 하는 방법을 한 줄 알린다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(ONE), claude(setupScreen(OAT))], { project: false, steps: [{ wait: /project ID: /, send: `${FAKE_PROJECT}\r` }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(0);
    expect(r.screen.match(/project ID: /g)?.length).toBe(1);
    expect(r.screen).toContain("셸 설정에 export HOMELAB_INFISICAL_PROJECT_ID=<ID>");
    expect(sets(r).length).toBe(2);
  }, TTY_MS);

  test("터미널: 프로젝트 ID 형식이 틀리면 다시 묻지 않고 한 번에 실패한다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main"], world(ONE), { project: false, steps: [{ wait: /project ID: /, send: "not-a-uuid\r" }] });
    expect(r.code).toBe(1);
    expect(r.screen.match(/project ID: /g)?.length).toBe(1);
    expect(r.screen).toContain("형식이 아니다");
  }, TTY_MS);

  test("터미널 --separate-tokens: 자리마다 로그인해 두 토큰을 따로 쓰고, 둘 다 화면에 없다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--separate-tokens", "--apply"], [...world({ CLAUDE_CODE_OAUTH_TOKEN: OAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: OAT2 }), claude(setupScreen(OAT), setupScreen(OAT2))]);
    expect(r.code).toBe(0);
    expect(r.calls.filter((c) => c.argv[0] === "claude").length).toBe(2);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${OAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${OAT2}\n`]);
    expect([leaks(r.screen, OAT), leaks(r.screen, OAT2)]).toEqual([false, false]);
    expect(r.screen).toContain("대화용 토큰");
    expect(r.screen).toContain("작업용 토큰");
  }, TTY_MS);

  test("터미널: 같은 토큰이 두 번 나오면(따로 받기) 아무것도 쓰지 않고 실패한다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--separate-tokens", "--apply"], [...world(ONE), claude(setupScreen(OAT), setupScreen(OAT))]);
    expect(r.code).toBe(1);
    // claude setup-token(토큰 발급)도 쓰기로 센다. 그 밖의 쓰기(Infisical·봇 DB)는 없다.
    expect(r.writes.map((c) => c.argv)).toEqual([["claude", "setup-token"], ["claude", "setup-token"]]);
    expect(r.screen).toContain("두 토큰이 같다");
    expect(leaks(r.screen, OAT)).toBe(false);
  }, TTY_MS);

  test("터미널: 토큰이 다른 글과 한 줄이어도 받아 가린다", async () => {
    const odd = `Opening browser…\n${OAUTH_URL}\nYour token: ${OAT}\n`;
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(ONE), claude(odd)]);
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${OAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${OAT}\n`]);
    expect(leaks(r.screen, OAT)).toBe(false);
    expect(r.screen).toContain("Your token: [토큰을 받아 화면에서 가렸다]");
  }, TTY_MS);

  test("터미널: 토큰을 확신하지 못하면 가린 채 받지 않고, 다른 터미널에서 받은 토큰을 가려진 입력으로 받는다. 화면 어디에도 토큰이 없다", async () => {
    const odd = ` ${OAUTH_URL}\n\n Your OAuth token (valid for 1 year):\n\n ${OAT.slice(0, 40)}\n ${OAT.slice(40)}\n\n Store this token securely.\n`;
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(ONE), claude(odd)], { steps: [{ wait: /화면에 보이지 않는다/, send: `${OAT}\r` }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${OAT}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${OAT}\n`]);
    expect(r.screen).toContain("값을 확신하지 못해 받지 않았다");
    expect(r.screen).toContain("다른 터미널에서 claude setup-token을 실행해");
    expect(r.screen).toContain(OAUTH_URL);
    expect(leaks(r.screen, OAT)).toBe(false);
  }, TTY_MS);

  test("터미널: 화면에 토큰 꼴이 하나도 없으면(새 꼴) 화면을 가리지 않고, 사람이 보이는 값을 가려진 입력에 붙여 넣는다", async () => {
    const fresh = "cc-oauth-FAKEnewformFAKEnewform0123456789";
    const odd = `Opening browser…\n${OAUTH_URL}\nYour credential: ${fresh}\n`;
    const both = { CLAUDE_CODE_OAUTH_TOKEN: fresh, CLAUDE_CODE_OAUTH_TOKEN_TASK: fresh };
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...world(both), claude(odd)], { steps: [{ wait: /화면에 보이지 않는다/, send: `${fresh}\r` }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`CLAUDE_CODE_OAUTH_TOKEN=${fresh}\n`, `CLAUDE_CODE_OAUTH_TOKEN_TASK=${fresh}\n`]);
    const prompt = r.screen.indexOf("화면에 보이지 않는다");
    expect(r.screen.slice(0, prompt)).toContain(`Your credential: ${fresh}`);
    expect(r.screen).toContain("화면에서 토큰을 찾지 못했다");
    expect(r.screen.slice(prompt)).not.toContain(fresh);
  }, TTY_MS);

  test("터미널 --by api: API 키를 가려진 입력 한 번으로 받아 두 자리에 쓰고, 화면에 되찍지 않는다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--by", "api", "--apply"], apiWorld({ ANTHROPIC_API_KEY: API_CHAT, ANTHROPIC_API_KEY_TASK: API_CHAT }), { steps: [{ wait: /대화용·작업용 API 키\(화면에 보이지 않는다\)/, send: `${API_CHAT}\r` }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`ANTHROPIC_API_KEY=${API_CHAT}\n`, `ANTHROPIC_API_KEY_TASK=${API_CHAT}\n`]);
    expect(r.screen).not.toContain("fakevalue-api");
    expect(r.calls.some((c) => c.argv[0] === "claude")).toBe(false);
  }, TTY_MS);

  test("터미널: 좁은 화면에서 긴 값을 붙여 넣어 가림 글자가 여러 줄로 다시 그려져도 값은 화면에 없다", async () => {
    const long = `fakevalue-api-long-${"x1Y2z3".repeat(20)}`;
    const r = await runCliTty(["bot", "account", "add", "main", "--by", "api", "--apply"], apiWorld({ ANTHROPIC_API_KEY: long, ANTHROPIC_API_KEY_TASK: long }), { cols: 40, steps: [{ wait: /API 키\(화면에/, send: long.slice(0, 50) }, { wait: /•{30}/, send: `${long.slice(50)}\r` }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(0);
    expect(sets(r)).toEqual([`ANTHROPIC_API_KEY=${long}\n`, `ANTHROPIC_API_KEY_TASK=${long}\n`]);
    expect(r.screen).not.toContain("x1Y2z3");
    expect(r.screen).not.toContain("fakevalue-api");
  }, TTY_MS);

  test("터미널: 붙여 넣은 값이 검사에 걸리면 오류 문구에 값이 없고 아무것도 쓰지 않는다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--by", "api", "--apply"], apiWorld(API_BOTH), { steps: [{ wait: /화면에 보이지 않는다/, send: `${API_CHAT} \r` }] });
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.screen).toContain("공백으로 시작하거나 끝난다");
    expect(r.screen).not.toContain("fakevalue-api");
  }, TTY_MS);

  test("터미널 --json·--verbose: 화면(stdout·stderr 모두)에 토큰이 없고, --json은 결과 문서 하나다", async () => {
    for (const flag of ["--json", "--verbose"]) {
      const r = await runCliTty(["bot", "account", "add", "main", "--apply", flag], [...world(ONE), claude(setupScreen(OAT))]);
      expect([flag, r.code, leaks(r.screen, OAT)]).toEqual([flag, 0, false]);
      expect(sets(r).length).toBe(2);
      if (flag === "--json") expect(JSON.parse(r.screen.slice(r.screen.lastIndexOf('{"schema"')).replace(/\r\n/g, "\n")).status).toBe("done");
    }
  }, TTY_MS);

  // 진행 표시(C35 할 일 10). Infisical 쓰기를 느리게 해 움직이는 표시가 몇 번 다시 그려지게 한다.
  const slowWorld = (sleepMs: number) => world(ONE).map((r, i) => (i === 2 ? { ...infisicalSet(FOLDER, { sleepMs }), captureStdin: true } : r));
  const SPIN = /[◒◐◓◑]  토큰 저장 중\(Infisical\)/;

  test("터미널 요약: 토큰을 받은 뒤 저장·기록 중인 일을 한 줄씩 보이고, 오래 걸리면 움직이는 표시로 그 줄만 다시 그린다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...slowWorld(600), claude(setupScreen(OAT))]);
    expect(r.code).toBe(0);
    const tail = r.screen.slice(r.screen.indexOf("[토큰을 받아 화면에서 가렸다]"));
    const save = tail.indexOf("토큰 저장 중(Infisical)");
    const record = tail.indexOf("봇 DB에 계정 기록 중");
    const head = tail.indexOf("계정 main 등록 끝(구독)");
    expect([save > 0, record > save, head > record]).toEqual([true, true, true]);
    expect(tail.match(new RegExp(SPIN.source, "g"))!.length).toBeGreaterThan(2);
    expect(tail).toMatch(/◇(\x1b\[[0-9;]*m)?  토큰 저장 중\(Infisical\)\r?\n/);
    // 다시 그리기는 한 줄 위(진행 줄 자신)로만 올라가 그 줄을 지우고 다시 쓴다. 커서는 숨기지 않는다.
    for (const m of tail.matchAll(/\x1b\[\d*A/g)) expect(tail.slice(m.index!, m.index! + 8)).toBe("\x1b[1A\r\x1b[K");
    expect(r.screen).not.toContain("\x1b[?25l");
    expect(leaks(r.screen, OAT)).toBe(false);
  }, TTY_MS);

  test("파이프·--json·--verbose는 진행 표시를 더하지 않는다(지금 출력 그대로)", async () => {
    const p = await runCli(["bot", "account", "add", "main", "--apply"], world(ONE), { stdin: `${OAT}\n` });
    expect(p.code).toBe(0);
    expect(p.stderr).not.toContain("저장 중");
    expect(p.stderr).not.toMatch(/[◒◐◓◑]/);
    for (const flag of ["--json", "--verbose"]) {
      const r = await runCliTty(["bot", "account", "add", "main", "--apply", flag], [...slowWorld(300), claude(setupScreen(OAT))]);
      expect([flag, r.code, r.screen.includes("토큰 저장 중"), /[◒◐◓◑]/.test(r.screen)]).toEqual([flag, 0, false, false]);
    }
  }, TTY_MS);

  test("터미널: 움직이는 표시 도중 Ctrl-C면 곧 끝나고, 커서는 보이며 다음 프롬프트는 새 줄에서 시작한다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--apply"], [...slowWorld(2_500), claude(setupScreen(OAT))], { steps: [{ wait: SPIN, send: "\x03" }] });
    expect(r.pending).toEqual([]);
    expect(r.code).not.toBe(0);
    expect(r.screen).not.toContain("\x1b[?25l");
    const last = r.screen.lastIndexOf("토큰 저장 중(Infisical)");
    expect(r.screen.slice(last)).toStartWith("토큰 저장 중(Infisical)\r\n");
    expect(r.screen).not.toContain("계정 main 등록 끝");
    expect(leaks(r.screen, OAT)).toBe(false);
  }, TTY_MS);

  test("터미널: 가려진 입력에서 Ctrl-C면 친 글자를 보이지 않고 아무것도 쓰지 않은 채 실패한다", async () => {
    const r = await runCliTty(["bot", "account", "add", "main", "--by", "api", "--apply"], apiWorld(API_BOTH), { steps: [{ wait: /화면에 보이지 않는다/, send: "fakevalue-api-half" }, { wait: /•{6}/, send: "\x03" }] });
    expect(r.pending).toEqual([]);
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.screen).toContain("입력을 취소했다");
    expect(r.screen).not.toContain("fakevalue-api");
  }, TTY_MS);

  test("계정 이름은 소문자·숫자·하이픈 32자 이하만 받는다(Infisical 경로·지표 라벨)", async () => {
    for (const name of ["Main", "-main", "main-", "a".repeat(33), "../x", "main/x"]) {
      const r = await runCli(["bot", "account", "add", name, "--json"], []);
      expect([name, r.code]).toEqual([name, 64]);
      expect(r.calls).toEqual([]);
    }
  });
});
