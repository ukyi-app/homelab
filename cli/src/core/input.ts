// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { isCancel, password } from "@clack/prompts";
import { readFileSync, readSync } from "node:fs";
import type { TerminalLogin } from "./exec";
import { valueProblem } from "./infisical";
import { promptOutput, screenSize } from "./output";
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
  // 자식에게 실제 터미널 폭을 준다(화면이 자연스럽게 접힌다). 접힌 토큰은 거르기가 같은 폭으로 이어 읽는다.
  const cols = screenSize().cols;
  const filter = tokenScreenFilter(screen, cols);
  // 토큰 자리부터는 자식이 끝날 때까지 화면을 붙든다. 보통 곧 끝나지만, 1초 넘게 붙들면 멈춘 것처럼 보이지 않게 한 줄 알린다.
  let since: number | null = null;
  const tick = setInterval(() => {
    if (!filter.holding()) return;
    since ??= Date.now();
    if (Date.now() - since >= 1_000) filter.notice("토큰을 받는 중(claude가 끝나기를 기다린다)");
  }, 200);
  let r;
  try {
    // 브라우저 로그인을 사람이 끝낼 때까지 기다린다(10분).
    r = await login(["claude", "setup-token"], (t) => filter.push(t), 600_000, cols);
  } finally {
    clearInterval(tick);
  }
  filter.end();
  if (r.errKind === "not-found") throw new CliError("claude(Claude Code CLI)가 이 기기의 PATH에 없다", "Claude Code CLI를 설치한 기기에서 다시 실행한다(토큰은 이 기기에서 받는다)");
  if (r.errKind === "timeout") throw new CliError("claude setup-token: 10분 안에 끝나지 않았다", "같은 명령을 다시 실행한다");
  if (r.errKind === "spawn") throw new CliError("claude setup-token을 띄우지 못했다", "Claude Code CLI가 실행되는지(claude --version) 본 뒤 같은 명령을 다시 실행한다");
  if (r.code !== 0) throw new CliError(`claude setup-token이 실패했다(exit ${r.code ?? r.signal ?? "?"})`, "브라우저 로그인을 마친 뒤 같은 명령을 다시 실행한다");
  const { token, conflict, hidden } = filter.result();
  if (conflict) throw new CliError("claude setup-token 화면에 서로 다른 토큰이 둘 나왔다. 아무것도 쓰지 않았다", "같은 명령을 다시 실행하고, 이번에 발급된 토큰은 Claude 설정에서 철회한다");
  // 가렸는데 받지 못했으면 화면에 토큰이 없어 사람도 복사할 수 없다. 같은 명령을 다시 실행해도 같은 화면 꼴이면 또 받지 못한다.
  // 그래서 claude setup-token을 다른 터미널에서 직접 띄워 나온 토큰을 이 가려진 입력에 붙여 넣는 길을 알린다(stdin 한 줄과 같은 값 경로).
  if (!token && hidden)
    progress("화면의 토큰은 가렸지만 값을 확신하지 못해 받지 않았다(claude 화면 꼴이 달라졌다). 다른 터미널에서 claude setup-token을 실행해 나온 토큰을 다음 입력에 붙여 넣고 그 터미널 스크롤을 지운다. 방금 가린 토큰은 저장하지 않았으니 Claude 설정에서 철회한다");
  else if (!token) progress("화면에서 토큰을 찾지 못했다(claude 출력 꼴이 달라졌다). 위에 나온 토큰을 복사해 다음 입력에 붙여 넣고, 붙여 넣은 뒤 터미널 스크롤을 지운다");
  return token;
}

// claude setup-token 화면에서 토큰을 받고 가린다. 줄 꼴에 기대지 않고 escape를 걷어 낸 글자 흐름으로 판정한다. 함정(2026-11-11
// owner 실측, claude 2.1.322): 터미널 UI(Ink)가 커서 이동·줄 지우기로 다시 그리는 화면에서는 "토큰 홀로 한 줄" 꼴이 맞지 않는다.
// - 안내 문구(ANNOUNCE)나 토큰 머리(HEAD)가 보이면 그 자리부터 자식이 끝날 때까지 아무것도 내보내지 않고 붙든다.
// - 끝나면 붙든 글에서 머리마다 토큰을 읽는다. 모두 확신할 수 있고 꼴 검사를 지나고 같은 값일 때만 받는다. 값이 잘리거나 다른 글이
//   덧붙어 저장되면 등록이 조용히 깨지므로, 하나라도 확신이 없으면 받지 않는다. 꼴 검사는 잘린 앞 조각도 지나므로 끝은 따로 확인한다:
//   토큰 뒤에 공백·빈 줄만 지나 끝 표지(END_MARK, 관측 배치에서 빈 줄 뒤 다음 줄)가 와야 하고, 어느 토큰에도 들지 않은 토큰 글자뿐인
//   줄(이어 읽지 못한 조각일 수 있다)이 있으면 받지 않는다. 표지 문구가 바뀌면 받지 못하고 가려진 입력으로 넘어간다(안전한 쪽).
// - 받았으면(또는 서로 다른 토큰이면) 붙든 글을 토큰 글자만 뺀 채(첫 자리에 MASKED) 내보낸다. 내보낼 글에 토큰 조각이 보이면
//   내보내지 않는다. 받지 못했으면 붙든 글을 버린다. 그래서 받지 못해도 토큰은 화면에 남지 않는다.
// - 머리·안내가 하나도 없으면 아무것도 가리지 않는다(새 꼴의 토큰은 화면에 보이고, 사람이 가려진 입력에 붙여 넣는다).
// 함정: 자식 출력은 아무 바이트에서나 잘려 온다. 붙들기 전에는 꼬리의 토큰 글자·escape 묶음(머리의 시작일 수 있다)만 붙들고
// 그 앞은 곧바로 내보낸다. 그래서 코드 입력 안내("… > ")는 늦지 않고 머리 조각은 판정 전에 나가지 않는다.
const HEAD = "sk-ant-";
const ANNOUNCE = "Your OAuth token";
const END_MARK = "Store this token";
const TOKEN_FORM = /^sk-ant-oat\d{2}-[A-Za-z0-9_-]{20,}$/;
const TOKEN_CHAR = /^[A-Za-z0-9_-]$/;
const MASKED = "[토큰을 받아 화면에서 가렸다]";
// 화면 폭에서 접힌 줄로 볼 여유. 접힌 줄은 들여쓰기·상자 여백을 빼고 열 끝 가까이까지 찬다. 그보다 짧은 줄 뒤의 토큰 글자 줄은
// 이어진 것인지 다른 글인지 알 수 없어 받지 않는다.
const FOLD_SLACK = 4;
// 받지 못한 토큰 조각 검사의 창 길이. 영어 문구와 우연히 겹치지 않을 만큼 길고, 접힌 조각을 놓치지 않을 만큼 짧다.
const LEAK_WINDOW = 8;

// 자식 출력의 한 단위. row: 다른 줄로 간다(줄바꿈, 세로 이동, 커서 위치). jump: 같은 줄에서 커서가 옮겨 간다(\r, 가로 이동).
// 둘 다 아니면 화면 글이 아닌 escape(색, 줄 지우기, 모드)다. col은 이 단위 뒤의 커서 열이다(모르면 NaN: 접힘 판정이 실패 쪽으로 간다).
type Unit = { end: number; ch?: string; row?: boolean; jump?: boolean; col: (c: number) => number } | { end: number; open: true };

const CSI = /\x1b\[([0-?]*)[ -/]*([@-~])/y;
const keep = (c: number) => c;

function unitAt(s: string, i: number): Unit {
  const c = s[i];
  if (c !== "\x1b") {
    const ch = String.fromCodePoint(s.codePointAt(i)!);
    const end = i + ch.length;
    if (ch === "\n") return { end, row: true, col: () => 0 };
    if (ch === "\r") return { end, jump: true, col: () => 0 };
    if (ch === "\b") return { end, jump: true, col: (x) => Math.max(0, x - 1) };
    if (ch === "\t") return { end, ch: " ", col: (x) => (Math.floor(x / 8) + 1) * 8 };
    if (/[\u0000-\u001f\u007f-\u009f]/.test(ch)) return { end, col: keep };
    return { end, ch, col: (x) => x + 1 };
  }
  if (i + 1 >= s.length) return { end: s.length, open: true };
  const n = s[i + 1];
  if (n === "[") {
    CSI.lastIndex = i;
    const m = CSI.exec(s);
    if (!m) return /^\x1b\[[0-?]*[ -/]*$/.test(s.slice(i)) ? { end: s.length, open: true } : { end: i + 1, col: keep };
    const end = i + m[0].length;
    if (m[1].startsWith("?")) return { end, col: keep };
    const [a, b] = m[1].split(";").map((x) => Number(x) || 1);
    switch (m[2]) {
      case "A": case "B": case "d": case "e": return { end, row: true, col: keep };
      case "E": case "F": return { end, row: true, col: () => 0 };
      case "H": case "f": return { end, row: true, col: () => (b ?? 1) - 1 };
      case "G": case "`": return { end, jump: true, col: () => (a ?? 1) - 1 };
      case "C": case "a": return { end, jump: true, col: (x) => x + (a ?? 1) };
      case "D": return { end, jump: true, col: (x) => Math.max(0, x - (a ?? 1)) };
      case "u": return { end, row: true, col: () => NaN };
      default: return { end, col: keep };
    }
  }
  // OSC(링크·제목)과 DCS 같은 문자열 escape는 끝 표지까지 한 단위다.
  if (n === "]" || "PX^_".includes(n)) {
    const st = n === "]" ? /\x07|\x1b\\/g : /\x1b\\/g;
    st.lastIndex = i + 2;
    const m = st.exec(s);
    return m ? { end: m.index + m[0].length, col: keep } : { end: s.length, open: true };
  }
  if (n >= " " && n <= "/") return i + 2 >= s.length ? { end: s.length, open: true } : { end: i + 3, col: keep };
  const end = i + 2;
  if ("78Mc".includes(n)) return { end, row: true, col: () => NaN };
  if (n === "D") return { end, row: true, col: keep };
  if (n === "E") return { end, row: true, col: () => 0 };
  return { end, col: keep };
}

type Seen = { kind: "ch"; ch: string; col: number; a: number; b: number } | { kind: "row" } | { kind: "jump" };

// 붙든 글을 화면 글자·줄 이동·같은 줄 이동의 흐름으로 편다. 화면 글이 아닌 escape는 뺀다.
function flatten(raw: string, col0: number): Seen[] {
  const seen: Seen[] = [];
  let col = col0;
  for (let i = 0; i < raw.length; ) {
    const u = unitAt(raw, i);
    if ("open" in u) break;
    if (u.ch !== undefined) seen.push({ kind: "ch", ch: u.ch, col, a: i, b: u.end });
    else if (u.row) seen.push({ kind: "row" });
    else if (u.jump) seen.push({ kind: "jump" });
    col = u.col(col);
    i = u.end;
  }
  return seen;
}

const tokenAt = (s: Seen[], i: number) => i < s.length && s[i].kind === "ch" && TOKEN_CHAR.test((s[i] as { ch: string }).ch);
const charAt = (s: Seen[], i: number, ch: string) => i < s.length && s[i].kind === "ch" && (s[i] as { ch: string }).ch === ch;
// 공백 글자(탭은 flatten에서 공백이 된다). 줄 끝 공백은 Ink가 줄을 폭까지 채울 때도 온다.
const blankAt = (s: Seen[], i: number) => i < s.length && s[i].kind === "ch" && /^\s$/.test((s[i] as { ch: string }).ch);
// i부터 공백·같은 줄 이동·줄 이동을 지난 다음 화면 글자 자리와 그 사이 줄 이동 수.
function skipBlank(s: Seen[], i: number): { j: number; rows: number } {
  let rows = 0;
  while (i < s.length && (s[i].kind !== "ch" || blankAt(s, i))) {
    if (s[i].kind === "row") rows++;
    i++;
  }
  return { j: i, rows };
}
// j에서 시작하는 줄이 토큰 글자 한 묶음과 그 뒤 공백뿐인지(접힌 조각 꼴).
function tokenOnlyLine(s: Seen[], j: number): boolean {
  let k = j;
  while (tokenAt(s, k)) k++;
  if (k === j) return false;
  while (k < s.length && s[k].kind !== "row" && (s[k].kind === "jump" || blankAt(s, k))) k++;
  return k >= s.length || s[k].kind === "row";
}

// 머리 자리 h에서 토큰 하나를 읽는다. 토큰 글자가 끝나는 곳이 끝이다. 줄 끝 공백·같은 줄 이동·줄 이동을 지나 다음 화면 글자를 본다.
// 줄이 바뀌면 이어지는 것은 Ink식 접힘뿐이다: 줄 이동이 하나(빈 줄 없음)이고, 앞 줄의 토큰이 열 끝 가까이(열을 넘지 않게)까지 찼고,
// 다음 줄이(들여쓰기 뒤) 토큰 글자 한 묶음과 공백뿐이고, 접힌 줄 길이가 모두 같다. 확신할 수 없는 경우(sure: false):
// - 같은 줄에서 공백·커서 이동 뒤 토큰 글자가 이어진다.
// - 토큰 글자뿐인 다음 줄인데 위 접힘 조건이 아니다(빈 줄 사이, 앞 줄이 차지 않음, 길이 다름).
// - 앞 줄이 찼는데 바로 다음 줄이 토큰 글자로 시작하는 다른 꼴이다.
// 다른 글(토큰 글자가 아닌 글자, 다시 그린 머리)이나 흐름 끝이 오면 값이 끝난다. 그 끝이 믿을 만한지는 endMarked가 따로 본다.
function readToken(s: Seen[], h: number, cols: number | undefined): { value: string; at: number[]; sure: boolean } {
  let value = "";
  const at: number[] = [];
  const ends = new Set<number>();
  let i = h;
  for (;;) {
    while (tokenAt(s, i)) {
      value += (s[i] as { ch: string }).ch;
      at.push(i);
      i++;
    }
    const endCol = (s[i - 1] as { col: number }).col + 1;
    const { j, rows } = skipBlank(s, i);
    if (j >= s.length || !tokenAt(s, j)) return { value, at, sure: true };
    if (rows === 0) return { value, at, sure: false };
    if (headAt(s, j)) return { value, at, sure: true };
    const full = cols !== undefined && endCol >= cols - FOLD_SLACK;
    if (!tokenOnlyLine(s, j)) return { value, at, sure: !(rows === 1 && full) };
    ends.add(endCol);
    if (rows !== 1 || !full || endCol > (cols as number) || ends.size > 1) return { value, at, sure: false };
    i = j;
  }
}

// 값 끝의 독립 근거: 토큰 마지막 글자 뒤에 공백·줄 이동만 지나 END_MARK가 온다(Ink가 표지 문구를 접어도 공백 하나로 본다).
function endMarked(s: Seen[], last: number): boolean {
  let text = "";
  for (let i = last + 1; i < s.length && text.length < END_MARK.length; i++) {
    const x = s[i];
    if (x.kind === "ch" && !/^\s$/.test(x.ch)) text += x.ch;
    else if (text !== "" && !text.endsWith(" ")) text += " ";
  }
  return text === END_MARK;
}

// 어느 토큰에도 들지 않은 줄 가운데 토큰 글자 한 묶음뿐인 줄이 있는지. 이어 읽지 못한 접힌 조각이 다른 자리(표지 뒤, 커서로 옮겨
// 그린 줄)에 있으면 앞 조각만 받게 되므로 받지 않는 근거로 쓴다.
function strayTokenLine(s: Seen[], taken: Set<number>): boolean {
  for (let i = 0; i < s.length; ) {
    let e = i;
    while (e < s.length && s[e].kind !== "row") e++;
    let k = i;
    while (k < e && (s[k].kind === "jump" || blankAt(s, k))) k++;
    if (k < e && !taken.has(k) && tokenOnlyLine(s, k)) return true;
    i = e + 1;
  }
  return false;
}

function headAt(s: Seen[], i: number): boolean {
  for (let k = 0; k < HEAD.length; k++) if (!charAt(s, i + k, HEAD[k])) return false;
  return true;
}

const flatVisible = (raw: string) => flatten(raw, 0).map((x) => (x.kind === "ch" ? x.ch : "")).join("").replace(/\s/g, "");

export type TokenScreen = {
  push(chunk: string): void;
  end(): void;
  // hidden: 화면의 일부를 붙들었다(머리나 안내 문구가 보였다). 이때 받지 못했으면 화면에도 토큰이 없다.
  result(): { token: Secret | null; conflict: boolean; hidden: boolean };
  // 붙드는 중인지(자식이 끝나기를 기다린다).
  holding(): boolean;
  // 붙드는 동안 한 번만 한 줄 알린다. 알린 뒤에는 끝날 때 붙든 화면을 다시 그리지 않는다(자식의 커서 계산이 이미 어긋났다).
  notice(text: string): void;
};

// cols: 자식에게 준 열 수. 없으면 접힌 토큰을 받지 않는다.
export function tokenScreenFilter(show: (text: string) => void, cols?: number): TokenScreen {
  // 아직 내보내지 않은 꼬리와 그 시작의 커서 열.
  let pend = "";
  let pendCol = 0;
  // 최근에 내보낸 화면 글(안내 문구 찾기용).
  let recent = "";
  let held: { raw: string; col: number } | null = null;
  let ended = false;
  let noticed = false;
  let token: Secret | null = null;
  let conflict = false;

  const startsHold = (word: string) => word.includes(HEAD) || `${recent}${word}`.replace(/\s+/g, " ").endsWith(ANNOUNCE);
  const remember = (text: string) => (recent = `${recent}${text}`.slice(-64));

  // 꼬리를 앞에서부터 읽어 내보낼 수 있는 데까지 내보낸다. 토큰 글자 묶음(사이 escape 포함)은 끝날 때까지 붙든다.
  // 묶음이 머리를 품거나 안내 문구를 끝내면 그 묶음부터 붙들기 시작한다. last면 끝나지 않은 묶음·escape도 끝난 것으로 본다.
  const scan = (last: boolean) => {
    let col = pendCol;
    let safe = 0;
    let safeCol = col;
    let run = -1;
    let runCol = 0;
    let word = "";
    const close = (): boolean => {
      if (run < 0) return false;
      if (startsHold(word)) {
        if (run > 0) show(pend.slice(0, run));
        held = { raw: pend.slice(run), col: runCol };
        pend = "";
        return true;
      }
      remember(word);
      run = -1;
      word = "";
      return false;
    };
    let i = 0;
    while (i < pend.length) {
      const u = unitAt(pend, i);
      if ("open" in u) {
        if (!last) break;
        i = pend.length;
        if (run < 0) safe = i;
        break;
      }
      if (u.ch !== undefined && TOKEN_CHAR.test(u.ch)) {
        if (run < 0) {
          run = i;
          runCol = col;
        }
        word += u.ch;
      } else if (!(run >= 0 && u.ch === undefined && !u.row && !u.jump)) {
        if (close()) return;
        if (u.ch !== undefined) remember(u.ch);
        else if (u.row || u.jump) remember(" ");
      }
      col = u.col(col);
      i = u.end;
      if (run < 0) {
        safe = i;
        safeCol = col;
      }
    }
    if (last && close()) return;
    if (last) safe = pend.length;
    if (safe > 0) show(pend.slice(0, safe));
    pend = pend.slice(safe);
    pendCol = safeCol;
  };

  const settle = (raw: string, col0: number) => {
    const seen = flatten(raw, col0);
    const found: { value: string; at: number[]; sure: boolean }[] = [];
    const taken = new Set<number>();
    for (let i = 0; i < seen.length; i++) {
      if (taken.has(i) || !headAt(seen, i)) continue;
      const t = readToken(seen, i, cols);
      for (const k of t.at) taken.add(k);
      found.push(t);
    }
    const good = found.length > 0 && found.every((t) => t.sure && TOKEN_FORM.test(t.value) && endMarked(seen, t.at[t.at.length - 1])) && !strayTokenLine(seen, taken);
    const values = [...new Set(found.map((t) => t.value))];
    if (good && values.length === 1) token = new Secret(values[0]);
    if (good && values.length > 1) conflict = true;
    if (!good) return;
    if (noticed) {
      if (token) show(`${MASKED}\r\n`);
      return;
    }
    // 토큰 글자를 빼고 첫 자리에 MASKED. escape·줄바꿈·들여쓰기는 남겨 자식이 그린 줄 수를 지킨다.
    const drop = new Map<number, { b: number; first: boolean }>();
    for (const t of found) t.at.forEach((k, n) => drop.set((seen[k] as { a: number }).a, { b: (seen[k] as { b: number }).b, first: n === 0 }));
    let out = "";
    for (let i = 0; i < raw.length; ) {
      const d = drop.get(i);
      if (d) {
        if (d.first) out += MASKED;
        i = d.b;
      } else out += raw[i++];
    }
    const flat = flatVisible(out);
    const leaks = flat.includes(HEAD) || values.some((v) => {
      const secret = v.slice(HEAD.length);
      for (let k = 0; k + LEAK_WINDOW <= secret.length; k++) if (flat.includes(secret.slice(k, k + LEAK_WINDOW))) return true;
      return false;
    });
    show(leaks ? (token ? `${MASKED}\r\n` : "") : out);
  };

  return {
    push(chunk) {
      if (ended) return;
      if (held) held.raw += chunk;
      else {
        pend += chunk;
        scan(false);
      }
    },
    end() {
      if (ended) return;
      if (!held) scan(true);
      ended = true;
      const h = held as { raw: string; col: number } | null;
      if (h) settle(h.raw, h.col);
      if (held) held.raw = "";
      pend = "";
    },
    result: () => ({ token, conflict, hidden: held !== null }),
    holding: () => held !== null && !ended,
    notice(text) {
      if (held === null || ended || noticed) return;
      noticed = true;
      show(`\r\n${text}\r\n`);
    },
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
