// PATH 스텁 본체. 도구 이름의 실행 파일(harness.ts가 만든다)이 이 파일을 bun으로 부른다.
// argv를 원장(JSONL)에 적고 규칙에 맞는 첫 응답을 낸다. stdin은 길이와 sha256만 적는다(시크릿이 지나는 길이다).
// 규칙에 captureStdin이 있으면 원문도 적는다(시크릿이 없는 gh api 본문 확인용).
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

type Matcher = string | { re: string };
// materialize: argv 마지막 인자(clone 목적지) 아래에 파일을 만든다. 값 "stub"은 스텁 실행 파일.
// echoCwd: 스텁이 실행된 폴더를 stdout에 낸다(git rev-parse --show-toplevel 흉내).
// homeWrite: $HOME 아래 path에 파일을 쓰려 한다(Infisical CLI의 secrets-backup 흉내). 실패는 무시한다(CLI 0.44.2도 무시).
//   force면 부모 폴더를 0700으로 바꾼 뒤 쓴다(권한이 듣지 않는 파일시스템 흉내). 결과는 원장의 homeWrite에 적는다.
type Resp = { stdout?: string; stderr?: string; code?: number; sleepMs?: number; echoEnv?: string[]; materialize?: Record<string, string>; echoCwd?: boolean; homeWrite?: { path: string; force?: boolean }; recordEnv?: string[]; holdMs?: number; writeLastArg?: string };
// noStdin: stdin을 읽지 않는다(위임이 부모 stdin을 넘기는 호출. 열린 stdin을 끝까지 읽으면 멈춘다).
type Rule = { argv: Matcher[]; rest: boolean; responses: Resp[]; captureStdin?: boolean; noStdin?: boolean };

// 환경을 비우고 띄운 호출(github 위임의 git clone)은 HOMELAB_STUB_DIR가 없다. 그때는 스텁 실행 파일 위치(<dir>/bin/<도구>)에서 찾는다.
const fromPath = dirname(dirname(process.argv[2] ?? ""));
const dir = process.env.HOMELAB_STUB_DIR ?? (existsSync(join(fromPath, "rules.json")) ? fromPath : undefined);
if (!dir) {
  process.stderr.write("stub: HOMELAB_STUB_DIR가 없다\n");
  process.exit(98);
}
// harness가 만든 sh 실행 파일이 자기 경로($0)를 첫 인자로 넘긴다.
const argv = [basename(process.argv[2]), ...process.argv.slice(3)];
const rules: Rule[] = JSON.parse(readFileSync(join(dir, "rules.json"), "utf8"));

function matches(rule: Rule): boolean {
  if (rule.rest ? argv.length < rule.argv.length : argv.length !== rule.argv.length) return false;
  return rule.argv.every((m, i) => (typeof m === "string" ? m === argv[i] : new RegExp(`^(?:${m.re})$`).test(argv[i])));
}

function homeWrite(w: { path: string; force?: boolean }): "written" | "denied" {
  // Infisical처럼 HOME 문자열에 이어 붙인다(path.join은 link/..를 링크를 보기 전에 지운다, #876 리뷰).
  const p = `${process.env.HOME ?? "/nonexistent"}/${w.path}`;
  try {
    mkdirSync(dirname(p), { recursive: true });
    if (w.force) chmodSync(dirname(p), 0o700);
    writeFileSync(p, "backup");
    return "written";
  } catch {
    return "denied";
  }
}

const index = rules.findIndex(matches);
const stdin = process.stdin.isTTY || (index !== -1 && rules[index].noStdin) ? "" : await Bun.stdin.text();
const call: Record<string, unknown> = {
  argv,
  stdinLength: stdin.length,
  stdinSha256: new Bun.CryptoHasher("sha256").update(stdin).digest("hex"),
  rule: index === -1 ? null : index,
  cwd: process.cwd(),
};
if (index !== -1 && rules[index].captureStdin) call.stdin = stdin;
// responses는 호출 순서대로 하나씩 쓴다. 다 쓰면 마지막 응답을 반복한다.
let resp: Resp | undefined;
if (index !== -1) {
  const counter = join(dir, `count-${index}`);
  const n = existsSync(counter) ? Number(readFileSync(counter, "utf8")) : 0;
  writeFileSync(counter, String(n + 1));
  resp = rules[index].responses[Math.min(n, rules[index].responses.length - 1)];
  if (resp.homeWrite) call.homeWrite = homeWrite(resp.homeWrite);
  // stdio를 상속하는 호출(github 위임)은 stdout을 시험이 못 받으므로 환경을 원장에 적는다.
  if (resp.recordEnv) call.env = Object.fromEntries(resp.recordEnv.map((k) => [k, process.env[k] ?? null]));
}
appendFileSync(join(dir, "ledger.jsonl"), JSON.stringify(call) + "\n");

if (!resp) {
  process.stderr.write(`stub: 시나리오에 없는 호출: ${JSON.stringify(argv)}\n`);
  process.exit(97);
}

if (resp.sleepMs) await Bun.sleep(resp.sleepMs);
if (resp.materialize) {
  const dest = argv[argv.length - 1];
  for (const [rel, content] of Object.entries(resp.materialize)) {
    const p = join(dest, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, content === "stub" ? `#!/bin/sh\nexec '${process.execPath}' '${process.argv[1]}' "$0" "$@"\n` : content);
    chmodSync(p, 0o755);
  }
}
if (resp.writeLastArg !== undefined) writeFileSync(argv[argv.length - 1], resp.writeLastArg);
if (resp.stdout) process.stdout.write(resp.stdout);
if (resp.echoCwd) process.stdout.write(`${process.cwd()}\n`);
// 자식이 받은 환경을 시험이 보게 한다(값이 없으면 null).
if (resp.echoEnv) process.stdout.write(JSON.stringify(Object.fromEntries(resp.echoEnv.map((k) => [k, process.env[k] ?? null]))));
if (resp.stderr) process.stderr.write(resp.stderr);
// 백그라운드 프로세스 흉내: 출력을 낸 뒤 살아 있는다(호출한 쪽이 kill한다).
if (resp.holdMs) await Bun.sleep(resp.holdMs);
process.exit(resp.code ?? 0);
