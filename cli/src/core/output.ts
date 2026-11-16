// 출력 계층. stdout·stderr에 쓰는 곳은 이 파일 하나다(정적 시험이 다른 곳의 console·process.stdout을 막는다).
// stdout에는 결과 하나만(사람용 또는 JSON 문서 하나), 진행 줄과 경고는 stderr.
// 시크릿 차단 두 겹: Result 안에 Secret 객체가 있으면 렌더하지 않고, 렌더한 글자에 추적 중인 원문이 있으면 내보내지 않는다.
import { log, outro } from "@clack/prompts";
import type { Writable } from "node:stream";
import { jsonStringify } from "./intrinsics";
import { findSecretPath } from "./guard";
import { containsTracked } from "./secret";
import type { Result, StepResult } from "./result";

export const SCHEMA = "homelab-cli/v1";

export class OutputBlocked extends Error {}

// 어느 단계가 값을 섞었는지만 알려 준다(값은 찍지 않는다).
export function secretProblem(r: Result): string | null {
  const obj = findSecretPath(r, "result");
  if (obj) return `${obj}에 시크릿 객체가 있다`;
  for (const s of r.steps) if (containsTracked(jsonStringify(s))) return `단계 ${s.id}`;
  const rest = jsonStringify({ ...r, steps: [] });
  return containsTracked(rest) ? "단계 밖(notes·next·error)" : null;
}

// 바깥 입력(앱 로그)을 그대로 터미널에 내면 escape 문자로 화면·클립보드를 조작할 수 있다. 줄바꿈·탭 밖의 C0·DEL·C1은
// \x1b 꼴 글자로 바꾼다(JSON에도 같은 값을 둔다. 사람이 jq -r로 볼 때도 같다).
export function safeBody(text: string): string {
  return text.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, "0")}`);
}

export function renderJson(r: Result): string {
  const doc: Record<string, unknown> = { schema: SCHEMA, command: r.command };
  if (r.app !== undefined) doc.app = r.app;
  doc.mode = r.mode;
  doc.status = r.status;
  doc.steps = r.steps;
  if (r.body !== undefined) doc.body = safeBody(r.body);
  doc.notes = r.notes;
  doc.next = r.next;
  if (r.error) doc.error = r.error;
  if (r.exitCode !== undefined) doc.exitCode = r.exitCode;
  return jsonStringify(doc) + "\n";
}

// 한글·CJK는 터미널에서 두 칸이다. 열 맞춤에 쓴다.
function width(s: string): number {
  let w = 0;
  for (const ch of s) w += /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/.test(ch) ? 2 : 1;
  return w;
}

const SUFFIX: Partial<Record<StepResult, string>> = { skipped: "건너뜀", applied: "했다", waiting: "대기", failed: "실패", "not-run": "안 함" };

export function renderHuman(r: Result): string {
  const lines: string[] = [];
  const head = r.title ?? (r.mode === "plan" ? "계획 (아무것도 바꾸지 않았다)" : r.mode === "apply" ? "실행" : `homelab ${r.command}${r.app ? ` ${r.app}` : ""}`);
  lines.push(head);
  const col = Math.max(0, ...r.steps.map((s) => width(s.target)));
  const num = String(r.steps.length).length;
  r.steps.forEach((s, i) => {
    // plan은 결과가 없고, 읽기 명령은 실패만 표시한다.
    const label = r.mode === "apply" || (r.mode === "read" && s.result === "failed") ? SUFFIX[s.result] : undefined;
    lines.push(`  ${String(i + 1).padStart(num)} ${s.target}${" ".repeat(col - width(s.target))}   ${s.detail}${label ? ` (${label})` : ""}`);
  });
  if (r.body !== undefined) {
    const b = safeBody(r.body);
    lines.push(b.endsWith("\n") ? b.slice(0, -1) : b);
  }
  for (const n of r.notes) lines.push(`주의: ${n}`);
  if (r.error) lines.push(`실패: ${r.error.message}`);
  lines.push(`다음: ${r.next ?? "없음"}`);
  return lines.join("\n") + "\n";
}

// clack 글 꼴을 문자열로 받는다. clack은 output에 바로 쓰므로 모았다가 이 계층의 writeStdout·writeStderr로 낸다
// (추적 중인 값 검사를 거치게). 색은 clack이 사람 터미널일 때만 넣는다.
function clackText(draw: (output: Writable) => void): string {
  let text = "";
  const out = { write: (s: string) => ((text += s), true), columns: screenSize().cols, isTTY: true, on: () => out, off: () => out };
  draw(out as unknown as Writable);
  return text;
}

// 터미널 요약의 진행 줄 하나(stderr).
export function stepLine(text: string): string {
  return clackText((output) => log.step(safeBody(text), { output }));
}

// 터미널 요약(Result.summary). 머리 한 줄과 몇 줄, 끝에 다음 행동. 실패면 실패 표시로 그린다.
export function renderSummary(r: Result): string {
  const s = r.summary!;
  const message = [s.head, ...s.lines].map(safeBody).join("\n");
  return clackText((output) => {
    const draw = r.status === "failed" ? log.error : r.status === "pending" ? log.info : r.status === "waiting" ? log.warn : log.success;
    draw(message, { output });
    if (s.next) outro(safeBody(`다음: ${s.next}`), { output });
  });
}

export function render(r: Result, json: boolean): string {
  const problem = secretProblem(r);
  if (problem) throw new OutputBlocked(`출력에 시크릿 값이 섞여 막았다(${problem})`);
  const text = json ? renderJson(r) : r.summary ? renderSummary(r) : renderHuman(r);
  if (containsTracked(text)) throw new OutputBlocked("출력에 시크릿 값이 섞여 막았다");
  return text;
}

export function writeStdout(text: string): void {
  if (containsTracked(text)) throw new OutputBlocked("출력에 시크릿 값이 섞여 막았다");
  stopActivity(true);
  process.stdout.write(text);
}

export function writeStderr(text: string): void {
  stopActivity(true);
  process.stderr.write(containsTracked(text) ? "진행 줄에 시크릿 값이 섞여 뺐다\n" : text);
}

// 터미널 요약의 움직이는 진행 줄. 함정: CLI의 쓰기·기다림은 모두 동기 호출(spawnSync·sleepSync)이라 그동안 이벤트 루프가 멈춘다.
// 그래서 그림은 Worker 스레드가 그리고, 메인 스레드는 멈춤을 Atomics로 알린 뒤 Worker가 손을 뗄 때까지 기다린다(그 뒤에 쓴 글이
// 프레임에 덮이지 않게). clack spinner를 쓰지 않는 이유: 같은 까닭으로 멈춰 보이고, stdin을 raw로 두어 Ctrl-C를 받으면
// process.exit(0)으로 끝낸다(쓰기 도중 성공 종료 코드). 이 진행 줄은 raw 모드·커서 숨김·신호 처리기를 두지 않는다. Ctrl-C는 지금처럼
// 프로세스를 바로 끝내고, 커서는 늘 진행 줄 아래 새 줄에 있어(줄을 쓴 뒤 줄바꿈, 다음 프레임은 한 줄 올라가 그 줄만 다시 쓴다)
// 셸 프롬프트가 깨끗한 줄에서 시작한다. 진행 줄 문구는 고정 문구뿐이고 값 검사를 거친다.
const FRAMES = ["◒", "◐", "◓", "◑"];
const FRAME_MS = 80;
const SPINNER_SRC = `self.onmessage = ({ data }) => {
  const st = new Int32Array(data.sab);
  let i = 1;
  while (Atomics.wait(st, 0, 1, ${FRAME_MS}) === "timed-out") process.stderr.write("\\x1b[1A\\r\\x1b[K" + data.frames[i++ % data.frames.length] + "  " + data.label + "\\n");
  Atomics.store(st, 0, 3);
  Atomics.notify(st, 0);
};`;
let spinnerUrl: string | undefined;
let active: { st: Int32Array; worker: Worker; label: string; done: string } | null = null;

// 진행 줄을 열 수 안에 둔다. 접히면 한 줄 위로 올라가 다시 쓰기가 다른 줄을 지운다.
function fitLine(text: string): string {
  const room = Math.max(10, screenSize().cols - 4);
  let out = "";
  for (const ch of text) {
    if (width(out + ch) > room) return `${out}…`;
    out += ch;
  }
  return out;
}

// 움직이는 진행 줄을 연다(앞 줄은 끝난 표시로 닫는다). stderr가 터미널이 아니면 열지 않고 false: 부르는 쪽이 지금의 진행 줄을 쓴다.
export function startActivity(text: string): boolean {
  stopActivity(true);
  if (!process.stderr.isTTY) return false;
  const label = fitLine(safeBody(text));
  if (containsTracked(label)) return false;
  const done = stepLine(label);
  const bar = done.slice(0, done.indexOf("\n") + 1);
  const st = new Int32Array(new SharedArrayBuffer(4));
  st[0] = 1;
  let worker: Worker;
  try {
    spinnerUrl ??= URL.createObjectURL(new Blob([SPINNER_SRC], { type: "application/javascript" }));
    worker = new Worker(spinnerUrl);
  } catch {
    // 진행 줄 때문에 명령이 깨지지 않게 한다. 부르는 쪽이 움직이지 않는 진행 줄을 쓴다.
    return false;
  }
  process.stderr.write(`${bar}${FRAMES[0]}  ${label}\n`);
  // 진행 줄이 열린 채 명령이 끝나도 프로세스가 Worker를 기다리지 않는다.
  worker.unref();
  worker.postMessage({ sab: st.buffer, frames: FRAMES, label });
  active = { st, worker, label, done: done.slice(bar.length) };
  return true;
}

// 움직이는 진행 줄을 닫고 그 자리에 끝난 표시(ok) 또는 실패 표시를 남긴다. 열린 줄이 없으면 아무것도 하지 않는다.
export function stopActivity(ok: boolean): void {
  if (!active) return;
  const a = active;
  active = null;
  Atomics.store(a.st, 0, 2);
  Atomics.notify(a.st, 0);
  // Worker가 아직 뜨지 않았어도 뜨자마자 손을 뗀다. 오래 걸려도 1초 뒤에는 그냥 덮어쓴다.
  Atomics.wait(a.st, 0, 2, 1_000);
  a.worker.terminate();
  process.stderr.write(`\x1b[1A\r\x1b[K${ok ? a.done : `▲  ${a.label}\n`}`);
}

// 결과(stdout)가 사람 터미널로 가는지. 터미널 요약은 이때만 쓴다(파일·파이프는 지금의 단계 표).
export function stdoutIsTerminal(): boolean {
  return Boolean(process.stdout.isTTY);
}

// 도움말 화면의 색·폭. 그 글이 가는 곳(stdout·stderr)이 사람 터미널일 때만 색을 넣고 그 폭에 맞춘다(100칸에서 멈춘다:
// 넓은 창에서 한 줄이 너무 길면 읽기 어렵다). 파이프·파일은 80칸 글자만. NO_COLOR(값이 있으면)·TERM=dumb면 색을 뺀다.
export function helpStyle(env: Record<string, string | undefined>, to: "stdout" | "stderr"): { color: boolean; cols: number } {
  const s = to === "stdout" ? process.stdout : process.stderr;
  const tty = Boolean(s.isTTY);
  return { color: tty && !env.NO_COLOR && env.TERM !== "dumb", cols: tty && s.columns ? Math.min(s.columns, 100) : 80 };
}

// 사람 터미널(stderr) 크기. 가짜 터미널 로그인이 자식 화면 크기를 정할 때 쓴다.
export function screenSize(): { cols: number; rows: number } {
  return { cols: process.stderr.columns ?? 80, rows: process.stderr.rows ?? 24 };
}

// clack 입력 화면이 쓸 출력. stderr로 가되 writeStderr를 거친다(추적 중인 값이 섞인 글은 내보내지 않는다).
// clack은 열 수로 글을 접고 resize 이벤트를 듣는다. 이벤트는 받지 않아도 된다(다시 그릴 때 열 수를 다시 읽는다).
export function promptOutput(): Writable {
  const out = {
    write: (chunk: string | Uint8Array) => (writeStderr(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk)), true),
    get columns() {
      return process.stderr.columns ?? 80;
    },
    get rows() {
      return process.stderr.rows ?? 24;
    },
    isTTY: Boolean(process.stderr.isTTY),
    on: () => out,
    off: () => out,
    once: () => out,
    removeListener: () => out,
  };
  return out as unknown as Writable;
}
