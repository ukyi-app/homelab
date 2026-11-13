// homelab CLI 진입점(설계 C.7). argv → 등록 표 → 파싱 → 실행 → 출력 → 종료 코드.
// 첫 import는 intrinsics다(명령 모듈이 평가되기 전에 내장 함수를 잡는다, 정적 시험).
import "./core/intrinsics";
import { readSync } from "node:fs";
import { parseInput, usageLine } from "./core/args";
import type { CommandSpec } from "./core/command";
import { allFlags, closest, commandJson, groupJson, overviewJson, renderCommand, renderGroup, renderOverview, shortUsage } from "./core/help";
import { helpStyle, OutputBlocked, render, stdoutIsTerminal, stepLine, writeStderr, writeStdout } from "./core/output";
import { CliError, EXIT, UsageError, type Mode, type Result } from "./core/result";
import { makeRuntime } from "./core/runtime";
import { versionLine } from "./core/version";
import { REGISTRY, SECTIONS } from "./registry";

function findCommand(argv: string[]): CommandSpec | undefined {
  let best: CommandSpec | undefined;
  for (const c of REGISTRY) {
    if (c.path.every((p, i) => argv[i] === p) && (!best || c.path.length > best.path.length)) best = c;
  }
  return best;
}

const isHelp = (a: string) => a === "-h" || a === "--help";
const startsWith = (path: string[], prefix: string[]) => prefix.every((w, i) => path[i] === w);
// prefix 아래의 명령(prefix 자신은 빼고).
const under = (prefix: string[]) => REGISTRY.filter((c) => c.path.length > prefix.length && startsWith(c.path, prefix));
function leadingWords(argv: string[]): string[] {
  const i = argv.findIndex((a) => a.startsWith("-"));
  return i === -1 ? argv : argv.slice(0, i);
}

// argv 앞 낱말 중 등록된 명령 경로의 접두사(묶음)가 되는 가장 긴 것. app, db, bot account 같은 것이다.
function groupOf(argv: string[]): string[] {
  const words = leadingWords(argv);
  let best: string[] = [];
  for (let n = 1; n <= words.length; n++) if (under(words.slice(0, n)).length > 0) best = words.slice(0, n);
  return best;
}

function quote(t: string): string {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(t) ? t : `'${t.replaceAll("'", `'\\''`)}'`;
}

// 사람용 사용법 오류. 긴 사용법 한 줄 대신 짧은 꼴과 도움말 위치를 보인다(--json 결과는 지금 꼴 그대로).
function usageText(cmd: CommandSpec, message: string): string {
  return `사용법 오류: ${message}\n사용법: ${shortUsage(cmd)}\n자세히: homelab ${cmd.path.join(" ")} -h\n`;
}

// 모르는 명령. 친 말은 되찍지 않고 등록 표의 이름만 권한다(값을 명령 자리에 잘못 넣은 경우 출력에 실린다).
function unknownText(argv: string[], group: string[]): string {
  const typed = leadingWords(argv)[group.length];
  const names = [...new Set(under(group).map((c) => c.path[group.length]))];
  const hit = typed === undefined ? null : closest(typed, names);
  const where = group.length ? `homelab ${group.join(" ")}에 없는 명령입니다` : "모르는 명령입니다";
  const lines = [`사용법 오류: ${where}`];
  if (hit) lines.push(`혹시: homelab ${[...group, hit].join(" ")}`);
  if (group.length) return `${lines.join("\n")}\n\n${renderGroup(group, under(group), helpStyle(process.env, "stderr"))}`;
  lines.push("명령 목록: homelab -h");
  return `${lines.join("\n")}\n`;
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
  if (argv[0] === "help") argv = [...argv.slice(1), "--help"];
  const json = argv.includes("--json");
  const wantsHelp = argv.some(isHelp);
  const out = () => helpStyle(process.env, "stdout");
  if (argv.length === 1 && argv[0] === "--version") {
    writeStdout(`${versionLine()}\n`);
    return 0;
  }
  // 인자 없는 homelab은 같은 화면에 64다(명령을 빠뜨린 스크립트가 성공으로 끝나지 않게).
  if (argv.length === 0) {
    writeStdout(renderOverview(SECTIONS, out()));
    return EXIT.usage;
  }
  const rest = argv.filter((a) => a !== "--json");
  if (rest.length === 1 && isHelp(rest[0]) && argv.length - rest.length <= 1) {
    writeStdout(json ? overviewJson(SECTIONS) : renderOverview(SECTIONS, out()));
    return 0;
  }
  const group = groupOf(argv);
  const found = findCommand(argv);
  // 묶음이 찾은 명령보다 길면(bot account …) 묶음이다. 단 --json 사용법 오류 결과는 도움말을 청하지 않는 한 지금 꼴 그대로 둔다.
  const cmd = found && (found.path.length >= group.length || (json && !wantsHelp)) ? found : undefined;
  if (!cmd) {
    if (group.length > 0 && leadingWords(argv).length === group.length) {
      if (wantsHelp) {
        writeStdout(json ? groupJson(SECTIONS, group, under(group)) : renderGroup(group, under(group), out()));
        return 0;
      }
      // 묶음만 쳤다: 사용법 오류(64)지만 무엇을 칠 수 있는지 보인다.
      if (!json) {
        writeStdout(renderGroup(group, under(group), out()));
        return EXIT.usage;
      }
    }
    // 명령줄을 되찍지 않는다(뒤에 값이 있을 수 있다). 등록 표에 있는 첫 단어만 보인다.
    const first = argv.find((a) => !a.startsWith("-")) ?? "";
    const head = REGISTRY.some((c) => c.path[0] === first) ? first : "(모르는 단어)";
    const r = usageResult(head, `모르는 명령: ${head}`, "homelab --help");
    if (json) emit(r, true);
    else writeStderr(unknownText(argv, group));
    return EXIT.usage;
  }
  const command = cmd.path.join(" ");
  const subs = under(cmd.path);
  // 필수 인자가 있는 명령을 이름만 치면(homelab bot, homelab app add) 사용법 오류 대신 그 명령의 도움말을 보인다. 코드는 64 그대로.
  if (!json && argv.length === cmd.path.length && cmd.args.some((a) => a.required)) {
    writeStdout(renderCommand(cmd, subs, out()));
    return EXIT.usage;
  }
  const usage = usageLine(cmd.path, cmd.args, allFlags(cmd));
  let input;
  try {
    input = parseInput(allFlags(cmd), cmd.args, argv.slice(cmd.path.length));
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    if (json) emit(usageResult(command, e.message, usage), true);
    else writeStderr(usageText(cmd, e.message));
    return EXIT.usage;
  }
  if (input.help) {
    writeStdout(json ? commandJson(SECTIONS, cmd, subs) : renderCommand(cmd, subs, out()));
    return 0;
  }

  const mode: Mode = cmd.kind === "change" ? (input.apply ? "apply" : "plan") : cmd.kind === "delegate" && cmd.delegateMode === "apply" ? "apply" : "read";
  const line = ["homelab", ...argv.filter((a) => a !== "--json")].map(quote).join(" ");
  // 터미널 요약은 결과가 사람 터미널로 갈 때만(stdout). 파일·파이프로 가면 지금의 단계 표 그대로다.
  const summary = cmd.terminalSummary === true && !json && input.flags.verbose !== true && stdoutIsTerminal();
  const progress = summary ? (l: string) => writeStderr(stepLine(l)) : (l: string) => writeStderr(`${l}\n`);
  const ctx = makeRuntime({ mode, json, summary, line, env: { ...process.env }, isTTY: Boolean(process.stdin.isTTY), ask, progress, delegate: cmd.kind === "delegate", wrapper: cmd.wrapper === "plan-json" });

  let result: Result;
  try {
    result = await cmd.run(ctx, input);
  } catch (e) {
    if (e instanceof UsageError) {
      if (json) emit(usageResult(command, e.message, usage), true);
      else writeStderr(usageText(cmd, e.message));
      return EXIT.usage;
    }
    const next = e instanceof CliError ? e.next : `원인을 고친 뒤 다시: ${line}`;
    result = { command, mode, status: "failed", steps: [], notes: [], next, error: { message: (e as Error).message, next } };
    if (summary) result.summary = { head: "실패", lines: [result.error!.message], next };
  }
  if (result.exitCode !== undefined && cmd.kind !== "delegate") {
    result = { ...result, status: "failed", exitCode: undefined, error: { message: "exitCode는 github 하위 명령만 쓴다", next: "버그다. 명령 파일을 고친다" } };
  }
  emit(result, json);
  if (cmd.kind === "delegate" && result.exitCode !== undefined) return result.exitCode;
  return EXIT[result.status];
}

// process.exit()를 부르지 않는다. 파이프·느린 소비자로 낸 출력이 비워지기 전에 끝나 잘린다(Bun 1.4.3 실측: 4MB 중 64KB만 도착).
// exitCode만 두면 이벤트 루프가 stdout·stderr를 비운 뒤 끝난다.
process.exitCode = await main(process.argv.slice(2));
