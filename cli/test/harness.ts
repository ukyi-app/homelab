// PATH 스텁 시험 장치(설계 C.7·L50: 외부 명령 argv를 기록해 plan의 쓰기 부명령 0건을 단언한다).
// 두 쓰임:
// - runCli: 실제 하위 프로세스로 `bun cli/src/main.ts`를 돌린다. PATH는 스텁 폴더 하나, HOME은 임시 폴더라
//   사람의 실제 gh·kubectl·infisical·kubeconfig에 닿을 길이 없다.
// - testCtx: 같은 프로세스에서 Ctx를 만들어 단계·어댑터를 직접 부른다. exec는 같은 스텁 PATH를 쓴다.
import { expect } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Ctx } from "../src/core/command";
import { runEngine } from "../src/core/engine";
import { PLAN_WRITE_BLOCKED, makeExec } from "../src/core/exec";
import { argvFor as ghArgv } from "../src/core/github";
import { argvFor as infisicalArgv } from "../src/core/infisical";
import { kubectlArgv } from "../src/core/kubectl";
import type { Mode } from "../src/core/result";
import { classify } from "../src/core/writes";

const MAIN = join(import.meta.dir, "..", "src", "main.ts");
const STUB = join(import.meta.dir, "stub.ts");

// 시험용 가짜 값. 시크릿 단언의 기본 목록이다.
export const FAKE_PROJECT = "00000000-0000-4000-8000-000000000000";
export const FAKE_SECRETS = ["fakevalue-aaaa-bbbb-cccc", "fakevalue-dddd-eeee-ffff"];
export const FAKE_SHA = "a".repeat(40);

export const DEFAULT_TOOLS = ["gh", "git", "kubectl", "infisical", "curl", "terraform", "jq", "tf-github.sh"];

// 규칙 argv 끝에 두면 나머지 인자는 아무거나.
export const REST = "...";

// echoEnv: 스텁이 받은 환경변수 중 이 이름들을 JSON으로 stdout에 낸다.
export type Resp = { stdout?: string; stderr?: string; code?: number; sleepMs?: number; echoEnv?: string[] };
export type Matcher = string | RegExp;
export type Rule = { argv: Matcher[]; responses: Resp[]; captureStdin?: boolean };
export type Call = { argv: string[]; stdinLength: number; stdinSha256: string; stdin?: string; rule: number | null };

export function rule(argv: Matcher[], resp: Resp | Resp[] = {}, opts: { captureStdin?: boolean } = {}): Rule {
  return { argv, responses: Array.isArray(resp) ? resp : [resp], captureStdin: opts.captureStdin };
}

export function sha256(text: string): string {
  return new Bun.CryptoHasher("sha256").update(text).digest("hex");
}

// 어댑터 argv에 맞춘 규칙 도우미. 어댑터가 argv를 바꾸면 여기도 따라온다.
export function ghResponse(status: number, json: unknown): Resp {
  return { stdout: `HTTP/2.0 ${status} X\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(json)}`, code: status < 300 ? 0 : 1 };
}
export function ghGet(path: string, status: number | Resp[], json?: unknown): Rule {
  return rule(ghArgv.get(path), Array.isArray(status) ? status : ghResponse(status, json));
}
export function ghSend(method: string, path: string, status: number | Resp[], json?: unknown): Rule {
  return rule(ghArgv.send(method, path), Array.isArray(status) ? status : ghResponse(status, json), { captureStdin: true });
}
export function infisicalList(path: string, entries: Record<string, string> | Resp[]): Rule {
  const resp = Array.isArray(entries) ? entries : { stdout: JSON.stringify(Object.entries(entries).map(([secretKey, secretValue]) => ({ secretKey, secretValue }))) };
  return rule(infisicalArgv.list(FAKE_PROJECT, path), resp);
}
export function infisicalSet(path: string, resp: Resp | Resp[] = {}): Rule {
  return rule(infisicalArgv.set(FAKE_PROJECT, path), resp);
}
export function kubectlRule(args: Matcher[], resp: Resp | Resp[] = {}): Rule {
  return rule(kubectlArgv(args as string[]) as Matcher[], resp);
}

function shq(v: string): string {
  return `'${v.replaceAll("'", `'\\''`)}'`;
}

// 스텁 폴더는 프로세스별 뿌리(homelab-cli-test-<pid>) 아래에 둔다. 함정(bun 1.4.3 실측): bun test에서는
// process.on("exit")·beforeExit가 돌지 않는다. 그래서 runCli는 끝나자마자 자기 폴더를 지우고, testCtx 폴더는
// 다음 실행이 장치를 불러올 때 죽은 프로세스의 뿌리째 지운다.
const ROOT_PREFIX = "homelab-cli-test-";
const root = join(tmpdir(), `${ROOT_PREFIX}${process.pid}`);

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

for (const name of readdirSync(tmpdir())) {
  const m = name.match(/^homelab-cli-test-(\d+)$/);
  if (m && Number(m[1]) !== process.pid && !alive(Number(m[1]))) rmSync(join(tmpdir(), name), { recursive: true, force: true });
}

function stubDir(rules: Rule[], tools?: string[]): { dir: string; bin: string; home: string } {
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(join(root, "s-"));
  const bin = join(dir, "bin");
  const home = join(dir, "home");
  mkdirSync(bin);
  mkdirSync(home);
  const names = new Set(tools ?? [...DEFAULT_TOOLS, ...rules.map((r) => String(r.argv[0]))]);
  for (const name of names) {
    const p = join(bin, name);
    // bun을 절대 경로로 부른다(PATH에 bun이 없다). bun 셔뱅을 직접 쓰지 않는 이유: bun은 .sh 이름의 파일을
    // Bun Shell 스크립트로 돌려 tf-github.sh 스텁이 깨진다. $0은 도구 이름을 알려 준다.
    writeFileSync(p, `#!/bin/sh\nexec ${shq(process.execPath)} ${shq(STUB)} "$0" "$@"\n`);
    chmodSync(p, 0o755);
  }
  const serial = rules.map((r) => {
    const rest = r.argv[r.argv.length - 1] === REST;
    const argv = (rest ? r.argv.slice(0, -1) : r.argv).map((m) => (typeof m === "string" ? m : { re: m.source }));
    return { argv, rest, responses: r.responses, captureStdin: r.captureStdin };
  });
  writeFileSync(join(dir, "rules.json"), JSON.stringify(serial));
  return { dir, bin, home };
}

function readLedger(dir: string): Call[] {
  const f = join(dir, "ledger.jsonl");
  if (!existsSync(f)) return [];
  return readFileSync(f, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

export type CliRun = { code: number; stdout: string; stderr: string; json: any; calls: Call[]; writes: Call[]; unmatched: Call[] };

export type RunOpts = { env?: Record<string, string>; stdin?: string; tools?: string[]; project?: boolean };

function baseEnv(s: { dir: string; bin: string; home: string }, opts: RunOpts): Record<string, string> {
  return {
    PATH: s.bin,
    HOME: s.home,
    TMPDIR: s.dir,
    HOMELAB_STUB_DIR: s.dir,
    // 타임아웃 주입 시험이 오래 기다리지 않게 한다. 스텁의 sleepMs를 이보다 길게 주면 시간 초과다.
    HOMELAB_TEST_TIMEOUT_MS: "3000",
    ...(opts.project === false ? {} : { HOMELAB_INFISICAL_PROJECT_ID: FAKE_PROJECT }),
    ...opts.env,
  };
}

function summarize(calls: Call[]) {
  return { calls, writes: calls.filter((c) => classify(c.argv).write), unmatched: calls.filter((c) => c.rule === null) };
}

export async function runCli(args: string[], rules: Rule[], opts: RunOpts = {}): Promise<CliRun> {
  const s = stubDir(rules, opts.tools);
  // --no-env-file: 실행 폴더의 .env가 시험 환경에 섞이지 않게 한다.
  const p = Bun.spawn([process.execPath, "--no-env-file", MAIN, ...args], {
    cwd: s.home,
    env: baseEnv(s, opts),
    stdin: opts.stdin === undefined ? "ignore" : new TextEncoder().encode(opts.stdin),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  let json: any = null;
  if (args.includes("--json")) {
    try {
      json = JSON.parse(stdout);
    } catch {
      json = null;
    }
  }
  const calls = readLedger(s.dir);
  rmSync(s.dir, { recursive: true, force: true });
  return { code, stdout, stderr, json, ...summarize(calls) };
}

// 같은 프로세스에서 단계·어댑터를 시험할 Ctx. calls()가 그때까지의 스텁 원장을 돌려준다.
export function testCtx(mode: Mode, rules: Rule[], opts: RunOpts & { delegate?: boolean } = {}): { ctx: Ctx; calls: () => ReturnType<typeof summarize>; progress: string[] } {
  const s = stubDir(rules, opts.tools);
  const env = baseEnv(s, opts);
  const progress: string[] = [];
  const ctx: Ctx = {
    mode,
    json: false,
    line: "homelab test",
    env,
    isTTY: false,
    exec: makeExec(mode, opts.delegate ?? false, env),
    engine: (plan) => runEngine(ctx, plan),
    progress: (l) => progress.push(l),
    ask: () => null,
  };
  return { ctx, calls: () => summarize(readLedger(s.dir)), progress };
}

// plan·읽기 명령의 부수효과 0(AC-2). 원장이 비면 실패한다(아무것도 읽지 않은 plan은 시험이 아니다).
export function expectPlanReadOnly(r: { stdout?: string; stderr?: string; calls: Call[]; writes: Call[]; unmatched: Call[] }, opts: { secrets?: string[]; allowNoCalls?: boolean } = {}): void {
  expect(r.unmatched.map((c) => c.argv)).toEqual([]);
  expect(r.writes.map((c) => c.argv)).toEqual([]);
  if (!opts.allowNoCalls) expect(r.calls.length).toBeGreaterThan(0);
  expect(`${r.stdout ?? ""}${r.stderr ?? ""}`).not.toContain(PLAN_WRITE_BLOCKED);
  expectNoSecrets(r, opts.secrets);
}

// 출력·argv·적어 둔 stdin 어디에도 가짜 시크릿이 없다(AC-3).
export function expectNoSecrets(r: { stdout?: string; stderr?: string; calls: Call[] }, secrets: string[] = FAKE_SECRETS): void {
  const places = [r.stdout ?? "", r.stderr ?? "", ...r.calls.map((c) => c.argv.join(" ")), ...r.calls.map((c) => c.stdin ?? "")];
  for (const s of secrets) for (const p of places) expect(p.includes(s)).toBe(false);
}
