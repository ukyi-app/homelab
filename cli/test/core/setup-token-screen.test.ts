// claude setup-token 화면 거르기(homelab bot account add, C35). 자식 출력을 줄 단위로 모아 토큰 줄만 가리고 나머지는 화면에 넘긴다.
// 2026-11-11 관측(claude 2.1.322): 안내 글 → "Your OAuth token (valid for 1 year):" → 빈 줄 → sk-ant-oat01-… 한 줄 → "Store this token securely…".
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tokenScreenFilter } from "../../src/core/input";
import { Secret } from "../../src/core/secret";
import { rule, stubSandbox } from "../harness";

const TOKEN = "sk-ant-oat01-FAKEfakeFAKEfake_0123456789-abcdefghijABCDEFGHIJ_klmnopqrstuvwxyzKLMNOPQRSTUVWXYZ-0123456789AA";
const SCREEN = [
  "Opening browser to sign in…\r\n",
  "Browser didn't open? Use the url below to sign in:\r\n",
  "\r\n",
  "https://claude.ai/oauth/authorize?code=true&client_id=fake&state=fake\r\n",
  "\r\n",
  "Paste code here if prompted > ",
  "\r\n",
  "✓ Long-lived authentication token created successfully!\r\n",
  "\r\n",
  "Your OAuth token (valid for 1 year):\r\n",
  "\r\n",
  `${TOKEN}\r\n`,
  "\r\n",
  "Store this token securely. You won't be able to see it again.\r\n",
].join("");

function run(chunks: string[], cols?: number) {
  const shown: string[] = [];
  const f = tokenScreenFilter((t) => shown.push(t), cols);
  for (const c of chunks) f.push(c);
  f.end();
  return { screen: shown.join(""), shown, ...f.result() };
}

// 토큰의 비밀 부분(접두 sk-ant-oat01- 뒤)에서 6자 이상 이어진 조각이 화면에 있으면 샌 것이다. escape·공백·줄바꿈을 걷어 낸 뒤에도 본다
// (접힌 토큰 조각이 줄을 넘어 이어 보이거나 색 escape로 갈라진 경우). 머리 sk-ant-도 가린다.
const ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[ -~])/g;
function leaked(screen: string, token = TOKEN): boolean {
  const secret = token.slice("sk-ant-oat01-".length);
  const flat = screen.replace(ESC, "").replace(/\s/g, "");
  if (flat.includes("sk-ant-")) return true;
  for (let i = 0; i + 6 <= secret.length; i++) if (screen.includes(secret.slice(i, i + 6)) || flat.includes(secret.slice(i, i + 6))) return true;
  return false;
}

// 두 조각으로 자른 모든 경계와 한 글자씩 온 경우를 모두 돈다.
function everyCut(screen: string, cols: number | undefined, check: (r: ReturnType<typeof run>, how: string) => void) {
  check(run([screen], cols), "whole");
  for (let cut = 1; cut < screen.length; cut++) check(run([screen.slice(0, cut), screen.slice(cut)], cols), `cut ${cut}`);
  check(run([...screen], cols), "one by one");
}

describe("setup-token 화면 거르기", () => {
  test("관측한 꼴: 토큰 줄 하나만 가리고 받는다. 로그인 안내(URL·코드 입력 안내)와 앞뒤 글은 그대로 보인다", () => {
    const r = run([SCREEN]);
    expect(r.token?.equals(new Secret(TOKEN))).toBe(true);
    expect(r.conflict).toBe(false);
    expect(leaked(r.screen)).toBe(false);
    expect(r.screen).toContain("https://claude.ai/oauth/authorize?code=true&client_id=fake&state=fake\r\n");
    expect(r.screen).toContain("Paste code here if prompted > ");
    expect(r.screen).toContain("Your OAuth token (valid for 1 year):\r\n");
    expect(r.screen).toContain("Store this token securely.");
    expect(r.screen).toContain("[토큰을 받아 화면에서 가렸다]\r\n");
  });

  test("어느 바이트 경계로 잘려 와도 토큰 조각이 새지 않고 결과가 같다", () => {
    const whole = run([SCREEN]).screen;
    for (let cut = 1; cut < SCREEN.length; cut++) {
      const r = run([SCREEN.slice(0, cut), SCREEN.slice(cut)]);
      expect([cut, leaked(r.screen), r.token?.equals(new Secret(TOKEN))]).toEqual([cut, false, true]);
      expect(r.screen).toBe(whole);
    }
    // 한 글자씩 와도 같다.
    const one = run([...SCREEN]);
    expect([leaked(one.screen), one.screen]).toEqual([false, whole]);
  });

  test("줄이 끝나기 전에도 토큰이 될 수 없는 앞부분은 곧바로 보인다(코드 입력 안내가 늦지 않게)", () => {
    const shown: string[] = [];
    const f = tokenScreenFilter((t) => shown.push(t));
    f.push("Paste code here if prompted > ");
    expect(shown.join("")).toBe("Paste code here if prompted > ");
    f.push("Opening browser");
    // 영숫자 꼬리는 토큰의 시작일 수 있어 줄이 끝날 때까지 붙든다.
    expect(shown.join("")).toBe("Paste code here if prompted > Opening ");
    f.push(" now\r\n");
    expect(shown.join("")).toBe("Paste code here if prompted > Opening browser now\r\n");
  });

  test("토큰 사이에 색 escape가 끼어도 escape 앞 조각을 미리 내보내지 않는다", () => {
    for (const colored of [`\x1b[1m${TOKEN.slice(0, 40)}\x1b[22m${TOKEN.slice(40)}\x1b[0m\r\n`, `${TOKEN} \r\x1b[K\r\n`, `\x1b[2K${TOKEN}\x1b[0K\r\n`]) {
      for (let cut = 1; cut < colored.length; cut++) {
        const r = run([colored.slice(0, cut), colored.slice(cut)]);
        expect([cut, leaked(r.screen), r.token?.equals(new Secret(TOKEN))]).toEqual([cut, false, true]);
      }
    }
  });

  test("토큰이 다른 글과 한 줄이어도 머리(sk-ant-)부터 받고 가린다. 앞 글은 그대로 보인다", () => {
    const r = run([`Your token: ${TOKEN}\r\n`]);
    expect(r.token?.equals(new Secret(TOKEN))).toBe(true);
    expect(r.screen).toBe("Your token: [토큰을 받아 화면에서 가렸다]\r\n");
  });

  test("토큰 꼴이 하나도 없으면 화면을 그대로 보이고 가린 것도 없다(가려진 입력으로 떨어져 사람이 화면의 값을 붙여 넣는다)", () => {
    const odd = "Opening browser…\r\nYour new credential: tok_FAKEfakeFAKEfake0123456789\r\n";
    const r = run([odd]);
    expect([r.token, r.hidden, r.screen]).toEqual([null, false, odd]);
  });

  test("같은 토큰을 다시 그려도 하나로 받고, 받은 뒤의 sk-ant- 줄은 꼴이 달라도 가린다", () => {
    const r = run([`${TOKEN}\r\n`, `${TOKEN}\r\n`, `again ${TOKEN}\r\n`]);
    expect(r.token?.equals(new Secret(TOKEN))).toBe(true);
    expect(r.conflict).toBe(false);
    expect(leaked(r.screen)).toBe(false);
  });

  test("서로 다른 토큰 줄이 둘이면 받지 않고 충돌로 알린다(둘 다 가린다)", () => {
    const other = `${TOKEN.slice(0, -2)}BB`;
    const r = run([`${TOKEN}\r\n`, `${other}\r\n`]);
    expect(r.token).toBe(null);
    expect(r.conflict).toBe(true);
    expect(leaked(r.screen)).toBe(false);
  });

  test("줄바꿈 없이 끝난 마지막 토큰 줄도 판정한다", () => {
    const r = run([`ok\r\n${TOKEN}`]);
    expect(r.token?.equals(new Secret(TOKEN))).toBe(true);
    expect(leaked(r.screen)).toBe(false);
  });
});

// 2026-11-11 owner 실측(claude 2.1.322, 가짜 터미널)에서 토큰 줄을 알아보지 못했다. 어떤 escape가 왔는지는 모른다. 그래서 터미널 UI(Ink)가
// 그릴 수 있는 꼴을 두루 넣는다. 꼴마다 모든 자름 경계·한 글자씩에서 (1) 화면에 토큰 조각이 없고 (2) 받은 값이 원본과 같다.
const LOGIN = [" Opening browser to sign in…", " Browser didn't open? Use the url below to sign in:", "", " https://claude.ai/oauth/authorize?code=true&client_id=fake&state=fake", ""];
const after = (token: string[]) => [" ✓ Long-lived authentication token created successfully!", "", " Your OAuth token (valid for 1 year):", "", ...token, "", " Store this token securely. You won't be able to see it again.", "", " Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>"];
// Ink식 접힘: 들여쓰기 한 칸 뒤 (열 - 1)자씩.
const folded = (cols: number) => TOKEN.match(new RegExp(`.{1,${cols - 1}}`, "g"))!.map((part) => ` ${part}`);
// Ink(log-update)가 앞 프레임을 지우는 꼴: 줄마다 줄 지우기·커서 위로, 끝에 줄 처음으로.
const erase = (lines: number) => `${"\x1b[2K\x1b[1A".repeat(lines - 1)}\x1b[2K\x1b[G`;
const cup = (rows: string[], from: number) => rows.map((l, i) => `\x1b[${from + i};1H${l}\x1b[K`).join("");

const FRAME = after([` ${TOKEN}`]);
const SHAPES: [string, string, number][] = [
  ["줄 앞 공백 한 칸(관측 배치), CRLF", [...LOGIN, ...FRAME].join("\r\n") + "\r\n", 200],
  ["줄바꿈이 LF만", [...LOGIN, ...FRAME].join("\n") + "\n", 200],
  ["같은 프레임을 줄 지우기·커서 위로 뒤 세 번 다시 그림", `${LOGIN.join("\r\n")}\r\n${[1, 2, 3].map(() => FRAME.join("\r\n")).join(erase(FRAME.length))}\r\n`, 200],
  ["줄마다 앞에 줄 지우기", FRAME.map((l) => `\x1b[2K${l}`).join("\r\n") + "\r\n", 200],
  ["열 폭(60)에서 Ink가 접음, 이어지는 줄도 한 칸 들여쓰기", after(folded(60)).join("\r\n") + "\r\n", 60],
  ["열 폭(60)을 넘는 줄을 터미널이 접음(줄바꿈 없음)", FRAME.join("\r\n") + "\r\n", 60],
  ["토큰 앞뒤·사이에 색 escape", after([` \x1b[1m\x1b[38;5;214m${TOKEN.slice(0, 30)}\x1b[39m${TOKEN.slice(30)}\x1b[22m\x1b[0m`]).join("\r\n") + "\r\n", 200],
  ["줄마다 커서 위치(CUP)로 그림, 줄바꿈 없음", cup(FRAME, 10), 200],
  ["CUP로 그리며 열 폭(60)에서 접힘, 두 번 다시 그림", `${cup(after(folded(60)), 10)}${cup(after(folded(60)), 10)}`, 60],
  ["다시 그리기 + 접힘 + 줄 지우기", `${after(folded(70)).join("\r\n")}${erase(after(folded(70)).length)}${after(folded(70)).map((l) => `\x1b[2K${l}`).join("\r\n")}\r\n`, 70],
];

describe("setup-token 화면 거르기: 화면 꼴", () => {
  for (const [name, screen, cols] of SHAPES) {
    test(`${name}: 토큰 조각 없이 원본과 같은 값을 받는다`, () => {
      everyCut(screen, cols, (r, how) => {
        expect([how, leaked(r.screen), r.token?.equals(new Secret(TOKEN)) ?? null, r.conflict, r.hidden]).toEqual([how, false, true, false, true]);
      });
      const r = run([screen], cols);
      expect(r.screen).toContain("[토큰을 받아 화면에서 가렸다]");
      expect(r.screen).toContain("Store this token securely");
    });
  }
});

// 가짜 터미널을 거친 판: 스텁이 그린 화면을 실제 Bun 가짜 터미널(열 80, 하위 프로세스의 stderr가 파이프라 기본 폭)로 받는다.
// 터미널이 \n을 \r\n으로 바꾸고 조각을 제멋대로 나눠 보낸다.
async function child(env: Record<string, string>) {
  const p = Bun.spawn([process.execPath, "--no-env-file", join(import.meta.dir, "..", "fixtures", "core", "login-child.ts")], { env: { ...env, LOGIN_CHILD_WANT: TOKEN }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { code, doc: JSON.parse(out), err };
}

const PTY_SHAPES: [string, string][] = [
  ["관측 배치(줄 앞 공백)", [...LOGIN, ...FRAME].join("\n") + "\n"],
  ["세 번 다시 그림", `${[1, 2, 3].map(() => FRAME.join("\n")).join(erase(FRAME.length))}\n`],
  ["열 폭 80에서 Ink가 접음", after(folded(80)).join("\n") + "\n"],
  ["CUP로 그리며 열 폭 80에서 접힘", cup(after(folded(80)), 5)],
  ["색 escape 사이에 낀 토큰", after([` \x1b[1m${TOKEN.slice(0, 30)}\x1b[22m${TOKEN.slice(30)}\x1b[0m`]).join("\n") + "\n"],
];

describe("setup-token 화면 거르기: 가짜 터미널 판", () => {
  for (const [name, screen] of PTY_SHAPES) {
    test(`${name}: 결과 문서에 받은 값이 원본과 같다고 나오고 화면에 토큰 조각이 없다`, async () => {
      const sb = stubSandbox([rule(["claude", "setup-token"], { stdout: screen }, { noStdin: true })]);
      const r = await child(sb.env);
      expect([r.code, r.doc.got, r.doc.same, leaked(r.err)]).toEqual([0, true, true, false]);
      expect(r.err).toContain("[토큰을 받아 화면에서 가렸다]");
    }, 20_000);
  }
});

describe("setup-token 화면 거르기: 확신이 없으면 받지 않는다(가린 채로)", () => {
  const cases: [string, string, number][] = [
    ["접힌 줄이 열 폭에 차지 않았는데 다음 줄이 토큰 글자뿐", after([` ${TOKEN.slice(0, 40)}`, ` ${TOKEN.slice(40)}`]).join("\r\n") + "\r\n", 200],
    ["접힌 줄 길이가 서로 다름", after([` ${TOKEN.slice(0, 59)}`, ` ${TOKEN.slice(59, 90)}`, ` ${TOKEN.slice(90)}`]).join("\r\n") + "\r\n", 60],
    ["같은 줄에서 커서를 옮긴 뒤 토큰 글자가 이어짐", after([` ${TOKEN.slice(0, 50)}\x1b[3G${TOKEN.slice(50)}`]).join("\r\n") + "\r\n", 200],
    ["꼴 검사에 걸림(머리 뒤가 짧다)", after([" sk-ant-oat01-short"]).join("\r\n") + "\r\n", 200],
    ["두 프레임 중 하나만 꼴이 다름", `${FRAME.join("\r\n")}\r\n${after([` ${TOKEN.slice(0, 40)}`, ` ${TOKEN.slice(40)}`]).join("\r\n")}\r\n`, 200],
  ];
  for (const [name, screen, cols] of cases) {
    test(`${name}: 받지 않고, 화면에 토큰 조각이 없다`, () => {
      everyCut(screen, cols, (r, how) => {
        expect([how, leaked(r.screen), r.token, r.hidden]).toEqual([how, false, null, true]);
      });
    });
  }

  test("안내 문구만 나오고 토큰 꼴이 없으면 받지 않고, 안내 뒤 글은 화면에 보이지 않는다", () => {
    const r = run([" Your OAuth token (valid for 1 year):\r\n\r\n tok_FAKEsecretish0123456789\r\n"]);
    expect([r.token, r.hidden]).toEqual([null, true]);
    expect(r.screen).not.toContain("FAKEsecretish");
  });

  test("자식이 1초 넘게 붙들려 있으면 알림을 한 번 보인다(가짜 터미널 판)", async () => {
    const sb = stubSandbox([rule(["claude", "setup-token"], { stdout: ` Your OAuth token (valid for 1 year):\n\n ${TOKEN}\n`, holdMs: 1_600 }, { noStdin: true })]);
    const r = await child(sb.env);
    expect([r.code, r.doc.same, leaked(r.err)]).toEqual([0, true, false]);
    expect(r.err).toContain("토큰을 받는 중(claude가 끝나기를 기다린다)");
    expect(r.err).toContain("[토큰을 받아 화면에서 가렸다]");
  }, 20_000);

  test("붙드는 동안 알림 한 줄을 보이면 끝난 뒤 붙든 화면을 다시 그리지 않고 가렸다는 줄만 보인다", () => {
    const shown: string[] = [];
    const f = tokenScreenFilter((t) => shown.push(t), 200);
    f.push(`${LOGIN.join("\r\n")}\r\n Your OAuth token (valid for 1 year):\r\n`);
    expect(f.holding()).toBe(true);
    f.notice("토큰을 받는 중");
    f.push(`\r\n ${TOKEN}\r\n\r\n Store this token securely.\r\n`);
    f.end();
    const screen = shown.join("");
    expect(f.result().token?.equals(new Secret(TOKEN))).toBe(true);
    expect(screen).toContain("토큰을 받는 중");
    expect(screen).toContain("[토큰을 받아 화면에서 가렸다]");
    expect(screen).not.toContain("Store this token");
    expect(leaked(screen)).toBe(false);
  });
});
