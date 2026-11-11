// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { readFileSync, readSync } from "node:fs";
import { isatty } from "node:tty";
import type { Exec } from "./exec";
import { valueProblem } from "./infisical";
import { CliError } from "./result";
import { Secret } from "./secret";

// 에코 없는 tty 한 줄. 바이트를 Enter까지 모은 뒤 UTF-8로 한 번만 디코딩한다(fatal). 함정:
// 1바이트마다 디코딩하면 한글·이모지가 바이트마다 U+FFFD가 되어 입력과 다른 값이 저장되고 길이 검사도 틀린다.
export function readHiddenLine(readByte: () => number | null): string {
  const bytes: number[] = [];
  for (;;) {
    const b = readByte();
    // Enter는 raw 모드에서 \r(0x0d)로 온다. Ctrl-C(0x03)는 취소.
    if (b === null || b === 0x0d || b === 0x0a) break;
    if (b === 0x03) throw new Error("입력을 취소했다");
    // Backspace(0x08)·Delete(0x7f)는 직전 UTF-8 문자 하나를 지운다. 이어지는 바이트(10xxxxxx)까지 함께 뺀다.
    if (b === 0x08 || b === 0x7f) {
      while (bytes.length > 0 && ((bytes.pop() as number) & 0xc0) === 0x80);
      continue;
    }
    bytes.push(b);
  }
  try {
    // ignoreBOM: 기본 디코더는 선두 U+FEFF를 지워 다른 값을 받아들인다. 그대로 두고 valueProblem이 판단한다.
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(new Uint8Array(bytes));
  } catch {
    throw new Error("입력이 올바른 UTF-8이 아니다");
  }
}

function readTtyHidden(): string {
  const stdin = process.stdin as unknown as { setRawMode?: (on: boolean) => void };
  stdin.setRawMode?.(true);
  try {
    const buf = Buffer.alloc(1);
    return readHiddenLine(() => (readSync(0, buf, 0, 1, null) === 0 ? null : buf[0]));
  } finally {
    stdin.setRawMode?.(false);
  }
}

// Claude 구독 장기 토큰 여러 개(homelab bot account add, 레인마다 하나).
// tty: 레인마다 login(lane)으로 `claude setup-token`을 띄운 뒤 에코 없는 한 줄. 파이프: stdin 전체를 줄로 나눠 레인 수와 같아야 한다.
// 같은 값을 두 레인에 넣으면 레인 분리가 무너진다(rotate.md 3e: 레인마다 따로). 그래서 값이 겹치면 거부한다.
// stderrTTY: 로그인 안내와 claude가 출력하는 발급 토큰은 stderr로 간다(setupTokenLogin). stderr가 터미널이 아니면 그 토큰이
// 파일·파이프에 남으므로 로그인을 띄우지 않고 거부한다. 무엇도 쓰기 전이다.
export function readSetupTokens(isTTY: boolean, ask: (q: string) => void, lanes: string[], login: (lane: string) => void, stderrTTY = isatty(2)): Secret[] {
  if (isTTY && !stderrTTY)
    throw new CliError(
      "stderr가 터미널이 아니라 claude setup-token을 띄우지 않았다(발급 토큰이 stderr의 파일·파이프에 남는다)",
      "stderr를 터미널에 둔 채 다시 실행하거나(--json >결과파일은 된다), 레인마다 받은 토큰을 stdin 두 줄로 넘긴다",
    );
  return readLaneValues(isTTY, ask, lanes, "토큰", login, "레인마다 다른 토큰이어야 한다(setup-token을 레인마다 따로 실행한다)");
}

// Claude Console API 키 여러 개(homelab bot account add --by api, 레인마다 하나). 자식을 띄우지 않아 stderr 조건이 없다.
// 같은 키를 두 레인에 넣으면 작업 파드에서 샌 키로 대화 레인까지 잃는다(레인 분리). 그래서 Console에서 레인마다 따로 만든다.
export function readApiKeys(isTTY: boolean, ask: (q: string) => void, lanes: string[]): Secret[] {
  return readLaneValues(isTTY, ask, lanes, "API 키", () => {}, "레인마다 다른 API 키여야 한다(Console에서 레인마다 키를 따로 만든다)");
}

function readLaneValues(isTTY: boolean, ask: (q: string) => void, lanes: string[], what: string, before: (lane: string) => void, distinct: string): Secret[] {
  const raws: string[] = [];
  if (isTTY) {
    for (const lane of lanes) {
      before(lane);
      ask(`${lane} 레인 ${what}(화면에 보이지 않는다): `);
      raws.push(readTtyHidden());
    }
  } else {
    const lines = readFileSync(0, "utf8").replace(/\r?\n$/, "").split(/\r?\n/);
    if (lines.length !== lanes.length) throw new Error(`stdin은 레인마다 한 줄씩 ${lanes.length}줄이어야 한다(${lanes.join(", ")} 순서)`);
    raws.push(...lines);
  }
  const values = raws.map((raw, i) => {
    const value = new Secret(raw);
    const problem = valueProblem(value);
    if (problem) throw new Error(`${lanes[i]} 레인 ${what}: ${problem}`);
    return value;
  });
  if (values.some((v, i) => values.slice(i + 1).some((w) => v.equals(w)))) throw new Error(distinct);
  return values;
}

// tty에서 레인 하나의 브라우저 로그인. claude가 이 기기에 있어야 한다(봇 파드가 아니라 CLI를 돌리는 기기).
// 자식 stdout은 stderr로 보낸다. CLI stdout은 결과 문서 하나만 내야 하고(--json >파일), claude는 안내와 발급 토큰을 stdout에 쓴다.
export function setupTokenLogin(exec: Exec, lane: string, progress: (line: string) => void): void {
  progress(`${lane} 레인: claude setup-token을 띄운다. 브라우저에서 봇 계정으로 로그인하고, 끝나면 화면에 나온 토큰을 복사해 다음 입력에 붙여 넣는다`);
  // 브라우저 로그인을 사람이 끝낼 때까지 기다린다(10분).
  const r = exec(["claude", "setup-token"], { stdio: "stdout-to-stderr", timeoutMs: 600_000 });
  if (r.errKind === "not-found") throw new CliError("claude(Claude Code CLI)가 이 기기의 PATH에 없다", "Claude Code CLI를 설치한 기기에서 다시 실행한다(토큰은 이 기기에서 받는다)");
  if (r.errKind === "timeout") throw new CliError("claude setup-token: 10분 안에 끝나지 않았다", "같은 명령을 다시 실행한다");
  if (r.code !== 0) throw new CliError(`claude setup-token이 실패했다(exit ${r.code ?? r.signal ?? "?"})`, "브라우저 로그인을 마친 뒤 같은 명령을 다시 실행한다");
}

// claude setup-token 화면에서 토큰 줄만 가리고 받는다. 관측한 꼴(claude 2.1.322, 2026-11-11)은 토큰이 홀로 한 줄이다.
// 그 꼴(escape를 뺀 줄 전체가 토큰)에 맞을 때만 가리고 받는다. 맞지 않으면 가리지도 받지도 않는다: 그때 토큰이 지금처럼
// 화면에 보여야 사람이 가려진 입력에 붙여 넣을 수 있다(가렸는데 못 받으면 아무도 토큰을 모른다).
// 함정: 자식 출력은 아무 바이트에서나 잘려 온다. 줄이 끝나기 전에는 꼬리의 영숫자·_·-와 escape 묶음(토큰의 시작일 수 있다)을
// 붙들고 그 앞만 내보낸다. 그래서 코드 입력 안내("… > ")처럼 줄바꿈 없는 글은 곧바로 보이고 토큰 조각은 판정 전에 나가지 않는다.
const TOKEN_LINE = /^sk-ant-oat\d{2}-[A-Za-z0-9_-]{20,}$/;
const TOKEN_MARK = "sk-ant-";
const MASKED = "[토큰을 받아 화면에서 가렸다]";
const ESCAPE = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])/g;
const visible = (s: string) => s.replace(ESCAPE, "").replace(/[\r\n]/g, "").trim();

// 꼬리에서 붙들 자리. 영숫자·_·-와 escape(끝나지 않은 escape 포함)만 이어진 꼬리의 시작 위치. 그 뒤에 붙은 공백·\r도
// 함께 붙든다(토큰 줄은 \r\n으로 끝나 \r까지 온 조각이 흔하다). 공백 앞이 토큰 글자가 아니면 공백은 그대로 내보낸다.
function holdFrom(s: string): number {
  const end = s.length;
  const ws = back(s, end, /[ \t\r]/);
  const run = back(s, ws, /[A-Za-z0-9_-]/);
  return run < ws ? run : back(s, end, null);
}

const WHOLE_ESCAPE = new RegExp(`^(?:${ESCAPE.source})$`);
const OPEN_ESCAPE = /^\x1b(?:\[[0-?]*[ -/]*|\][^\x07\x1b]*)?$/;

// from에서 앞으로 cls 글자와 escape를 건너뛴 위치. escape를 글자보다 먼저 본다: \x1b[K의 K를 글자로 세면 escape 앞(토큰)이 풀린다.
// 문자열 끝의 끝나지 않은 escape(\x1b[3 같은 것)도 escape로 본다.
function back(s: string, from: number, cls: RegExp | null): number {
  let i = from;
  for (;;) {
    const esc = s.lastIndexOf("\x1b", i - 1);
    if (esc >= 0 && i > esc) {
      const piece = s.slice(esc, i);
      if (WHOLE_ESCAPE.test(piece) || (i === s.length && OPEN_ESCAPE.test(piece))) {
        i = esc;
        continue;
      }
    }
    if (cls && i > 0 && cls.test(s[i - 1])) {
      i--;
      continue;
    }
    return i;
  }
}

export type TokenScreen = { push(chunk: string): void; end(): void; result(): { token: Secret | null; conflict: boolean } };

export function tokenScreenFilter(show: (text: string) => void): TokenScreen {
  let line = "";
  // line 앞부분 중 이미 내보낸 길이.
  let sent = 0;
  let token: Secret | null = null;
  let conflict = false;
  const judge = (full: string, ending: string) => {
    const text = visible(full);
    const rest = full.slice(sent);
    if (TOKEN_LINE.test(text)) {
      // 받는 즉시 Secret으로만 든다(추적 목록에 올라 출력 계층이 이 값을 다시 막는다).
      const got = new Secret(text);
      if (token === null && !conflict) token = got;
      else if (token !== null && !token.equals(got)) {
        token = null;
        conflict = true;
      }
      show(`${MASKED}${ending}`);
    } else if ((token !== null || conflict) && visible(rest).includes(TOKEN_MARK)) {
      show(`${MASKED}${ending}`);
    } else show(rest);
  };
  return {
    push(chunk) {
      line += chunk;
      for (let nl = line.indexOf("\n"); nl !== -1; nl = line.indexOf("\n")) {
        const full = line.slice(0, nl + 1);
        judge(full, full.endsWith("\r\n") ? "\r\n" : "\n");
        line = line.slice(nl + 1);
        sent = 0;
      }
      const upto = holdFrom(line);
      if (upto > sent) {
        show(line.slice(sent, upto));
        sent = upto;
      }
    },
    end() {
      if (line.length > sent) judge(line, "");
      line = "";
      sent = 0;
    },
    result: () => ({ token, conflict }),
  };
}

export function readSecretInput(isTTY: boolean, ask: (q: string) => void, prompt: string): Secret {
  let raw: string;
  if (isTTY) {
    ask(prompt);
    raw = readTtyHidden();
  } else {
    // 파이프 끝의 줄바꿈 하나만 뗀다(echo·printf '%s\n'). 나머지 줄바꿈은 아래 검사가 거부한다.
    raw = readFileSync(0, "utf8").replace(/\r?\n$/, "");
  }
  const value = new Secret(raw);
  const problem = valueProblem(value);
  if (problem) throw new Error(`입력한 값: ${problem}`);
  return value;
}
