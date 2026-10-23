// PATH 스텁 본체. 도구 이름의 실행 파일(harness.ts가 만든다)이 이 파일을 bun으로 부른다.
// argv를 원장(JSONL)에 적고 규칙에 맞는 첫 응답을 낸다. stdin은 길이와 sha256만 적는다(시크릿이 지나는 길이다).
// 규칙에 captureStdin이 있으면 원문도 적는다(시크릿이 없는 gh api 본문 확인용).
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

type Matcher = string | { re: string };
type Resp = { stdout?: string; stderr?: string; code?: number; sleepMs?: number; echoEnv?: string[] };
type Rule = { argv: Matcher[]; rest: boolean; responses: Resp[]; captureStdin?: boolean };

const dir = process.env.HOMELAB_STUB_DIR;
if (!dir) {
  process.stderr.write("stub: HOMELAB_STUB_DIR가 없다\n");
  process.exit(98);
}
// harness가 만든 sh 실행 파일이 자기 경로($0)를 첫 인자로 넘긴다.
const argv = [basename(process.argv[2]), ...process.argv.slice(3)];
const stdin = process.stdin.isTTY ? "" : await Bun.stdin.text();
const rules: Rule[] = JSON.parse(readFileSync(join(dir, "rules.json"), "utf8"));

function matches(rule: Rule): boolean {
  if (rule.rest ? argv.length < rule.argv.length : argv.length !== rule.argv.length) return false;
  return rule.argv.every((m, i) => (typeof m === "string" ? m === argv[i] : new RegExp(`^(?:${m.re})$`).test(argv[i])));
}

const index = rules.findIndex(matches);
const call: Record<string, unknown> = {
  argv,
  stdinLength: stdin.length,
  stdinSha256: new Bun.CryptoHasher("sha256").update(stdin).digest("hex"),
  rule: index === -1 ? null : index,
};
if (index !== -1 && rules[index].captureStdin) call.stdin = stdin;
appendFileSync(join(dir, "ledger.jsonl"), JSON.stringify(call) + "\n");

if (index === -1) {
  process.stderr.write(`stub: 시나리오에 없는 호출: ${JSON.stringify(argv)}\n`);
  process.exit(97);
}

// responses는 호출 순서대로 하나씩 쓴다. 다 쓰면 마지막 응답을 반복한다.
const counter = join(dir, `count-${index}`);
const n = existsSync(counter) ? Number(readFileSync(counter, "utf8")) : 0;
writeFileSync(counter, String(n + 1));
const resp = rules[index].responses[Math.min(n, rules[index].responses.length - 1)];
if (resp.sleepMs) await Bun.sleep(resp.sleepMs);
if (resp.stdout) process.stdout.write(resp.stdout);
// 자식이 받은 환경을 시험이 보게 한다(값이 없으면 null).
if (resp.echoEnv) process.stdout.write(JSON.stringify(Object.fromEntries(resp.echoEnv.map((k) => [k, process.env[k] ?? null]))));
if (resp.stderr) process.stderr.write(resp.stderr);
process.exit(resp.code ?? 0);
