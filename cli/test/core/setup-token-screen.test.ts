// claude setup-token 화면 거르기(homelab bot account add, C35). 자식 출력을 줄 단위로 모아 토큰 줄만 가리고 나머지는 화면에 넘긴다.
// 2026-11-11 관측(claude 2.1.322): 안내 글 → "Your OAuth token (valid for 1 year):" → 빈 줄 → sk-ant-oat01-… 한 줄 → "Store this token securely…".
import { describe, expect, test } from "bun:test";
import { tokenScreenFilter } from "../../src/core/input";
import { Secret } from "../../src/core/secret";

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

function run(chunks: string[]) {
  const shown: string[] = [];
  const f = tokenScreenFilter((t) => shown.push(t));
  for (const c of chunks) f.push(c);
  f.end();
  return { screen: shown.join(""), shown, ...f.result() };
}

// 토큰의 비밀 부분(접두 sk-ant-oat01- 뒤)에서 6자 이상 이어진 조각이 화면에 있으면 샌 것이다.
function leaked(screen: string): boolean {
  const secret = TOKEN.slice("sk-ant-oat01-".length);
  for (let i = 0; i + 6 <= secret.length; i++) if (screen.includes(secret.slice(i, i + 6))) return true;
  return false;
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

  test("꼴이 다르면(토큰이 다른 글과 한 줄) 가리지 않고 받지도 않는다: 지금처럼 화면에 보이고 가려진 입력으로 떨어진다", () => {
    const r = run([`Your token: ${TOKEN}\r\n`]);
    expect(r.token).toBe(null);
    expect(r.screen).toBe(`Your token: ${TOKEN}\r\n`);
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
