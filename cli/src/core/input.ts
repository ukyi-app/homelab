// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정 2026-10-23).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { readFileSync, readSync } from "node:fs";
import { valueProblem } from "./infisical";
import { Secret } from "./secret";

// 에코 없는 tty 한 줄. 바이트를 Enter까지 모은 뒤 UTF-8로 한 번만 디코딩한다(fatal). 함정(#873 3라운드):
// 1바이트마다 디코딩하면 한글·이모지가 바이트마다 U+FFFD가 되어 입력과 다른 값이 저장되고 길이 검사도 틀린다.
export function readHiddenLine(readByte: () => number | null): string {
  const bytes: number[] = [];
  for (;;) {
    const b = readByte();
    // Enter는 raw 모드에서 \r(0x0d)로 온다. Ctrl-C(0x03)는 취소.
    if (b === null || b === 0x0d || b === 0x0a) break;
    if (b === 0x03) throw new Error("입력을 취소했다");
    // Backspace(0x08)·Delete(0x7f)는 직전 UTF-8 문자 하나를 지운다(Connector 4360754443). 이어지는 바이트(10xxxxxx)까지 함께 뺀다.
    if (b === 0x08 || b === 0x7f) {
      while (bytes.length > 0 && ((bytes.pop() as number) & 0xc0) === 0x80);
      continue;
    }
    bytes.push(b);
  }
  try {
    // ignoreBOM: 기본 디코더는 선두 U+FEFF를 지워 다른 값을 받아들인다. 그대로 두고 valueProblem이 판단한다(codex 확인 라운드).
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
