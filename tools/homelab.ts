#!/usr/bin/env bun
// homelab CLI 셸 — 앱 배포·리소스 조작 통합 진입점(워킹 스켈레톤: doctor).
// 이 파일은 CLI 관심사만 갖는다: argv 파싱·--help·사람용 렌더링·stdout 순수성·종료코드.
// 동사의 실체(operation catalog)는 lib/verbs.ts, 계약 상수는 lib/contract.ts가 SSOT다 —
// 이 bin 모듈은 import 시 main이 실행되므로 MCP 등 다른 소비자는 lib 쪽을 import한다
// (structure r1 A1·B1). 셰뱅+exec 비트는 이 파일만 예외: package.json bin("homelab")의
// 대상이라 `bun link`가 전역 PATH에 심링크한다(test_shebang-exec.bats가 bin 선언에서 파생).
import { parseCommand, typedFlags, type CommandTree, type ParsedCommand } from "./lib/cli.ts";
import { USAGE_EXIT, type Envelope } from "./lib/contract.ts";
import { DOCTOR, VERBS } from "./lib/verbs.ts";
import type { DoctorCheck, DoctorSummary } from "./lib/doctor.ts";

// 동사 실행의 세 결말 — 프로세스 관심사(stdout 채널·종료코드)는 전부 main이 소유한다.
type VerbOutput =
  | { kind: "help"; text: string }
  | { kind: "usage-error"; message: string; usage: string }
  | { kind: "result"; json: boolean; envelope: Envelope; human: string[] };

// CLI 어댑터 — catalog 행마다 argv→타입 입력 매핑과 렌더링을 배선한다(어댑터는 named export를
// 정확한 입력 타입으로 직접 호출). totality는 아래 초기화 검사가 강제: 미배선 동사는 어떤
// 호출이든 즉시 throw(계약 파손 — 종료코드 2의 의미 재사용 금지).
const CLI_BY_VERB: Record<string, (rest: string[]) => VerbOutput> = {
  doctor: doctorCli,
};
for (const v of VERBS) {
  if (!CLI_BY_VERB[v.path.join(" ")]) throw new Error(`계약 파손: 동사 '${v.path.join(" ")}'의 CLI 어댑터가 없다`);
}

// 라우팅 어휘·usage는 catalog에서 파생한다(어휘 SSOT = lib/verbs.ts).
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

function renderDoctor(envelope: Envelope): string[] {
  const r = envelope.result as { checks: DoctorCheck[]; summary: DoctorSummary };
  return [
    ...r.checks.map((c) => `${MARK[c.status]} ${c.id} — ${c.detail}`),
    "",
    `진단 결과: pass ${r.summary.pass} · fail ${r.summary.fail} · warn ${r.summary.warn}`,
  ];
}

function doctorCli(rest: string[]): VerbOutput {
  let flags;
  try { flags = typedFlags(rest, { value: [], bool: ["--json", "--help"] }); }
  catch (e) {
    return { kind: "usage-error", message: `homelab doctor: ${e instanceof Error ? e.message : String(e)}`, usage: doctorUsage() };
  }
  if (flags.bool("--help")) return { kind: "help", text: doctorUsage() };
  const envelope = DOCTOR.op({});
  return { kind: "result", json: flags.bool("--json"), envelope, human: renderDoctor(envelope) };
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

  // parseCommand가 성공한 path는 TREE의 리프이고 TREE는 VERBS에서 파생되므로, 초기화의
  // totality 검사와 합쳐 어댑터가 항상 존재한다.
  const out = CLI_BY_VERB[cmd.path.join(" ")]!(cmd.rest);

  // 프로세스 관심사는 여기서만: --help는 --json보다 우선(계약 stdout 절), usage 오류는 exit 2 +
  // stderr, 결과는 stdout 순수성(--json이면 stdout은 envelope 하나, 사람용은 stderr)을 지킨다.
  if (out.kind === "help") { process.stdout.write(out.text); return 0; }
  if (out.kind === "usage-error") { process.stderr.write(`${out.message}\n\n${out.usage}`); return USAGE_EXIT; }
  const sink = out.json ? process.stderr : process.stdout;
  for (const line of out.human) sink.write(line + "\n");
  if (out.json) process.stdout.write(JSON.stringify(out.envelope, null, 2) + "\n");
  return out.envelope.exitCode;
}

process.exitCode = main(process.argv.slice(2));
