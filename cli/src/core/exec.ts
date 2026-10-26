// 외부 명령 seam. cli/src에서 프로세스를 띄우는 곳은 여기 하나다. 명령(commands/)은 이 모듈을 볼 수 없고
// core 어댑터(runtime.ts가 문맥으로 준다)만 부른다. 어댑터마다 argv 모양이 고정이라 안전의 근거는 어댑터 모양이고,
// 아래 판정(writes.ts)은 원장 집계와 마지막 방어선이다(사용자 결정 2026-10-23, #873 3라운드).
// seam은 재시도하지 않는다. 변이 호출의 타임아웃은 "결과 미상"이고 재시도는 두 번 실행이다(B.8 E7).
//
// - read exec: 쓰기로 판정된 argv를 실행하지 않는다. 예외는 core가 만든 임시 폴더로의 git clone 하나.
// - write exec: 엔진이 Step.apply() 한 번마다 새로 만들고 끝나면 폐기한다(live). 폐기한 exec를 붙잡아 두었다가 써도 막힌다.
//   전역 쓰기 창이 없으므로 다른 엔진·병렬 흐름의 read가 쓰기를 빌려 쓸 수 없다(#873 2라운드 P2).
// - 직접 stdio(inherit, stdout-to-stderr)는 github 위임만. 위임 stdout-to-stderr는 부모 stdin을 넘긴다.
// - 값을 내는 호출은 secretStdout으로만, 민감 호출의 stderr 원문은 돌려주지 않는다.
import { basename } from "node:path";
import { guardInfisicalBackup } from "./infisical-backup";
import { Secret, containsTracked, isSecret, revealSecret } from "./secret";
import { ownedTemp } from "./temp";
import { classify } from "./writes";

export type ExecOpts = {
  input?: string | Secret;
  timeoutMs?: number;
  cwd?: string;
  stdio?: "pipe" | "inherit" | "stdout-to-stderr";
  secretStdout?: boolean;
  // 자식 환경에 더하거나 지울 값(undefined면 지움).
  env?: Record<string, string | undefined>;
  // 자식 환경을 이 값으로 바꾼다(env -i처럼). git clone이 전역·시스템 설정과 hook을 끊을 때 쓴다.
  cleanEnv?: Record<string, string>;
  // read exec에서 git clone을 허용할 core 임시 폴더. argv 마지막이 그 아래여야 한다.
  cloneInto?: string;
  // 민감 호출은 stderr 원문을 버린다. 판정에 필요한 오류는 core 고정 정규식으로 이름만 돌려받는다(예 비밀번호 거부).
  signals?: Record<string, RegExp>;
};

export type ExecResult = {
  code: number | null;
  stdout: string;
  stdoutSecret?: Secret;
  // 민감 호출이면 빈 문자열이고 stderrHidden이 true다.
  stderr: string;
  stderrHidden?: boolean;
  // kubectl API의 NotFound 응답(Error from server (NotFound))만. 인증 플러그인의 "not found" 같은 다른 오류는 아니다.
  notFound: boolean;
  errKind?: "not-found" | "timeout" | "spawn";
  // opts.signals 중 stdout·stderr에 맞은 이름.
  signals?: string[];
};

export type Exec = (argv: string[], opts?: ExecOpts) => ExecResult;

// 쓰기 호출을 막았을 때 메시지에 넣는 표지. 시험이 이 글자를 찾는다.
export const PLAN_WRITE_BLOCKED = "plan-write-blocked";

const READ_TIMEOUT_MS = 30_000;
const WRITE_TIMEOUT_MS = 120_000;
const MAX_ERR = 2_000;
const KUBE_NOT_FOUND = /^Error from server \(NotFound\)/m;

function timeoutFor(write: boolean, env: Record<string, string | undefined>, asked?: number): number {
  const base = asked ?? (write ? WRITE_TIMEOUT_MS : READ_TIMEOUT_MS);
  // 시험 전용: 타임아웃 주입 시험이 기다리지 않게 상한을 낮춘다.
  const cap = Number(env.HOMELAB_TEST_TIMEOUT_MS);
  return Number.isFinite(cap) && cap > 0 ? Math.min(base, cap) : base;
}

// 함정(옛 tools/lib/exec.ts 실측): git hook 안에서 CLI를 띄우면 GIT_DIR·GIT_WORK_TREE·GIT_INDEX_FILE이 상속돼
// git -C <다른 곳>이 hook의 저장소를 본다. 자격이 없으면 프롬프트에서 멈추므로 GIT_TERMINAL_PROMPT=0. 판정은 basename.
// git을 부르는 래퍼(tf-github.sh)도 같다(Connector 4360754437). GIT_CONFIG_COUNT·KEY·VALUE는 설정(core.fsmonitor 등)을
// 끼워 넣으므로 저장소 변수만이 아니라 GIT_* 전부를 지운다.
function childEnv(argv0: string, base: Record<string, string | undefined>, opts: ExecOpts): Record<string, string> {
  const env: Record<string, string | undefined> = opts.cleanEnv ? { ...opts.cleanEnv } : { ...base, ...opts.env };
  if (basename(argv0) === "git" || basename(argv0) === "tf-github.sh") {
    for (const k of Object.keys(env)) if (k.startsWith("GIT_") && !(opts.cleanEnv && k in opts.cleanEnv)) delete env[k];
    env.GIT_TERMINAL_PROMPT = "0";
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) out[k] = v;
  return out;
}

type MakeOpts = {
  env: Record<string, string | undefined>;
  // 쓰기 exec만: 이 apply가 아직 진행 중인지. false면 모든 호출을 막는다.
  live?: () => boolean;
  // github 위임 명령의 exec. 직접 stdio를 쓸 수 있고, 쓰기는 래퍼(tf-github.sh) 하나만.
  delegate?: boolean;
};

function cloneAllowed(argv: string[], opts: ExecOpts): boolean {
  if (!opts.cloneInto || !ownedTemp(opts.cloneInto)) return false;
  const pos = argv.slice(1).filter((a) => !a.startsWith("-"));
  return basename(argv[0]) === "git" && argv.includes("clone") && (argv.at(-1) ?? "").startsWith(`${opts.cloneInto}/`) && pos.length >= 3;
}

export function makeExec(kind: "read" | "write", m: MakeOpts): Exec {
  return (argv, opts = {}) => {
    if (argv.length === 0) throw new Error("빈 argv");
    if (kind === "write" && !(m.live?.() ?? false)) throw new Error(`${PLAN_WRITE_BLOCKED}: 끝난 apply의 쓰기 문맥을 다시 썼다(Step.apply 밖)`);
    for (const a of argv) {
      if (containsTracked(a)) throw new Error(`시크릿 값을 명령행 인자로 넘기려 했다: ${basename(argv[0])}(값은 stdin으로만 넘긴다)`);
      if (a.includes("\0")) throw new Error(`NUL이 든 인자: ${basename(argv[0])}`);
    }
    const verdict = classify(argv);
    if (verdict.write) {
      const ok = kind === "write" ? !m.delegate || basename(argv[0]) === "tf-github.sh" : cloneAllowed(argv, opts);
      if (!ok) throw new Error(`${PLAN_WRITE_BLOCKED}: ${kind === "read" ? "읽기 문맥" : "github 위임의 래퍼 밖"}에서 쓰기 호출을 막았다(${verdict.reason})`);
    }
    if (verdict.sensitiveOutput && !opts.secretStdout) throw new Error(`값을 내는 호출은 secretStdout으로만 실행한다: ${verdict.reason}`);
    const stdio = opts.stdio ?? "pipe";
    if (stdio !== "pipe") {
      if (!m.delegate) throw new Error(`stdio ${stdio}는 github 위임 명령만 쓴다(출력 계층을 거치지 않는다)`);
      if (opts.secretStdout || isSecret(opts.input)) throw new Error(`stdio ${stdio}에 시크릿 입출력을 함께 쓰지 않는다`);
    }
    const sensitive = Boolean(opts.secretStdout) || isSecret(opts.input) || Boolean(verdict.sensitiveOutput);
    const input = opts.input === undefined ? undefined : isSecret(opts.input) ? revealSecret(opts.input) : opts.input;
    // 입력을 따로 주지 않은 위임 명령은 부모 stdin을 넘긴다(래퍼가 묻는 값과 마지막 yes를 사람이 직접 답한다).
    const stdin = input !== undefined ? new TextEncoder().encode(input) : stdio !== "pipe" ? "inherit" : "ignore";
    const env = childEnv(argv[0], m.env, opts);
    // 띄우기 실패는 값으로 돌려준다. 그래야 아래 백업 막기의 실패(던짐)와 섞이지 않는다.
    const spawn = (childEnvFinal: Record<string, string>): ReturnType<typeof Bun.spawnSync> | Error => {
      try {
        return Bun.spawnSync(argv, {
          cwd: opts.cwd,
          env: childEnvFinal,
          stdin,
          stdout: stdio === "pipe" ? "pipe" : stdio === "inherit" ? "inherit" : 2,
          stderr: stdio === "pipe" ? "pipe" : "inherit",
          timeout: timeoutFor(verdict.write, m.env, opts.timeoutMs),
        } as Parameters<typeof Bun.spawnSync>[1]);
      } catch (e) {
        return e as Error;
      }
    };
    // infisical은 어느 어댑터가 부르든 로컬 백업 막기를 거친다(infisical-backup.ts). 자식 HOME은 막은 폴더와 같은 실제 경로다.
    const p = basename(argv[0]) === "infisical" ? guardInfisicalBackup(env.HOME, (home) => spawn({ ...env, HOME: home })) : spawn(env);
    if (p instanceof Error) {
      const code = (p as NodeJS.ErrnoException).code;
      return { code: null, stdout: "", stderr: sensitive ? "" : p.message, stderrHidden: sensitive || undefined, notFound: false, errKind: code === "ENOENT" ? "not-found" : "spawn" };
    }
    const stdoutText = p.stdout ? p.stdout.toString() : "";
    const rawErr = p.stderr ? p.stderr.toString() : "";
    const result: ExecResult = {
      code: p.exitCode,
      stdout: opts.secretStdout ? "" : stdoutText,
      // 자식이 죽기 전에 쓴 stderr가 원인의 유일한 단서일 때가 많다. 민감 호출이 아니면 앞부분만 남긴다.
      stderr: sensitive ? "" : rawErr.trim().slice(0, MAX_ERR),
      notFound: basename(argv[0]) === "kubectl" && KUBE_NOT_FOUND.test(rawErr),
    };
    if (sensitive) result.stderrHidden = true;
    if (opts.signals) result.signals = Object.entries(opts.signals).filter(([, re]) => re.test(rawErr) || re.test(stdoutText)).map(([k]) => k);
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

// port-forward 하나를 백그라운드로 띄워 로컬 포트를 읽고, 그 포트로 curl 하나를 한 뒤 끝낸다(03 D7 헬스 확인).
// 비동기 프로세스라 makeExec 밖의 이 모양 전용 함수로 둔다. argv는 core가 만들고(kubectl.ts), 쓰기 문맥이 살아 있을 때만 돈다.
// port-forward는 NetworkPolicy를 거치지 않는다(T11 손 절차와 같음).
export type Forward = (forwardArgs: string[], path: string, timeoutMs?: number) => Promise<number>;

const FORWARDING = /Forwarding from 127\.0\.0\.1:([0-9]{1,5}) ->/;

export function makeForward(exec: Exec, m: { env: Record<string, string | undefined>; live: () => boolean }): Forward {
  return async (forwardArgs, path, timeoutMs = 15_000) => {
    if (!m.live()) throw new Error(`${PLAN_WRITE_BLOCKED}: 끝난 apply의 쓰기 문맥을 다시 썼다(Step.apply 밖)`);
    const argv = ["kubectl", ...forwardArgs];
    if (argv[1] !== "-n" || !argv.includes("port-forward")) throw new Error("port-forward argv 모양이 아니다");
    for (const a of argv) if (containsTracked(a) || a.includes("\0")) throw new Error("port-forward 인자에 쓸 수 없는 값이 있다");
    const p = Bun.spawn(argv, { env: childEnv("kubectl", m.env, {}), stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    try {
      const reader = p.stdout.getReader();
      const deadline = Date.now() + Math.min(timeoutMs, timeoutFor(false, m.env));
      let text = "";
      let port: string | undefined;
      while (!port) {
        const left = deadline - Date.now();
        if (left <= 0) throw new ExecTimeout("port-forward: 로컬 포트를 받지 못했다(시간 초과)");
        const chunk = await Promise.race([reader.read(), Bun.sleep(left).then(() => null)]);
        if (chunk === null) continue;
        if (chunk.done) throw new Error("port-forward가 포트를 알리기 전에 끝났다");
        text += new TextDecoder().decode(chunk.value);
        port = FORWARDING.exec(text)?.[1];
      }
      reader.releaseLock();
      const r = exec(["curl", "-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10", `http://127.0.0.1:${port}${path}`]);
      if (r.errKind === "timeout") throw new ExecTimeout("헬스 확인: 시간 초과");
      const code = Number(r.stdout.trim());
      if (!Number.isInteger(code)) throw new Error(`헬스 확인: 응답 코드를 읽지 못했다(${why(r)})`);
      return code;
    } finally {
      p.kill();
      await p.exited;
    }
  };
}

// kubectl 둘을 잇는 파이프(03 2부: pg_dump | rclone rcat, rclone cat | pg_restore, 임시 클러스터 pg_dump | 복원 Job pg_restore).
// 데이터는 CLI 메모리를 흐름으로만 지나고 디스크에 남지 않는다(restore.md 1단계: 사람 기기에 데이터가 남지 않게).
// 판정은 두 종료 코드를 함께 본다(한쪽만 0이면 실패다: 앞이 죽으면 뒤는 잘린 입력으로 성공할 수 있다).
// stderr 원문은 돌려주지 않는다(pg_restore 오류에 행 데이터가 섞일 수 있다). 소비자 stdout만 상한까지 모은다.
export type PipeResult = { producerCode: number | null; consumerCode: number | null; stdout: string; timedOut: boolean };
export type Pipe = (producer: string[], consumer: string[], opts?: { timeoutMs?: number; maxStdout?: number }) => Promise<PipeResult>;

const PIPE_MAX_STDOUT = 32 * 1024 * 1024;

export function makePipe(m: { env: Record<string, string | undefined>; live: () => boolean }): Pipe {
  return async (producer, consumer, opts = {}) => {
    if (!m.live()) throw new Error(`${PLAN_WRITE_BLOCKED}: 끝난 apply의 쓰기 문맥을 다시 썼다(Step.apply 밖)`);
    for (const argv of [producer, consumer]) {
      if (argv[0] !== "kubectl" || argv[1] !== "-n" || !argv.includes("exec")) throw new Error("파이프는 kubectl exec 둘만 잇는다");
      for (const a of argv) if (containsTracked(a) || a.includes("\0")) throw new Error("파이프 인자에 쓸 수 없는 값이 있다");
    }
    const env = childEnv("kubectl", m.env, {});
    const max = opts.maxStdout ?? PIPE_MAX_STDOUT;
    const timeoutMs = timeoutFor(true, m.env, opts.timeoutMs ?? 3_600_000);
    const a = Bun.spawn(producer, { env, stdin: "ignore", stdout: "pipe", stderr: "ignore" });
    const b = Bun.spawn(consumer, { env, stdin: a.stdout, stdout: "pipe", stderr: "ignore" });
    let timedOut = false;
    let tooBig = false;
    const timer = setTimeout(() => {
      timedOut = true;
      a.kill();
      b.kill();
    }, timeoutMs);
    try {
      const chunks: Uint8Array[] = [];
      let size = 0;
      for await (const c of b.stdout) {
        size += c.length;
        if (size > max) {
          tooBig = true;
          a.kill();
          b.kill();
          break;
        }
        chunks.push(c);
      }
      const [producerCode, consumerCode] = await Promise.all([a.exited, b.exited]);
      if (tooBig) throw new Error(`파이프 출력이 상한(${max}바이트)을 넘었다`);
      return { producerCode: timedOut ? null : producerCode, consumerCode: timedOut ? null : consumerCode, stdout: new TextDecoder().decode(Buffer.concat(chunks)), timedOut };
    } finally {
      clearTimeout(timer);
    }
  };
}
