// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { isCancel, password } from "@clack/prompts";
import { readFileSync, readSync } from "node:fs";
import type { TerminalLogin } from "./exec";
import { valueProblem } from "./infisical";
import { promptOutput } from "./output";
import { CliError } from "./result";
import { Secret } from "./secret";

// tty 가려진 입력(봇 계정 자격). clack password는 readline에 출력을 주지 않아 입력을 되찍지 않고, 화면에는 가림 글자만 그린다.
// 그리는 글은 출력 계층(promptOutput)을 거쳐 stderr로 간다(stdout은 결과 자리). 받은 값은 부르는 쪽이 곧바로 Secret으로 감싼다.
export async function askHiddenTty(prompt: string): Promise<string> {
  const v = await password({ message: prompt, mask: "•", output: promptOutput() });
  if (isCancel(v)) throw new Error("입력을 취소했다");
  return v;
}

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

// 봇 계정 자격 입력(homelab bot account add). 자리는 대화용·작업용 둘이다(대화용은 대화와 PR 리뷰, 작업용은 코드 변경 작성).
// 기본은 값 하나를 두 자리에 함께 쓴다(로그인 한 번, 사용자 결정 2026-11-11). separate면 자리마다 따로 받고 같은 값이면 거부한다.
// 잃는 것: 한쪽만 교체·철회할 수 없고, 샌 값만으로 어느 자리인지 가를 수 없다. 그래서 따로 받는 선택지를 둔다.
// 파이프: stdin 전체를 줄로 나눠 받을 값 수(기본 1, separate면 자리 수)와 같아야 한다.
export type SlotInput = {
  isTTY: boolean;
  // 로그인 화면(거른 뒤)도 stderr로 간다. 꼴이 달라 거르지 못하면 토큰이 그대로 보이므로 stderr가 터미널일 때만 띄운다.
  stderrTTY: boolean;
  readStdin: () => string;
  // tty에서 에코 없는 한 줄. 취소는 던진다.
  askHidden: (prompt: string) => Promise<string>;
};

export const SEPARATE_FLAG = "--separate-tokens";

export const readStdinAll = (): string => readFileSync(0, "utf8");

// Claude 구독 장기 토큰. tty면 받을 값마다 login(자리 이름)이 `claude setup-token`을 띄워 화면에서 토큰을 받는다.
// login이 null(화면에서 토큰 줄을 알아보지 못함)이면 가려진 입력으로 받는다.
export async function readSetupTokens(io: SlotInput, lanes: string[], separate: boolean, login: (slot: string) => Promise<Secret | null>): Promise<Secret[]> {
  if (io.isTTY && !io.stderrTTY)
    throw new CliError(
      "stderr가 터미널이 아니라 claude setup-token을 띄우지 않았다(로그인 화면과 발급 토큰이 stderr의 파일·파이프에 남을 수 있다)",
      "stderr를 터미널에 둔 채 다시 실행하거나(--json >결과파일은 된다), 받은 토큰을 stdin으로 넘긴다",
    );
  return readSlots(io, lanes, separate, "토큰", login, `${SEPARATE_FLAG}를 골랐는데 두 토큰이 같다. 자리마다 claude setup-token으로 따로 받거나, 같은 토큰을 함께 쓰려면 ${SEPARATE_FLAG}를 뺀다`);
}

// Claude Console API 키. 자식을 띄우지 않아 stderr 조건이 없다. 구독 토큰과 같은 기본(키 하나를 두 자리에)이다.
export async function readApiKeys(io: SlotInput, lanes: string[], separate: boolean): Promise<Secret[]> {
  return readSlots(io, lanes, separate, "API 키", async () => null, `${SEPARATE_FLAG}를 골랐는데 두 API 키가 같다. Console에서 자리마다 키를 따로 만들거나, 같은 키를 함께 쓰려면 ${SEPARATE_FLAG}를 뺀다`);
}

async function readSlots(io: SlotInput, lanes: string[], separate: boolean, what: string, login: (slot: string) => Promise<Secret | null>, distinct: string): Promise<Secret[]> {
  const slots = separate ? lanes : [lanes.join("·")];
  const values: Secret[] = [];
  const check = (value: Secret, slot: string) => {
    const problem = valueProblem(value);
    if (problem) throw new Error(`${slot} ${what}: ${problem}`);
    values.push(value);
  };
  if (io.isTTY) {
    for (const slot of slots) {
      const got = await login(slot);
      check(got ?? new Secret(await io.askHidden(`${slot} ${what}(화면에 보이지 않는다)`)), slot);
    }
  } else {
    const lines = io.readStdin().replace(/\r?\n$/, "").split(/\r?\n/);
    if (lines.length !== slots.length)
      throw new Error(separate ? `${SEPARATE_FLAG}면 stdin은 자리마다 한 줄씩 ${slots.length}줄이어야 한다(${lanes.join(", ")} 순서)`
        : `stdin은 ${what} 한 줄이어야 한다(${slots[0]}에 함께 쓴다. 따로 넘기려면 ${SEPARATE_FLAG}와 ${lanes.length}줄)`);
    lines.forEach((raw, i) => check(new Secret(raw), slots[i]));
  }
  if (values.some((v, i) => values.slice(i + 1).some((w) => v.equals(w)))) throw new Error(distinct);
  return separate ? values : lanes.map(() => values[0]);
}

// tty에서 받을 값 하나의 브라우저 로그인. claude가 이 기기에 있어야 한다(봇 파드가 아니라 CLI를 돌리는 기기).
// 화면 글은 tokenScreenFilter로 걸러 screen(stderr)에 보인다. stdout은 결과 문서 하나뿐이다(--json >파일).
export async function setupTokenLogin(login: TerminalLogin, slot: string, progress: (line: string) => void, screen: (text: string) => void): Promise<Secret | null> {
  progress(`${slot} 토큰: claude setup-token을 띄운다. 브라우저에서 봇 계정으로 로그인한다(토큰은 CLI가 받고 화면에는 보이지 않는다)`);
  const filter = tokenScreenFilter(screen);
  // 브라우저 로그인을 사람이 끝낼 때까지 기다린다(10분).
  const r = await login(["claude", "setup-token"], (t) => filter.push(t), 600_000);
  filter.end();
  if (r.errKind === "not-found") throw new CliError("claude(Claude Code CLI)가 이 기기의 PATH에 없다", "Claude Code CLI를 설치한 기기에서 다시 실행한다(토큰은 이 기기에서 받는다)");
  if (r.errKind === "timeout") throw new CliError("claude setup-token: 10분 안에 끝나지 않았다", "같은 명령을 다시 실행한다");
  if (r.errKind === "spawn") throw new CliError("claude setup-token을 띄우지 못했다", "Claude Code CLI가 실행되는지(claude --version) 본 뒤 같은 명령을 다시 실행한다");
  if (r.code !== 0) throw new CliError(`claude setup-token이 실패했다(exit ${r.code ?? r.signal ?? "?"})`, "브라우저 로그인을 마친 뒤 같은 명령을 다시 실행한다");
  const { token, conflict } = filter.result();
  if (conflict) throw new CliError("claude setup-token 화면에 서로 다른 토큰이 둘 나왔다. 아무것도 쓰지 않았다", "같은 명령을 다시 실행하고, 이번에 발급된 토큰은 Claude 설정에서 철회한다");
  if (!token) progress("화면에서 토큰 줄을 알아보지 못했다(claude 출력 꼴이 달라졌다). 위에 나온 토큰을 복사해 다음 입력에 붙여 넣고, 붙여 넣은 뒤 터미널 스크롤을 지운다");
  return token;
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
