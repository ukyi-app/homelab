#!/usr/bin/env bun
// homelab CLI 셸 — 앱 배포·리소스 조작 통합 진입점(워킹 스켈레톤: doctor).
// 이 파일은 CLI 관심사만 갖는다: argv 파싱·--help·사람용 렌더링·stdout 순수성·종료코드.
// 동사의 실체(operation catalog)는 lib/verbs.ts, 계약 상수는 lib/contract.ts가 SSOT다 —
// 이 bin 모듈은 import 시 main이 실행되므로 MCP 등 다른 소비자는 lib 쪽을 import한다
// (structure r1 A1·B1). 셰뱅+exec 비트는 이 파일만 예외: package.json bin("homelab")의
// 대상이라 `bun link`가 전역 PATH에 심링크한다(test_shebang-exec.bats가 bin 선언에서 파생).
import { spawnSync } from "node:child_process";
import { readSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseCommand, typedFlags, type CommandTree, type ParsedCommand } from "./lib/cli.ts";
import { USAGE_EXIT, type Envelope } from "./lib/contract.ts";
import { APP_NAME_RE } from "./lib/identity.ts";
import { WAIT_DEFAULTS } from "./lib/mutation.ts";
import type { TypedFlags } from "./lib/cli.ts";
import { APP_CREATE, APP_INIT, APP_SECRETS, APP_TEARDOWN, CACHE_CREATE, DB_CREATE, DOCTOR, STATUS, VERBS, appCreateInputError, appTeardownInputError, cacheCreateInputError, dbCreateInputError, type AppCreateInput, type AppTeardownInput, type CacheCreateInput, type DbCreateInput } from "./lib/verbs.ts";
import { appSecretsInputError, type AppSecretsInput } from "./lib/secrets.ts";
import { appInitInputError, type AppInitInput } from "./lib/init.ts";
import { runMcpServer } from "./lib/mcp.ts";
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
  "app create": appCreateCli,
  "app secrets": appSecretsCli,
  "app teardown": appTeardownCli,
  "app init": appInitCli,
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
    `  ${"mcp".padEnd(14)}stdio MCP 서버(파괴 제외 전 동사를 tool로 노출 — JSON-RPC 2.0 over stdin/stdout)`,
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

// 변이 어댑터 공용 골격 — "위치 인자 하나 + 플래그" 파싱(cli.ts typedFlags 수렴형과 같은 이유:
// 콜사이트마다 복제되던 분리·try/catch·--help 분기를 한 곳으로). 실패는 usage-error VerbOutput.
type Parsed = { positional?: string; flags: TypedFlags };
function positionalThenFlags(rest: string[], spec: { value: string[]; bool: string[] }, tool: string, usage: () => string): Parsed | VerbOutput {
  let positional: string | undefined;
  let flagArgv = rest;
  if (rest[0] !== undefined && !rest[0].startsWith("--")) { positional = rest[0]; flagArgv = rest.slice(1); }
  try { return { positional, flags: typedFlags(flagArgv, spec) }; }
  catch (e) { return { kind: "usage-error", message: `${tool}: ${e instanceof Error ? e.message : String(e)}`, usage: usage() }; }
}
const isOutput = (x: Parsed | VerbOutput): x is VerbOutput => "kind" in x;
// 숫자 플래그 — 부재=undefined, 형식 검증은 동사의 입력 술어(waitInputError 등)가 한다.
const numFlag = (flags: TypedFlags, k: string): number | undefined => {
  const v = flags.str(k);
  return v === undefined ? undefined : Number(v);
};
const WAIT_FLAG_LINES = [
  `  --poll-ms <n>      폴링 간격(기본 ${WAIT_DEFAULTS.pollMs} — 시간 주입 심)`,
  `  --deadline-ms <n>  전체 데드라인(기본 ${WAIT_DEFAULTS.deadlineMs} — 시간 주입 심)`,
  "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
  "",
];

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
    ...WAIT_FLAG_LINES,
  ].join("\n");
}

function renderMutation(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  const lines = [`${envelope.verb} ${r.name}${r.correlation ? ` — correlation ${r.correlation}` : ""}`];
  if (r.chain) {
    lines.push(r.chain.mode === "chain"
      ? `연쇄: 앱 레포 안 — ${r.chain.sealSkipped === true ? "재봉인 생략(--no-seal)" : "seal 실행"} · ${r.chain.pushed === true ? "봉인본 갱신 커밋 push됨" : r.chain.pushed === false ? "커밋 없음" : "선행 조건 단계"}${r.chain.headSha ? ` · HEAD ${String(r.chain.headSha).slice(0, 7)}` : ""}`
      : "연쇄: 앱 레포 밖 — 디스패치만");
  }
  if (r.run?.url) lines.push(`run: ${r.run.url}${r.run.conclusion ? ` (${r.run.conclusion})` : ""}${r.run.failedJobs ? ` · 실패 잡: ${r.run.failedJobs.join(", ")}` : ""}`);
  if (r.pr?.url) lines.push(`PR: ${r.pr.url} · merged ${OX[String(r.pr.merged)]}${r.pr.mergeSha ? ` · merge SHA ${r.pr.mergeSha}` : ""}`);
  if (Array.isArray(r.applications)) {
    for (const a of r.applications) {
      if (a.error) lines.push(`Application ${a.name}: 조회 실패 — ${a.error}`);
      // teardown(absence): 존재/부재 판정 — sync/health가 아니라 present 필드를 쓴다.
      else if (a.present !== undefined) lines.push(`Application ${a.name}: ${a.present ? "아직 존재 — prune 진행 중" : "부재 — prune 완료"}`);
      else lines.push(`Application ${a.name}: sync ${a.sync} · health ${a.health} · rev ${a.revision} · 후손 ${OX[String(a.descendant)]}${a.surfaceOk !== undefined ? ` · 표면 ${OX[String(a.surfaceOk)]}` : ""}`);
    }
  }
  if (r.dnsReclaim) lines.push(`DNS 회수: ${r.dnsReclaim} 소관(이 명령의 관측 대상 아님)`);
  if (envelope.omitted.includes("live")) lines.push("라이브(ArgoCD) 수렴: 생략 — KUBECONFIG 미설정(머지까지만 확인)");
  if (r.pendingReason) lines.push(`대기: ${r.pendingReason}`);
  if (r.error) lines.push(`오류: ${r.error}`);
  lines.push(`결과: ${envelope.variant}`);
  return lines;
}

function appCreateUsage(): string {
  return [
    "사용법: homelab app create <app> [--wait] [--json]",
    "",
    "빌드된 앱(GHCR 이미지 존재)을 homelab에 등록한다 — create-app 디스패처를 correlation 수령증과",
    "함께 트리거하고 run을 추적한다. create-app은 **수동 머지** 동사다(머지 = 공개 승인,",
    "auto-merge 없음): --wait는 승인 경계를 약화하지 않고, 미머지면 '사람 머지 대기' 바운디드",
    "pending을 반환하며, 대기 중 머지가 관측되면 라이브 수렴(<app>-prod Application + 표면)을 이어간다.",
    "  --wait             머지 관측 + Application 수렴까지 대기(미머지 = 바운디드 pending)",
    ...WAIT_FLAG_LINES,
  ].join("\n");
}

function appCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab app create", appCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appCreateUsage() };
  const input: AppCreateInput = { app: p.positional ?? "", wait: p.flags.bool("--wait"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms") };
  const bad = appCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app create: ${bad}`, usage: appCreateUsage() };
  const envelope = APP_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

function appSecretsUsage(): string {
  return [
    "사용법: homelab app secrets <app> [--wait] [--json]",
    "",
    "앱 시크릿 봉인본을 배선한다. 실행 디렉토리가 그 앱 레포(.app-config.yml 마커 + canonical remote)면",
    "seal(앱 레포의 tools/seal-secret.mts) → 봉인본만 커밋 → push → 원격 main 도달성 확인 → update-secrets",
    "디스패치를 연쇄하고, 선행 조건(main 브랜치·클린 트리·canonical remote) 중 하나라도 실패면 디스패치",
    "없이 거부한다. 앱 레포 밖이면 디스패치만 한다(이미 push된 봉인본 재배선). 평문은 출력되지 않는다.",
    "  --wait             auto-merge 머지 + <app>-prod Application 수렴까지 대기(동일 봉인본이면 no-op 검증)",
    "  --no-seal          재봉인 없이 이미 커밋·push된 봉인본을 재디스패치(push 성공·디스패치 실패 후 재실행)",
    "                     — kubeseal 암호문은 매번 달라 재봉인은 언제나 새 커밋·새 PR·파드 롤링이다",
    ...WAIT_FLAG_LINES,
  ].join("\n");
}

function appSecretsCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--no-seal", "--json", "--help"] }, "homelab app secrets", appSecretsUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appSecretsUsage() };
  const input: AppSecretsInput = { app: p.positional ?? "", wait: p.flags.bool("--wait"), noSeal: p.flags.bool("--no-seal"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms") };
  const bad = appSecretsInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app secrets: ${bad}`, usage: appSecretsUsage() };
  const envelope = APP_SECRETS.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

function appTeardownUsage(): string {
  return [
    "사용법: homelab app teardown <app> --confirm <app> [--wait] [--json]",
    "",
    "앱을 철거한다 — teardown-app 디스패처를 correlation 수령증과 함께 트리거한다. teardown-app은",
    "**수동 머지** 동사다(머지 = 파괴 승인, auto-merge 없음). 파괴 오발사를 막기 위해 앱 이름 재입력을",
    "요구한다: --confirm 값이 <app>과 정확히 일치해야 하고, 플래그가 없으면 TTY에서 재입력을 프롬프트하며,",
    "비-TTY(스크립트)에서는 거부한다. --wait의 종결은 다른 동사와 다르다 — 삭제 대상 Application은",
    "Healthy가 될 수 없으므로, 성공 = 머지 관측 + 생성됐던 Application의 **부재**(prune 완료)다.",
    "DNS 회수는 iac/tf-reconcile 소관이라 이 명령의 관측 대상이 아니다(결과에 명시).",
    "  --confirm <app>    파괴 확인 — 철거할 앱 이름 재입력(불일치·비-TTY 무플래그 = 거부)",
    "  --wait             머지 관측 + Application 부재(prune)까지 대기(미머지 = 바운디드 pending)",
    ...WAIT_FLAG_LINES,
  ].join("\n");
}

// 파괴 확인 — --confirm 플래그가 없을 때. TTY면 앱 이름 재입력을 프롬프트하고 한 줄을 동기로 읽어
// 반환, 비-TTY(스크립트·파이프)면 undefined(= 거부, 콜사이트가 일치 검사로 처리한다). isTTY를
// 주입 가능하게 만들지 않는다 — 그러면 프로덕션에 테스트 전용 분기가 생기고 정작 진짜 TTY 동작은
// 검증되지 않는다. 테스트는 pty(util-linux script)로 실물 터미널을 만든다.
function promptConfirm(app: string): string | undefined {
  if (process.stdin.isTTY !== true) return undefined;
  process.stderr.write(`파괴 확인: 철거할 앱 이름 '${app}'을 다시 입력하세요 > `);
  const buf = Buffer.alloc(256);
  let n = 0;
  try { n = readSync(0, buf, 0, buf.length, null); } catch { return undefined; }
  return buf.subarray(0, n).toString("utf8").trim();
}

function appTeardownCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--confirm", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab app teardown", appTeardownUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appTeardownUsage() };
  const app = p.positional ?? "";
  // 앱 이름 형식은 confirm 프롬프트 전에 검증한다(불량 이름으로 프롬프트를 띄우지 않는다).
  if (!APP_NAME_RE.test(app)) return { kind: "usage-error", message: `homelab app teardown: 앱 이름 형식 불량(소문자 kebab, 2..40): ${app}`, usage: appTeardownUsage() };
  // 파괴 확인 가드 — 플래그가 있으면 그 값, 없으면 TTY 재입력(비-TTY면 undefined). 일치해야만 진행.
  const confirm = p.flags.str("--confirm") ?? promptConfirm(app);
  if (confirm !== app) {
    return { kind: "usage-error", message: `homelab app teardown: 파괴 확인 실패 — '${app}' 재입력이 일치하지 않는다(입력: ${confirm ?? "(없음 — 비-TTY에는 --confirm 필수)"})`, usage: appTeardownUsage() };
  }
  const input: AppTeardownInput = { app, confirm, wait: p.flags.bool("--wait"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms") };
  const bad = appTeardownInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app teardown: ${bad}`, usage: appTeardownUsage() };
  const envelope = APP_TEARDOWN.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

function appInitUsage(): string {
  return [
    "사용법: homelab app init <app> --archetype fullstack|api|site|worker [--public] [--dispatch-secrets <경로>] [--adopt] [--json]",
    "",
    "앱 레포의 시작을 끝까지 만든다(멱등·재개 가능): preflight(부수효과 0) → 템플릿에서 레포 생성",
    "(기본 private) → 클론 → 스캐폴더 비대화형 실행 → invocation marker 기록 → 커밋·첫 push(빌드",
    "트리거) → [--dispatch-secrets면 디스패치 시크릿 쌍 설정]. 실패 후 같은 명령을 다시 실행하면",
    "도달한 체크포인트부터 수렴한다. 소유 증명은 마커(.homelab-init)이고, 마커 없는 기존 레포는",
    "거부한다 — 확인 후 --adopt로만 이어갈 수 있다. private key 값은 어떤 출력에도 나타나지 않는다.",
    "  --archetype <a>    fullstack|api|site|worker (kind는 아키타입 유도값 — CONTEXT.md 용어)",
    "  --public           공개 레포로 생성(기본 private)",
    "  --dispatch-secrets <경로>  App 키 디렉토리(app-id·private-key.pem) — 새 레포에 디스패치 시크릿 쌍 설정",
    "  --adopt            마커 없는 기존 레포를 명시 입양(사용자 확인 — 소유 미증명 레포 이어가기)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
  ].join("\n");
}

function renderInit(envelope: Envelope): string[] {
  const r = envelope.result as Record<string, any>;
  const lines = [`app init ${r.app} — 아키타입 ${r.archetype} · ${r.public ? "public" : "private"} · repo ${r.repo}`];
  if (r.error) {
    lines.push(`체크포인트: ${r.checkpoint ?? "?"}`);
    lines.push(`오류: ${r.error}`);
  } else {
    const st: string[] = [];
    if (r.created) st.push("레포 생성");
    if (r.adopted) st.push("입양");
    if (r.scaffolded) st.push("스캐폴드");
    if (r.pushed) st.push("첫 push");
    lines.push(`단계: ${st.length ? st.join(" · ") : "변경 없음(이미 완료)"}`);
  }
  if (r.secrets) lines.push(`디스패치 시크릿: App ID ${OX[String(r.secrets.appId)]} · private key ${OX[String(r.secrets.privateKey)]}`);
  lines.push(`결과: ${envelope.variant}`);
  return lines;
}

function appInitCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--archetype", "--dispatch-secrets"], bool: ["--public", "--adopt", "--json", "--help"] }, "homelab app init", appInitUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appInitUsage() };
  const input: AppInitInput = {
    app: p.positional ?? "",
    archetype: p.flags.str("--archetype") ?? "",
    public: p.flags.bool("--public"),
    dispatchSecrets: p.flags.str("--dispatch-secrets"),
    adopt: p.flags.bool("--adopt"),
  };
  const bad = appInitInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app init: ${bad}`, usage: appInitUsage() };
  const envelope = APP_INIT.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderInit(envelope) };
}

function cacheCreateUsage(): string {
  return [
    "사용법: homelab cache create <name> [--maxmemory-mi 16..1024] [--wait] [--json]",
    "",
    "앱별 Valkey 캐시를 생성한다 — create-cache 디스패처를 correlation 수령증과 함께 트리거하고",
    "자기 run을 특정해 conclusion까지 추적한다(PR-first — 머지가 곧 적용).",
    "  --maxmemory-mi <n> maxmemory(Mi, 16..1024 — 생략 시 디스패처 기본 64)",
    "  --wait             auto-merge 머지 + Application 집합(cache-prod·data-conn-prod) 수렴까지 대기",
    ...WAIT_FLAG_LINES,
  ].join("\n");
}

function cacheCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--maxmemory-mi", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab cache create", cacheCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: cacheCreateUsage() };
  const input: CacheCreateInput = { name: p.positional ?? "", maxmemoryMi: numFlag(p.flags, "--maxmemory-mi"), wait: p.flags.bool("--wait"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms") };
  const bad = cacheCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab cache create: ${bad}`, usage: cacheCreateUsage() };
  const envelope = CACHE_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderMutation(envelope) };
}

// cache url 패스스루 — 기존 도구(tools/cache-url.ts)를 같은 동작으로 재노출한다.
function cacheUrlCli(rest: string[]): VerbOutput {
  const tool = fileURLToPath(new URL("./cache-url.ts", import.meta.url));
  const r = spawnSync(process.execPath, [tool, ...rest], { stdio: "inherit" });
  return { kind: "exit", code: r.status ?? 1 };
}

function dbCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--ext", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab db create", dbCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: dbCreateUsage() };
  const input: DbCreateInput = {
    name: p.positional ?? "",
    ext: p.flags.str("--ext")?.split(",").map((x) => x.trim()).filter((x) => x !== ""),
    wait: p.flags.bool("--wait"),
    pollMs: numFlag(p.flags, "--poll-ms"),
    deadlineMs: numFlag(p.flags, "--deadline-ms"),
  };
  const bad = dbCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab db create: ${bad}`, usage: dbCreateUsage() };
  const envelope = DB_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: renderMutation(envelope) };
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

function mcpUsage(): string {
  return [
    "사용법: homelab mcp",
    "",
    "stdio MCP 서버를 연다(JSON-RPC 2.0, 개행 구분, stdin→stdout). 파괴 제외 전 동사(doctor·status·",
    "db create/url·cache create/url·app init/create/secrets)를 tool로 노출한다 — teardown은 노출하지 않는다.",
    "각 tool 호출은 동기·바운디드(--wait류 장기 대기 없음)이고, 결과는 CLI --json과 같은 계약 오브젝트다.",
    "디렉토리 추론이 없다: app secrets는 repoPath, app init은 parentDir를 명시 입력으로 받는다.",
    "",
  ].join("\n");
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

// 진입점 — `mcp`는 동사가 아니라 transport 모드라 catalog 밖에서 특별 라우팅한다(서버가 자기 자신을
// 노출하지 않도록 VERBS에도 없다). 서버는 비동기(stdin EOF까지)라 main()의 동기 경로와 분리한다.
const ARGV = process.argv.slice(2);
if (ARGV[0] === "mcp") {
  if (ARGV[1] === "--help") { process.stdout.write(mcpUsage()); process.exitCode = 0; }
  else if (ARGV.length > 1) { process.stderr.write(`homelab mcp: 알 수 없는 인자: ${ARGV.slice(1).join(" ")}\n\n${mcpUsage()}`); process.exitCode = USAGE_EXIT; }
  else { runMcpServer().then((code) => { process.exitCode = code; }); }
} else {
  process.exitCode = main(ARGV);
}
