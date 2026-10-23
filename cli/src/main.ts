// homelab CLI 진입점(설계 C.7). argv → 등록 표 → 파싱 → 실행 → 출력 → 종료 코드(PLAN D2).
// 첫 import는 intrinsics다(명령 모듈이 평가되기 전에 내장 함수를 잡는다, 정적 시험).
import "./core/intrinsics";
import { readSync } from "node:fs";
import { APPLY_FLAG, GLOBAL_FLAGS, parseInput, usageLine } from "./core/args";
import type { CommandSpec } from "./core/command";
import { OutputBlocked, render, writeStderr, writeStdout } from "./core/output";
import { CliError, EXIT, UsageError, type Mode, type Result } from "./core/result";
import { makeRuntime } from "./core/runtime";
import { versionLine } from "./core/version";
import { REGISTRY } from "./registry";

function findCommand(argv: string[]): CommandSpec | undefined {
  let best: CommandSpec | undefined;
  for (const c of REGISTRY) {
    if (c.path.every((p, i) => argv[i] === p) && (!best || c.path.length > best.path.length)) best = c;
  }
  return best;
}

function quote(t: string): string {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(t) ? t : `'${t.replaceAll("'", `'\\''`)}'`;
}

function flagsOf(c: CommandSpec) {
  return [...c.flags, ...(c.kind === "change" ? [APPLY_FLAG] : []), ...GLOBAL_FLAGS];
}

function overview(): string {
  const lines = ["사용법: homelab <명령> [인자] [--apply] [--json]", "", "명령:"];
  for (const c of REGISTRY) lines.push(`  ${usageLine(c.path, c.args, c.flags).slice("homelab ".length).padEnd(70)} ${c.summary}${c.placeholder ? ` (아직 구현 전, ${c.placeholder})` : ""}`);
  lines.push("", "바꾸는 명령은 기본이 plan(아무것도 바꾸지 않음)이고 --apply로 실행한다.", "종료 코드: 0 완료·변경 없음·plan, 1 실패, 3 대기(PR 병합·동기화), 64 사용법 오류. github 하위 명령은 래퍼 코드 그대로.");
  return lines.join("\n") + "\n";
}

// tty에서 한 줄 읽는다. 질문은 stderr로(stdout은 결과 자리).
function ask(question: string): string | null {
  writeStderr(question);
  const buf = Buffer.alloc(1);
  let line = "";
  for (;;) {
    let n = 0;
    try {
      n = readSync(0, buf, 0, 1, null);
    } catch {
      return null;
    }
    if (n === 0) return line.length > 0 ? line : null;
    const ch = buf.toString("utf8");
    if (ch === "\n") return line.replace(/\r$/, "");
    line += ch;
  }
}

function usageResult(command: string, message: string, usage: string): Result {
  return { command, mode: "read", status: "usage", steps: [], notes: [], next: usage, error: { message, next: usage } };
}

function emit(result: Result, json: boolean): void {
  try {
    writeStdout(render(result, json));
  } catch (e) {
    if (!(e instanceof OutputBlocked)) throw e;
    // 값이 섞인 결과는 버리고 무엇이 막혔는지만 낸다.
    const blocked: Result = { command: result.command, app: result.app, mode: result.mode, status: "failed", steps: [], notes: [], next: null, error: { message: e.message, next: "버그다. 이 출력과 명령줄(값 없이)을 남기고 알린다" } };
    writeStdout(render(blocked, json));
    result.status = "failed";
    result.exitCode = undefined;
  }
}

async function main(argv: string[]): Promise<number> {
  const json = argv.includes("--json");
  if (argv.length === 1 && argv[0] === "--version") {
    writeStdout(`${versionLine()}\n`);
    return 0;
  }
  if (argv.length === 0 || (argv.length === 1 && (argv[0] === "--help" || argv[0] === "-h"))) {
    writeStdout(overview());
    return argv.length === 0 ? EXIT.usage : 0;
  }
  const cmd = findCommand(argv);
  if (!cmd) {
    // 명령줄을 되찍지 않는다(뒤에 값이 있을 수 있다). 등록 표에 있는 첫 단어만 보인다.
    const first = argv.find((a) => !a.startsWith("-")) ?? "";
    const head = REGISTRY.some((c) => c.path[0] === first) ? first : "(모르는 단어)";
    const r = usageResult(head, `모르는 명령: ${head}`, "homelab --help");
    if (json) emit(r, true);
    else writeStderr(`사용법 오류: ${r.error!.message}\n${overview()}`);
    return EXIT.usage;
  }
  const command = cmd.path.join(" ");
  const usage = usageLine(cmd.path, cmd.args, flagsOf(cmd));
  let input;
  try {
    input = parseInput(flagsOf(cmd), cmd.args, argv.slice(cmd.path.length));
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    if (json) emit(usageResult(command, e.message, usage), true);
    else writeStderr(`사용법 오류: ${e.message}\n${usage}\n`);
    return EXIT.usage;
  }
  if (input.help) {
    writeStdout(`${usage}\n  ${cmd.summary}\n`);
    return 0;
  }

  const mode: Mode = cmd.kind === "change" ? (input.apply ? "apply" : "plan") : cmd.kind === "delegate" && cmd.delegateMode === "apply" ? "apply" : "read";
  const line = ["homelab", ...argv.filter((a) => a !== "--json")].map(quote).join(" ");
  const ctx = makeRuntime({ mode, json, line, env: { ...process.env }, isTTY: Boolean(process.stdin.isTTY), ask, progress: (l) => writeStderr(`${l}\n`), delegate: cmd.kind === "delegate" });

  let result: Result;
  try {
    result = await cmd.run(ctx, input);
  } catch (e) {
    if (e instanceof UsageError) {
      if (json) emit(usageResult(command, e.message, usage), true);
      else writeStderr(`사용법 오류: ${e.message}\n${usage}\n`);
      return EXIT.usage;
    }
    const next = e instanceof CliError ? e.next : `원인을 고친 뒤 다시: ${line}`;
    result = { command, mode, status: "failed", steps: [], notes: [], next, error: { message: (e as Error).message, next } };
  }
  if (result.exitCode !== undefined && cmd.kind !== "delegate") {
    result = { ...result, status: "failed", exitCode: undefined, error: { message: "exitCode는 github 하위 명령만 쓴다", next: "버그다. 명령 파일을 고친다" } };
  }
  emit(result, json);
  if (cmd.kind === "delegate" && result.exitCode !== undefined) return result.exitCode;
  return EXIT[result.status];
}

// process.exit()를 부르지 않는다. 파이프·느린 소비자로 낸 출력이 비워지기 전에 끝나 잘린다(Bun 1.4.3 실측: 4MB 중 64KB만 도착).
// exitCode만 두면 이벤트 루프가 stdout·stderr를 비운 뒤 끝난다(Connector 4360396737).
process.exitCode = await main(process.argv.slice(2));
