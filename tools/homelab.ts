#!/usr/bin/env bun
// homelab CLI — 앱 배포·리소스 조작 통합 진입점(워킹 스켈레톤: doctor).
// 셰뱅+exec 비트는 이 파일만 예외다: package.json bin("homelab")의 대상이라 `bun link`가
// 전역 PATH에 심링크한다(test_shebang-exec.bats가 bin 선언에서 예외를 파생해 강제).
// 계약: --json 출력·variant·종료코드 매핑은 tools/cli-result-schema.json(x-contract)이 SSOT —
// 여기서는 그 파일을 런타임에 읽고 코드 상수로 복제하지 않는다. import.meta.url 기준 해석이라
// 어느 디렉토리에서 실행해도(앱 레포 안 포함) 동작한다.
import { readFileSync } from "node:fs";
import { parseCommand, typedFlags, type CommandTree, type ParsedCommand } from "./lib/cli.ts";
import { runDoctor } from "./lib/doctor.ts";

const SCHEMA = JSON.parse(readFileSync(new URL("./cli-result-schema.json", import.meta.url), "utf8"));
const CONTRACT = SCHEMA["x-contract"];
const ENVELOPE: string = CONTRACT.envelope;
const EXIT: Record<string, number> = CONTRACT.exitCodes;
const USAGE_EXIT: number = CONTRACT.usageExit;

// 동사 어휘 SSOT — TREE(라우팅)·usage(--help 열거)·디스패치를 전부 여기서 파생한다.
// 후속 티켓은 이 배열에 행을 추가한다(예: ["app","init"]). run까지 한 행이라
// "어휘에는 있는데 분기가 없는" 미배선 상태가 표현 불가능하다(종료코드 2 의미 재사용 방지).
const VERBS: Array<{ path: string[]; desc: string; run: (rest: string[]) => number }> = [
  { path: ["doctor"], desc: "플랫폼 전제 진단(gh 인증·owner 일치·스코프 / bun·kubeseal / KUBECONFIG / 템플릿 호환성)", run: doctorMain },
];
const TREE: CommandTree = {};
for (const v of VERBS) {
  let node: CommandTree = TREE;
  v.path.forEach((word, i) => {
    if (i === v.path.length - 1) node[word] = null;
    else node = (node[word] ??= {}) as CommandTree;
  });
}

function usage(): string {
  const rows = VERBS.map((v) => `  ${v.path.join(" ").padEnd(14)}${v.desc}`).join("\n");
  return [
    "사용법: homelab <동사> [옵션]",
    "",
    "동사:",
    rows,
    "",
    "공통 옵션:",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(계약: tools/cli-result-schema.json)",
    "  --help        사용법 출력",
    "",
  ].join("\n");
}

function doctorUsage(): string {
  return [
    "사용법: homelab doctor [--json]",
    "",
    "플랫폼 전제 진단 — gh 인증·HOMELAB_OWNER 일치·토큰 스코프, bun·kubeseal 존재,",
    "KUBECONFIG(부재는 경고), 템플릿 접근성·호환성(스캐폴더 비대화형 계약·TARGETARCH)을 점검한다.",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
  ].join("\n");
}

const MARK: Record<string, string> = { pass: "✓", fail: "✗", warn: "⚠" };

// variant → 종료코드(스키마 x-contract SSOT). 매핑 부재는 계약 파손이라 fail-closed.
function exitFor(variant: string): number {
  const code = EXIT[variant];
  if (code === undefined) throw new Error(`계약 파손: variant '${variant}'의 종료코드 매핑이 스키마에 없다`);
  return code;
}

function doctorMain(rest: string[]): number {
  let flags;
  try { flags = typedFlags(rest, { value: [], bool: ["--json", "--help"] }); }
  catch (e) {
    process.stderr.write(`homelab doctor: ${e instanceof Error ? e.message : String(e)}\n\n${doctorUsage()}`);
    return USAGE_EXIT;
  }
  if (flags.bool("--help")) { process.stdout.write(doctorUsage()); return 0; }

  const json = flags.bool("--json");
  // stdout 순수성: --json이면 사람용 보고는 전부 stderr로 보낸다(계약 stdout 절).
  const human = (line: string) => (json ? process.stderr : process.stdout).write(line + "\n");

  const { checks, summary } = runDoctor();
  for (const c of checks) human(`${MARK[c.status]} ${c.id} — ${c.detail}`);
  human("");
  human(`진단 결과: pass ${summary.pass} · fail ${summary.fail} · warn ${summary.warn}`);

  const variant = summary.fail > 0 ? "failure" : "success";
  const exitCode = exitFor(variant);
  if (json) {
    const envelope = { schema: ENVELOPE, verb: "doctor", variant, exitCode, omitted: [], result: { checks, summary } };
    process.stdout.write(JSON.stringify(envelope, null, 2) + "\n");
  }
  return exitCode;
}

function main(argv: string[]): number {
  if (argv.length === 0) { process.stderr.write(usage()); return USAGE_EXIT; }
  if (argv[0] === "--help") { process.stdout.write(usage()); return 0; }

  let cmd: ParsedCommand;
  try { cmd = parseCommand(argv, TREE); }
  catch (e) {
    process.stderr.write(`homelab: ${e instanceof Error ? e.message : String(e)}\n\n${usage()}`);
    return USAGE_EXIT;
  }

  // parseCommand가 성공한 path는 TREE의 리프이고 TREE는 VERBS에서 파생되므로 항상 찾아진다.
  const verb = VERBS.find((v) => v.path.length === cmd.path.length && v.path.every((w, i) => w === cmd.path[i]))!;
  return verb.run(cmd.rest);
}

process.exitCode = main(process.argv.slice(2));
