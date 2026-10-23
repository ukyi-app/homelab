// 외부 명령 seam. cli/src에서 프로세스를 띄우는 곳은 여기 하나다(정적 시험이 다른 곳의 spawn·fetch를 막는다).
// 네트워크도 gh·curl 같은 도구로만 나가게 해 PATH 스텁 시험이 모든 바깥 호출을 본다(L50).
// seam은 재시도하지 않는다. 변이 호출의 타임아웃은 "실패"가 아니라 "결과 미상"이고 재시도는 두 번 실행이다(B.8 E7).
// 엔진이 상태를 다시 읽어 이어 간다.
import { basename } from "node:path";
import { Secret, containsTracked, isSecret } from "./secret";
import type { Mode } from "./result";
import { classify } from "./writes";

export type ExecOpts = {
  input?: string | Secret;
  timeoutMs?: number;
  cwd?: string;
  // inherit: 래퍼의 대화형 질문을 사람이 직접 받는다(delegate만). stdout-to-stderr: --json일 때 stdout을 지킨다.
  stdio?: "pipe" | "inherit" | "stdout-to-stderr";
  // stdout을 Secret으로만 돌려준다(kubectl get secret, infisical secrets 등).
  secretStdout?: boolean;
  // 자식 환경에 더하거나 지울 값(undefined면 지움).
  env?: Record<string, string | undefined>;
};

export type ExecResult = {
  code: number | null;
  stdout: string;
  stdoutSecret?: Secret;
  stderr: string;
  errKind?: "not-found" | "timeout" | "spawn";
};

export type Exec = (argv: string[], opts?: ExecOpts) => ExecResult;

// plan·read 모드에서 쓰기 호출을 막았을 때 메시지에 넣는 표지. 시험이 이 글자를 찾는다.
export const PLAN_WRITE_BLOCKED = "plan-write-blocked";

const READ_TIMEOUT_MS = 30_000;
const WRITE_TIMEOUT_MS = 120_000;
const MAX_ERR = 2_000;

function timeoutFor(write: boolean, env: Record<string, string | undefined>, asked?: number): number {
  const base = asked ?? (write ? WRITE_TIMEOUT_MS : READ_TIMEOUT_MS);
  // 시험 전용: 타임아웃 주입 시험이 기다리지 않게 상한을 낮춘다.
  const cap = Number(env.HOMELAB_TEST_TIMEOUT_MS);
  return Number.isFinite(cap) && cap > 0 ? Math.min(base, cap) : base;
}

// 함정(옛 tools/lib/exec.ts 실측): git hook 안에서 CLI를 띄우면 GIT_DIR·GIT_WORK_TREE·GIT_INDEX_FILE이 상속돼
// git -C <다른 곳>이 hook의 저장소를 본다. 자격이 없으면 프롬프트에서 멈추므로 GIT_TERMINAL_PROMPT=0.
function childEnv(argv0: string, base: Record<string, string | undefined>, extra?: Record<string, string | undefined>): Record<string, string> {
  const env: Record<string, string | undefined> = { ...base, ...extra };
  if (argv0 === "git") {
    delete env.GIT_DIR;
    delete env.GIT_WORK_TREE;
    delete env.GIT_INDEX_FILE;
    env.GIT_TERMINAL_PROMPT = "0";
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) out[k] = v;
  return out;
}

export function makeExec(mode: Mode, delegateApply: boolean, env: Record<string, string | undefined>): Exec {
  return (argv, opts = {}) => {
    if (argv.length === 0) throw new Error("빈 argv");
    for (const a of argv) {
      if (containsTracked(a)) throw new Error(`시크릿 값을 명령행 인자로 넘기려 했다: ${argv[0]}(값은 stdin으로만 넘긴다)`);
      if (a.includes("\0")) throw new Error(`NUL이 든 인자: ${argv[0]}`);
    }
    const verdict = classify(argv);
    // github apply(delegate)는 래퍼 하나만 쓰기로 허용한다. 래퍼 밖의 쓰기는 그 명령에서도 막는다.
    const allowed = !verdict.write || (mode === "apply" && (!delegateApply || basename(argv[0]) === "tf-github.sh"));
    if (!allowed) {
      throw new Error(`${PLAN_WRITE_BLOCKED}: ${mode} 모드에서 쓰기 호출을 막았다(${verdict.reason})`);
    }
    const stdio = opts.stdio ?? "pipe";
    const input = opts.input === undefined ? undefined : isSecret(opts.input) ? opts.input.reveal() : opts.input;
    let p: ReturnType<typeof Bun.spawnSync>;
    try {
      p = Bun.spawnSync(argv, {
        cwd: opts.cwd,
        env: childEnv(argv[0], env, opts.env),
        stdin: stdio === "inherit" ? "inherit" : input === undefined ? "ignore" : new TextEncoder().encode(input),
        stdout: stdio === "pipe" ? "pipe" : stdio === "inherit" ? "inherit" : 2,
        stderr: stdio === "inherit" || stdio === "stdout-to-stderr" ? "inherit" : "pipe",
        timeout: timeoutFor(verdict.write, env, opts.timeoutMs),
      } as Parameters<typeof Bun.spawnSync>[1]);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      return { code: null, stdout: "", stderr: (e as Error).message, errKind: code === "ENOENT" ? "not-found" : "spawn" };
    }
    const stdoutText = p.stdout ? p.stdout.toString() : "";
    // 자식이 죽기 전에 쓴 stderr가 원인의 유일한 단서일 때가 많다. 앞부분만 남긴다.
    const stderr = (p.stderr ? p.stderr.toString() : "").trim().slice(0, MAX_ERR);
    const result: ExecResult = { code: p.exitCode, stdout: opts.secretStdout ? "" : stdoutText, stderr };
    if (opts.secretStdout) result.stdoutSecret = new Secret(stdoutText);
    if ((p as { exitedDueToTimeout?: boolean }).exitedDueToTimeout) result.errKind = "timeout";
    return result;
  };
}

// 결과 해석에 쓰는 짧은 원인 한 줄.
export function why(r: ExecResult): string {
  if (r.errKind === "not-found") return "명령이 없다";
  if (r.errKind === "timeout") return "시간 초과(결과 미상)";
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
