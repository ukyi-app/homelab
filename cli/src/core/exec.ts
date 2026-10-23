// 외부 명령 seam. cli/src에서 프로세스를 띄우는 곳은 여기 하나다(정적 시험이 다른 곳의 spawn·fetch를 막는다).
// 네트워크도 gh·curl 같은 도구로만 나가게 해 PATH 스텁 시험이 모든 바깥 호출을 본다(L50).
// seam은 재시도하지 않는다. 변이 호출의 타임아웃은 "실패"가 아니라 "결과 미상"이고 재시도는 두 번 실행이다(B.8 E7).
// 엔진이 상태를 다시 읽어 이어 간다.
//
// 안전 계약(02~04가 우회할 수 없어야 한다, #873 1라운드):
// - 쓰기는 apply 모드에서 엔진이 Step.apply()를 도는 동안(runWithWrites 창)에만 실행한다. read()·단계 준비·
//   타임아웃 뒤 재조회는 apply 모드여도 읽기 전용이다. 창을 여는 함수는 engine.ts·main.ts만 쓴다(정적 시험).
// - 직접 stdio(inherit, stdout-to-stderr)는 github 위임 명령만. 그 밖의 명령 출력은 모두 출력 계층을 거친다.
// - 값을 내는 호출(kubectl Secret 조회, infisical secrets 조회·토큰, gh auth token)은 secretStdout으로만 실행한다.
// - 민감 호출(secretStdout, Secret stdin, 값을 내는 호출)의 stderr 원문은 돌려주지 않는다. 오류에 값이 실릴 수 있다.
import { basename } from "node:path";
import { Secret, containsTracked, isSecret } from "./secret";
import type { Mode } from "./result";
import { classify } from "./writes";

export type ExecOpts = {
  input?: string | Secret;
  timeoutMs?: number;
  cwd?: string;
  // inherit: 래퍼의 대화형 질문을 사람이 직접 받는다. stdout-to-stderr: --json일 때 stdout을 지키고 stdin은 넘긴다. 둘 다 delegate만.
  stdio?: "pipe" | "inherit" | "stdout-to-stderr";
  // stdout을 Secret으로만 돌려준다.
  secretStdout?: boolean;
  // 자식 환경에 더하거나 지울 값(undefined면 지움).
  env?: Record<string, string | undefined>;
};

export type ExecResult = {
  code: number | null;
  stdout: string;
  stdoutSecret?: Secret;
  // 민감 호출이면 빈 문자열이고 stderrHidden이 true다.
  stderr: string;
  stderrHidden?: boolean;
  // stderr에 NotFound·not found가 있었는지. 민감 호출에서도 원문 없이 쓸 수 있게 따로 둔다.
  notFound: boolean;
  errKind?: "not-found" | "timeout" | "spawn";
};

export type Exec = (argv: string[], opts?: ExecOpts) => ExecResult;

// 쓰기 호출을 막았을 때 메시지에 넣는 표지. 시험이 이 글자를 찾는다.
export const PLAN_WRITE_BLOCKED = "plan-write-blocked";

const READ_TIMEOUT_MS = 30_000;
const WRITE_TIMEOUT_MS = 120_000;
const MAX_ERR = 2_000;

// 쓰기 창. 엔진이 Step.apply()를 await하는 동안만 0보다 크다.
let writeDepth = 0;

export async function runWithWrites<T>(fn: () => Promise<T>): Promise<T> {
  writeDepth++;
  try {
    return await fn();
  } finally {
    writeDepth--;
  }
}

function timeoutFor(write: boolean, env: Record<string, string | undefined>, asked?: number): number {
  const base = asked ?? (write ? WRITE_TIMEOUT_MS : READ_TIMEOUT_MS);
  // 시험 전용: 타임아웃 주입 시험이 기다리지 않게 상한을 낮춘다.
  const cap = Number(env.HOMELAB_TEST_TIMEOUT_MS);
  return Number.isFinite(cap) && cap > 0 ? Math.min(base, cap) : base;
}

// 함정(옛 tools/lib/exec.ts 실측): git hook 안에서 CLI를 띄우면 GIT_DIR·GIT_WORK_TREE·GIT_INDEX_FILE이 상속돼
// git -C <다른 곳>이 hook의 저장소를 본다. 자격이 없으면 프롬프트에서 멈추므로 GIT_TERMINAL_PROMPT=0.
// 판정은 basename이다. /usr/bin/git처럼 절대 경로로 불러도 같다(쓰기 판정 classify와 같은 기준).
function childEnv(argv0: string, base: Record<string, string | undefined>, extra?: Record<string, string | undefined>): Record<string, string> {
  const env: Record<string, string | undefined> = { ...base, ...extra };
  if (basename(argv0) === "git") {
    delete env.GIT_DIR;
    delete env.GIT_WORK_TREE;
    delete env.GIT_INDEX_FILE;
    env.GIT_TERMINAL_PROMPT = "0";
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) out[k] = v;
  return out;
}

export function makeExec(mode: Mode, delegate: boolean, env: Record<string, string | undefined>): Exec {
  return (argv, opts = {}) => {
    if (argv.length === 0) throw new Error("빈 argv");
    for (const a of argv) {
      if (containsTracked(a)) throw new Error(`시크릿 값을 명령행 인자로 넘기려 했다: ${basename(argv[0])}(값은 stdin으로만 넘긴다)`);
      if (a.includes("\0")) throw new Error(`NUL이 든 인자: ${basename(argv[0])}`);
    }
    const verdict = classify(argv);
    if (verdict.write) {
      const open = mode === "apply" && writeDepth > 0;
      // github apply(delegate)는 래퍼 하나만 쓰기로 허용한다.
      const target = !delegate || basename(argv[0]) === "tf-github.sh";
      if (!open || !target) {
        const where = mode !== "apply" ? `${mode} 모드` : writeDepth === 0 ? "apply 모드의 읽기 단계(Step.apply 밖)" : "github 위임 명령의 래퍼 밖";
        throw new Error(`${PLAN_WRITE_BLOCKED}: ${where}에서 쓰기 호출을 막았다(${verdict.reason})`);
      }
    }
    if (verdict.sensitiveOutput && !opts.secretStdout) throw new Error(`값을 내는 호출은 secretStdout으로만 실행한다: ${verdict.reason}`);
    const stdio = opts.stdio ?? "pipe";
    if (stdio !== "pipe") {
      if (!delegate) throw new Error(`stdio ${stdio}는 github 위임 명령만 쓴다(출력 계층을 거치지 않는다)`);
      if (opts.secretStdout || isSecret(opts.input)) throw new Error(`stdio ${stdio}에 시크릿 입출력을 함께 쓰지 않는다`);
    }
    const sensitive = Boolean(opts.secretStdout) || isSecret(opts.input) || verdict.sensitiveOutput;
    const input = opts.input === undefined ? undefined : isSecret(opts.input) ? opts.input.reveal() : opts.input;
    // 입력을 따로 주지 않은 위임 명령은 부모 stdin을 넘긴다(래퍼가 묻는 값과 마지막 yes를 사람이 직접 답한다).
    const stdin = input !== undefined ? new TextEncoder().encode(input) : stdio !== "pipe" ? "inherit" : "ignore";
    let p: ReturnType<typeof Bun.spawnSync>;
    try {
      p = Bun.spawnSync(argv, {
        cwd: opts.cwd,
        env: childEnv(argv[0], env, opts.env),
        stdin,
        stdout: stdio === "pipe" ? "pipe" : stdio === "inherit" ? "inherit" : 2,
        stderr: stdio === "pipe" ? "pipe" : "inherit",
        timeout: timeoutFor(verdict.write, env, opts.timeoutMs),
      } as Parameters<typeof Bun.spawnSync>[1]);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      return { code: null, stdout: "", stderr: sensitive ? "" : (e as Error).message, stderrHidden: sensitive || undefined, notFound: false, errKind: code === "ENOENT" ? "not-found" : "spawn" };
    }
    const stdoutText = p.stdout ? p.stdout.toString() : "";
    const rawErr = p.stderr ? p.stderr.toString() : "";
    // 자식이 죽기 전에 쓴 stderr가 원인의 유일한 단서일 때가 많다. 민감 호출이 아니면 앞부분만 남긴다.
    const result: ExecResult = {
      code: p.exitCode,
      stdout: opts.secretStdout ? "" : stdoutText,
      stderr: sensitive ? "" : rawErr.trim().slice(0, MAX_ERR),
      notFound: /NotFound|not found/i.test(rawErr),
    };
    if (sensitive) result.stderrHidden = true;
    if (opts.secretStdout) result.stdoutSecret = new Secret(stdoutText);
    if ((p as { exitedDueToTimeout?: boolean }).exitedDueToTimeout) result.errKind = "timeout";
    return result;
  };
}

// 결과 해석에 쓰는 짧은 원인 한 줄.
export function why(r: ExecResult): string {
  if (r.errKind === "not-found") return "명령이 없다";
  if (r.errKind === "timeout") return "시간 초과(결과 미상)";
  if (r.stderrHidden) return `exit ${r.code}(값이 실릴 수 있는 호출이라 오류 원문을 버렸다)`;
  const line = r.stderr.split("\n").find((l) => /^(error|fatal|gh:|Error)/i.test(l.trim())) ?? r.stderr.split("\n")[0] ?? "";
  return `exit ${r.code}${line ? `: ${line.trim()}` : ""}`;
}

export class ExecTimeout extends Error {}

// 실패면 던진다. 타임아웃은 ExecTimeout(엔진이 재조회로 처리).
export function must(r: ExecResult, what: string): ExecResult {
  if (r.errKind === "timeout") throw new ExecTimeout(`${what}: 시간 초과(결과 미상)`);
  if (r.code !== 0) throw new Error(`${what}: ${why(r)}`);
  return r;
}
