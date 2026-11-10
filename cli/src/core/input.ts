// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { readFileSync, readSync } from "node:fs";
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
export function readSetupTokens(isTTY: boolean, ask: (q: string) => void, lanes: string[], login: (lane: string) => void): Secret[] {
  const raws: string[] = [];
  if (isTTY) {
    for (const lane of lanes) {
      login(lane);
      ask(`${lane} 레인 토큰(화면에 보이지 않는다): `);
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
    if (problem) throw new Error(`${lanes[i]} 레인 토큰: ${problem}`);
    return value;
  });
  if (values.some((v, i) => values.slice(i + 1).some((w) => v.equals(w)))) throw new Error("레인마다 다른 토큰이어야 한다(setup-token을 레인마다 따로 실행한다)");
  return values;
}

// tty에서 레인 하나의 브라우저 로그인. claude가 이 기기에 있어야 한다(봇 파드가 아니라 CLI를 돌리는 기기).
export function setupTokenLogin(exec: Exec, lane: string, progress: (line: string) => void): void {
  progress(`${lane} 레인: claude setup-token을 띄운다. 브라우저에서 봇 계정으로 로그인하고, 끝나면 화면에 나온 토큰을 복사해 다음 입력에 붙여 넣는다`);
  // 브라우저 로그인을 사람이 끝낼 때까지 기다린다(10분).
  const r = exec(["claude", "setup-token"], { stdio: "inherit", timeoutMs: 600_000 });
  if (r.errKind === "not-found") throw new CliError("claude(Claude Code CLI)가 이 기기의 PATH에 없다", "Claude Code CLI를 설치한 기기에서 다시 실행한다(토큰은 이 기기에서 받는다)");
  if (r.errKind === "timeout") throw new CliError("claude setup-token: 10분 안에 끝나지 않았다", "같은 명령을 다시 실행한다");
  if (r.code !== 0) throw new CliError(`claude setup-token이 실패했다(exit ${r.code ?? r.signal ?? "?"})`, "브라우저 로그인을 마친 뒤 같은 명령을 다시 실행한다");
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
