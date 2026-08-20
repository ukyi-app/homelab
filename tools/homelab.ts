#!/usr/bin/env bun
// homelab CLI 셸 — 앱 배포·리소스 조작 통합 진입점(워킹 스켈레톤: doctor).
// 이 파일은 CLI 관심사만 갖는다: argv 파싱·--help·사람용 렌더링·stdout 순수성·종료코드.
// 동사의 실체(operation catalog)는 lib/verbs.ts, 계약 상수는 lib/contract.ts가 SSOT다 —
// 이 bin 모듈은 import 시 main이 실행되므로 MCP 등 다른 소비자는 lib 쪽을 import한다
// (structure r1 A1·B1). 셰뱅+exec 비트는 이 파일만 예외: package.json bin("homelab")의
// 대상이라 `bun link`가 전역 PATH에 심링크한다(test_shebang-exec.bats가 bin 선언에서 파생).
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseCommand, typedFlags, type CommandTree, type ParsedCommand } from "./lib/cli.ts";
import { USAGE_EXIT, type Envelope } from "./lib/contract.ts";
import { CACHE_CREATE, DB_CREATE, DOCTOR, STATUS, VERBS, cacheCreateInputError, dbCreateInputError, type CacheCreateInput, type DbCreateInput } from "./lib/verbs.ts";
import type { DoctorCheck, DoctorSummary } from "./lib/doctor.ts";
import { statusInputError, type StatusInput } from "./lib/status.ts";

// 동사 실행의 네 결말 — 프로세스 관심사(stdout 채널·종료코드)는 전부 main이 소유한다.
// exit = 패스스루 동사(자식 프로세스가 자기 출력·종료코드를 이미 냈다 — 같은 동작 재노출 계약).
type VerbOutput =
  | { kind: "help"; text: string }
  | { kind: "usage-error"; message: string; usage: string }
  | { kind: "exit"; code: number }
  | { kind: "result"; json: boolean; envelope: Envelope; human: string[] };

// CLI 어댑터 — catalog 행마다 argv→타입 입력 매핑과 렌더링을 배선한다(어댑터는 named export를
// 정확한 입력 타입으로 직접 호출). totality는 아래 초기화 검사가 강제: 미배선 동사는 어떤
// 호출이든 즉시 throw(계약 파손 — 종료코드 2의 의미 재사용 금지).
const CLI_BY_VERB: Record<string, (rest: string[]) => VerbOutput> = {
  doctor: doctorCli,
  status: statusCli,
  "db create": dbCreateCli,
  "db url": dbUrlCli,
  "cache create": cacheCreateCli,
  "cache url": cacheUrlCli,
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

function statusUsage(): string {
  return [
    "사용법: homelab status [<app>] [--run <url> | --pr <url>] [--json]",
    "",
    "앱 상태 관찰 — 인자 없음: 전체 앱 목록·요약(레포 데이터). <app>: 배포 핀·바인딩·최근 run·",
    "열린 PR에, KUBECONFIG가 있으면 ArgoCD sync/health를 덧붙인다(없으면 라이브 구간 생략 표시).",
    "핸들 조회: --run/--pr에 GitHub URL을 주면 그 오퍼레이션 단위의 상태를 보고한다.",
    "  --run <url>   run URL(https://github.com/<o>/<r>/actions/runs/<id>) 핸들 조회",
    "  --pr <url>    PR URL(https://github.com/<o>/<r>/pull/<n>) 핸들 조회",
    "  --root <dir>  앱 산출물 루트 오버라이드(기본: CLI 자신의 레포 — 테스트 심)",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
  ].join("\n");
}

const OX: Record<string, string> = { true: "켜짐", false: "꺼짐" };

function renderStatus(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  if (typeof r.error === "string") return [`오류: ${r.error}`];
  if (r.mode === "list") {
    if (r.count === 0) return ["온보딩된 앱이 없다(그린필드)"];
    return [
      `앱 ${r.count}개`,
      ...r.apps.map((a: Record<string, unknown>) =>
        `• ${a.name} — tag ${a.tag ?? "(핀 없음)"} · autoDeploy ${OX[String(a.autoDeploy)] ?? "미기록"} · repo ${a.sourceRepo ?? "(인레포)"}`),
    ];
  }
  if (r.mode === "app") {
    const lines = [
      `앱: ${r.app.name}`,
      `배포 핀: tag ${r.app.tag ?? "(없음)"} · digest ${r.app.digest ?? "(없음)"}`,
      `autoDeploy: ${OX[String(r.app.autoDeploy)] ?? "미기록"} · source repo: ${r.app.sourceRepo ?? "(인레포)"} · 메모리 원장: ${r.app.ledgerMi !== undefined ? `limit ${r.app.ledgerMi}Mi` : "행 없음"}`,
      r.runs.length === 0 ? "최근 run: 없음"
        : `최근 run: ${r.runs.map((x: Record<string, unknown>) => `${x.name}[${x.status}${x.conclusion ? `/${x.conclusion}` : ""}]`).join(" · ")}`,
      r.openPrs.length === 0 ? "열린 PR: 없음"
        : `열린 PR: ${r.openPrs.map((p: Record<string, unknown>) => `#${p.number}(${p.head})`).join(" · ")}`,
    ];
    if (envelope.omitted.includes("live")) lines.push("라이브(ArgoCD): 생략 — KUBECONFIG 미설정");
    else if (r.live?.error) lines.push(`라이브(ArgoCD): 조회 실패 — ${r.live.error}`);
    else lines.push(`라이브(ArgoCD): sync ${r.live.argocd.sync} · health ${r.live.argocd.health}${r.live.argocd.revision ? ` · rev ${r.live.argocd.revision}` : ""}`);
    return lines;
  }
  if (r.mode === "run") {
    return [`run: ${r.run.name ?? "(이름 없음)"} — status ${r.run.status}${r.run.conclusion ? ` · conclusion ${r.run.conclusion}` : " · 진행 중"}`];
  }
  return [`PR #${r.pr.number} — ${r.pr.state} · merged ${OX[String(r.pr.merged)]} · auto-merge ${OX[String(r.pr.autoMerge)]}`];
}

function statusCli(rest: string[]): VerbOutput {
  let app: string | undefined;
  let flagArgv = rest;
  if (rest[0] !== undefined && !rest[0].startsWith("--")) { app = rest[0]; flagArgv = rest.slice(1); }
  let flags;
  try { flags = typedFlags(flagArgv, { value: ["--run", "--pr", "--root"], bool: ["--json", "--help"] }); }
  catch (e) {
    return { kind: "usage-error", message: `homelab status: ${e instanceof Error ? e.message : String(e)}`, usage: statusUsage() };
  }
  if (flags.bool("--help")) return { kind: "help", text: statusUsage() };
  const input: StatusInput = { app, runUrl: flags.str("--run"), prUrl: flags.str("--pr"), root: flags.str("--root") };
  const bad = statusInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab status: ${bad}`, usage: statusUsage() };
  const envelope = STATUS.op(input);
  return { kind: "result", json: flags.bool("--json"), envelope, human: renderStatus(envelope) };
}

function dbCreateUsage(): string {
  return [
    "사용법: homelab db create <name> [--ext a,b,...] [--wait] [--json]",
    "",
    "공유 CNPG 클러스터에 논리 DB를 생성한다 — create-database 디스패처를 correlation 수령증과",
    "함께 트리거하고 자기 run을 특정해 conclusion까지 추적한다(PR-first — 머지가 곧 적용).",
    "  --ext <a,b>        확장 목록(알려진 5종은 체크박스, 그 외는 ext_extra로 — 예: pg_trgm,vector)",
    "  --wait             auto-merge 머지 + Application 집합(cnpg-data·data-conn-prod) 수렴까지 대기",
    "  --poll-ms <n>      폴링 간격(기본 5000 — 시간 주입 심)",
    "  --deadline-ms <n>  전체 데드라인(기본 1200000 — 시간 주입 심)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
  ].join("\n");
}

function renderMutation(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  const lines = [`${envelope.verb} ${r.name} — correlation ${r.correlation}`];
  if (r.run?.url) lines.push(`run: ${r.run.url}${r.run.conclusion ? ` (${r.run.conclusion})` : ""}${r.run.failedJobs ? ` · 실패 잡: ${r.run.failedJobs.join(", ")}` : ""}`);
  if (r.pr?.url) lines.push(`PR: ${r.pr.url} · merged ${OX[String(r.pr.merged)]}${r.pr.mergeSha ? ` · merge SHA ${r.pr.mergeSha}` : ""}`);
  if (Array.isArray(r.applications)) {
    for (const a of r.applications) {
      lines.push(a.error
        ? `Application ${a.name}: 조회 실패 — ${a.error}`
        : `Application ${a.name}: sync ${a.sync} · health ${a.health} · rev ${a.revision} · 후손 ${OX[String(a.descendant)]}${a.surfaceOk !== undefined ? ` · 표면 ${OX[String(a.surfaceOk)]}` : ""}`);
    }
  }
  if (envelope.omitted.includes("live")) lines.push("라이브(ArgoCD) 수렴: 생략 — KUBECONFIG 미설정(머지까지만 확인)");
  if (r.pendingReason) lines.push(`대기: ${r.pendingReason}`);
  if (r.error) lines.push(`오류: ${r.error}`);
  lines.push(`결과: ${envelope.variant}`);
  return lines;
}

function cacheCreateUsage(): string {
  return [
    "사용법: homelab cache create <name> [--maxmemory-mi 16..1024] [--wait] [--json]",
    "",
    "앱별 Valkey 캐시를 생성한다 — create-cache 디스패처를 correlation 수령증과 함께 트리거하고",
    "자기 run을 특정해 conclusion까지 추적한다(PR-first — 머지가 곧 적용).",
    "  --maxmemory-mi <n> maxmemory(Mi, 16..1024 — 생략 시 디스패처 기본 64)",
    "  --wait             auto-merge 머지 + Application 집합(cache-prod·data-conn-prod) 수렴까지 대기",
    "  --poll-ms <n>      폴링 간격(기본 5000 — 시간 주입 심)",
    "  --deadline-ms <n>  전체 데드라인(기본 1200000 — 시간 주입 심)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
  ].join("\n");
}

function cacheCreateCli(rest: string[]): VerbOutput {
  let name: string | undefined;
  let flagArgv = rest;
  if (rest[0] !== undefined && !rest[0].startsWith("--")) { name = rest[0]; flagArgv = rest.slice(1); }
  let flags;
  try { flags = typedFlags(flagArgv, { value: ["--maxmemory-mi", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }); }
  catch (e) {
    return { kind: "usage-error", message: `homelab cache create: ${e instanceof Error ? e.message : String(e)}`, usage: cacheCreateUsage() };
  }
  if (flags.bool("--help")) return { kind: "help", text: cacheCreateUsage() };
  const num = (k: string): number | undefined => {
    const v = flags.str(k);
    return v === undefined ? undefined : Number(v);
  };
  const input: CacheCreateInput = {
    name: name ?? "",
    maxmemoryMi: num("--maxmemory-mi"),
    wait: flags.bool("--wait"),
    pollMs: num("--poll-ms"),
    deadlineMs: num("--deadline-ms"),
  };
  const bad = cacheCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab cache create: ${bad}`, usage: cacheCreateUsage() };
  const envelope = CACHE_CREATE.op(input);
  return { kind: "result", json: flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

// cache url 패스스루 — 기존 도구(tools/cache-url.ts)를 같은 동작으로 재노출한다.
function cacheUrlCli(rest: string[]): VerbOutput {
  const tool = fileURLToPath(new URL("./cache-url.ts", import.meta.url));
  const r = spawnSync(process.execPath, [tool, ...rest], { stdio: "inherit" });
  return { kind: "exit", code: r.status ?? 1 };
}

function dbCreateCli(rest: string[]): VerbOutput {
  let name: string | undefined;
  let flagArgv = rest;
  if (rest[0] !== undefined && !rest[0].startsWith("--")) { name = rest[0]; flagArgv = rest.slice(1); }
  let flags;
  try { flags = typedFlags(flagArgv, { value: ["--ext", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }); }
  catch (e) {
    return { kind: "usage-error", message: `homelab db create: ${e instanceof Error ? e.message : String(e)}`, usage: dbCreateUsage() };
  }
  if (flags.bool("--help")) return { kind: "help", text: dbCreateUsage() };
  const num = (k: string): number | undefined => {
    const v = flags.str(k);
    return v === undefined ? undefined : Number(v);
  };
  const input: DbCreateInput = {
    name: name ?? "",
    ext: flags.str("--ext")?.split(",").map((s) => s.trim()).filter((s) => s !== ""),
    wait: flags.bool("--wait"),
    pollMs: num("--poll-ms"),
    deadlineMs: num("--deadline-ms"),
  };
  const bad = dbCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab db create: ${bad}`, usage: dbCreateUsage() };
  const envelope = DB_CREATE.op(input);
  return { kind: "result", json: flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

// db url 패스스루 — 기존 도구(tools/db-url.ts)를 같은 동작으로 재노출한다: argv 그대로,
// stdio 상속(평문 비노출 규율 포함 그 도구의 출력 계약 그대로), 종료코드 전파.
function dbUrlCli(rest: string[]): VerbOutput {
  const tool = fileURLToPath(new URL("./db-url.ts", import.meta.url));
  const r = spawnSync(process.execPath, [tool, ...rest], { stdio: "inherit" });
  return { kind: "exit", code: r.status ?? 1 };
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
  if (out.kind === "exit") return out.code;
  const sink = out.json ? process.stderr : process.stdout;
  for (const line of out.human) sink.write(line + "\n");
  if (out.json) process.stdout.write(JSON.stringify(out.envelope, null, 2) + "\n");
  return out.envelope.exitCode;
}

process.exitCode = main(process.argv.slice(2));
