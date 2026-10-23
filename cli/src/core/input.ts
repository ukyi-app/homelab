// 시크릿 입력(secret set의 값 등). 파이프면 stdin 전체, tty면 에코 없이 한 줄. 16자 이상만(사용자 결정 2026-10-23).
// 쓰기 문맥(Step.apply)에서만 부른다. 값은 곧바로 Secret이 되고 출력·argv·파일에 가지 않는다.
import { readFileSync, readSync } from "node:fs";
import { valueProblem } from "./infisical";
import { Secret } from "./secret";

function readTtyHidden(): string {
  const stdin = process.stdin as unknown as { setRawMode?: (on: boolean) => void };
  stdin.setRawMode?.(true);
  try {
    const buf = Buffer.alloc(1);
    let line = "";
    for (;;) {
      const n = readSync(0, buf, 0, 1, null);
      if (n === 0) return line;
      const ch = buf.toString("utf8");
      // Enter는 raw 모드에서 \r로 온다. Ctrl-C(\x03)는 취소.
      if (ch === "\r" || ch === "\n") return line;
      if (ch === "\x03") throw new Error("입력을 취소했다");
      line += ch;
    }
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
