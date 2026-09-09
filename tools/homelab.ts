#!/usr/bin/env bun
// homelab CLI 셸 — 앱 배포·리소스 조작 통합 진입점(전 동사 착지: lib/verbs.ts VERBS + mcp).
// 이 파일은 CLI 관심사만 갖는다: argv 파싱·--help·사람용 렌더링·stdout 순수성·종료코드.
// 동사의 실체(operation catalog)는 lib/verbs.ts, 계약 상수는 lib/contract.ts가 SSOT다 —
// 이 bin 모듈은 import 시 main이 실행되므로 MCP 등 다른 소비자는 lib 쪽을 import한다.
// 셰뱅+exec 비트는 이 파일만 예외: package.json bin("homelab")의
// 대상이라 `bun link`가 전역 PATH에 심링크한다(test_shebang-exec.bats가 bin 선언에서 파생).
import { readSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { CommandParseError, parseCommand, skipMarker, typedFlags, type CommandTree, type ParsedCommand } from "./lib/cli.ts";
import { cacheUrlInputError, dbUrlInputError, type CacheUrlInput, type DbUrlInput } from "./lib/conn-url.ts";
import { ENVELOPE, EXIT, USAGE_EXIT, assertEnvelope, type Envelope } from "./lib/contract.ts";
import { git } from "./lib/exec.ts";
import { APP_NAME_RE } from "./lib/identity.ts";
import { WAIT_DEFAULTS, waitInputError, type ProgressEvent } from "./lib/mutation.ts";
import type { TypedFlags } from "./lib/cli.ts";
import { APP_CREATE, APP_INIT, APP_SECRETS, APP_TEARDOWN, CACHE_CREATE, CACHE_URL, DB_CREATE, DB_URL, DOCTOR, STATUS, VERBS, appCreateInputError, appTeardownInputError, cacheCreateInputError, dbCreateInputError, type AppCreateInput, type AppTeardownInput, type CacheCreateInput, type DbCreateInput } from "./lib/verbs.ts";
import { appSecretsInputError, type AppSecretsInput } from "./lib/secrets.ts";
import { appInitInputError, type AppInitInput } from "./lib/init.ts";
import { ARCHETYPES } from "./lib/platform.ts";
import { runMcpServer } from "./lib/mcp.ts";
import { renderDoctor, renderInit, renderMutation, renderStatus, renderUrl } from "./lib/render.ts";
import { statusInputError, type StatusInput } from "./lib/status.ts";

// 동사 실행의 세 결말 — 프로세스 관심사(stdout 채널·종료코드)는 전부 main이 소유한다.
// (패스스루 "exit" 결말은 url 동사의 catalog 승격으로 소멸 — 전 동사가 op envelope 계약이다.)
type VerbOutput =
  | { kind: "help"; text: string }
  | { kind: "usage-error"; message: string; usage: string }
  | { kind: "result"; json: boolean; envelope: Envelope; human: () => string[] };

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

// 종료코드 절 — 계약(x-contract)에서 **파생 렌더**한다(리터럴 복제 금지: 스키마가 SSOT다).
// 코드별로 묶어 그 코드를 내는 variant를 같은 줄에 적는다 — 스크립트는 코드로, 에이전트는
// variant로 분기하기 때문에 둘의 관계가 한 줄 안에 보여야 한다. usage(파싱 실패)는 variant가
// 아니라 코드만 있는 결말이라 따로 적는다(스크립트가 가장 자주 밟는데 어휘에 없었다).
function exitCodeLines(): string[] {
  const byCode = new Map<number, string[]>();
  for (const [variant, code] of Object.entries(EXIT)) byCode.set(code, [...(byCode.get(code) ?? []), variant]);
  // usage는 variant가 아니라 파싱 실패의 코드다 — 같은 표에 넣되 그 사실을 꼬리에 적는다.
  const note = new Map<number, string>([[USAGE_EXIT, "  ← variant가 아니라 플래그·인자 해석 실패(이때만 결과 오브젝트가 없다)"]]);
  byCode.set(USAGE_EXIT, [...(byCode.get(USAGE_EXIT) ?? []), "usage"]);
  const rows = [...byCode.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([code, variants]) => `  ${code}  ${variants.join(" · ")}${note.get(code) ?? ""}`);
  return [
    "종료코드:",
    ...rows,
    "  같은 코드를 나눠 갖는 variant가 있다 — 스크립트는 종료코드로, 에이전트는 variant로 분기한다.",
    "",
  ];
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
    "공통 옵션(mcp 제외 — 그 모드는 인자를 받지 않는다):",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(계약: tools/cli-result-schema.json)",
    "  --help        사용법 출력(`-h`·`help` 별칭 — 동사·그룹 노드 어디서든 stdout·exit 0)",
    "  --version     진입점 경로·체크아웃 HEAD·결과 계약 schema 출력",
    "",
    ...exitCodeLines(),
    ...LEVER_LINES,
  ].join("\n");
}

function doctorUsage(): string {
  return [
    "사용법: homelab doctor [--json]",
    "",
    "플랫폼 전제 진단 — gh 인증·버전·HOMELAB_OWNER 일치·토큰 스코프, bun·git·kubeseal·kubectl 존재,",
    "git 커밋 신원·GitHub https 자격 helper(부재는 경고), KUBECONFIG(부재는 경고·콜론 목록 지원),",
    "템플릿 접근성·호환성(스캐폴더 비대화형 계약·TARGETARCH)을 점검한다.",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
    ...needsLines(DOCTOR),
  ].join("\n");
}

// 변이 어댑터 공용 골격 — "위치 인자 하나 + 플래그" 파싱(cli.ts typedFlags 수렴형과 같은 이유:
// 콜사이트마다 복제되던 분리·try/catch·--help 분기를 한 곳으로). 실패는 usage-error VerbOutput.
// spec의 세 축: value=값 플래그 · bool=불리언 · num=값 플래그 중 **십진 정수 표기**를 요구하는 것
// (값 목록에 자동 편입), alias=위치 인자와 같은 것을 지정하는 플래그(예: url 동사의 --name).
type Parsed = { positional?: string; flags: TypedFlags };
type FlagPlan = { value: string[]; bool: string[]; num?: string[]; alias?: string };
// 십진 정수 표기 술어 — 범위 검사는 그대로 동사의 입력 술어(waitInputError·cacheCreateInputError)가
// 소유하고 여기서는 **표기**만 본다. Number()는 "1e3"·"0x10"·" 5 "·"5.0"을 조용히 삼켰고(실측)
// 거부 문구가 원문 대신 NaN/0을 인용했다(함정 원장 「TS 바닥값은 coercion 뒤에서 조용히 꺼진다」).
const DECIMAL_RE = /^\d+$/;
function positionalThenFlags(rest: string[], spec: FlagPlan, tool: string, usage: () => string): Parsed | VerbOutput {
  const fail = (message: string): VerbOutput => ({ kind: "usage-error", message: `${tool}: ${message}`, usage: usage() });
  const value = spec.num === undefined ? spec.value : [...spec.value, ...spec.num];
  // 별칭 충돌 — 이름을 위치 인자와 별칭 플래그로 동시에 주면 어느 쪽이 이겼는지가 침묵으로 갈린다
  // (실측: --name이 이겨 엉뚱한 리소스의 자격이 .env.local에 기록될 수 있었다). 검출은 원본 argv를
  // parseFlags와 **같은 걸음**(값 플래그는 다음 토큰을 소비)으로 훑어 순서와 무관하게 두 값을 인용한다.
  // 미지 옵션을 만나면 스캔을 접는다 — 그 진단은 parseFlags가 소유한다(오진 방지).
  if (spec.alias !== undefined) {
    let pos: string | undefined;
    let aliasValue: string | undefined;
    let scanned = true;
    for (let i = 0; i < rest.length; i++) {
      const a = rest[i]!;
      if (!a.startsWith("--")) { pos ??= a; continue; }
      if (spec.bool.includes(a)) continue;
      if (!value.includes(a)) { scanned = false; break; }
      if (a === spec.alias) aliasValue ??= rest[i + 1];
      i++;
    }
    if (scanned && pos !== undefined && aliasValue !== undefined) {
      return fail(`이름이 두 번 지정됐다(위치 인자 '${pos}' · ${spec.alias} '${aliasValue}') — 하나만 준다`);
    }
  }
  let positional: string | undefined;
  let flagArgv = rest;
  // `-`로 시작하는 토큰은 위치 인자가 아니다 — 도움말을 구한 `-h`가 '이름 형식 불량: -h'로
  // 돌아오던 자리다. 거부 문구는 parseFlags가 소유한다(단일 대시 규약 한 곳).
  if (rest[0] !== undefined && !rest[0].startsWith("-")) { positional = rest[0]; flagArgv = rest.slice(1); }
  let flags: TypedFlags;
  try { flags = typedFlags(flagArgv, { value, bool: spec.bool }); }
  catch (e) { return fail(e instanceof Error ? e.message : String(e)); }
  for (const k of spec.num ?? []) {
    const v = flags.str(k);
    if (v !== undefined && !DECIMAL_RE.test(v)) return fail(`${k} 값은 십진 정수여야 한다: '${v}'`);
  }
  return { positional, flags };
}
const isOutput = (x: Parsed | VerbOutput): x is VerbOutput => "kind" in x;
// 숫자 플래그 — 부재=undefined. 표기는 spec.num 술어가 이미 걸렀으므로 Number()가 정확하고,
// 범위(양의 정수·16..1024)는 그대로 동사의 입력 술어가 소유한다.
const numFlag = (flags: TypedFlags, k: string): number | undefined => {
  const v = flags.str(k);
  return v === undefined ? undefined : Number(v);
};
// ⚠️ 두 플래그는 테스트가 시간을 밀리초로 줄이는 주입 심이기도 하지만, **데드라인 조정은 정당한
// 운영 노브**다(--wait의 pending은 실패가 아니라 바운디드 결과다). 사용자용 라벨에 '심(seam)'이라는
// 레포 내부 어휘를 노출하면 '쓰지 말라'로도 '써도 된다'로도 읽힌다 — 그 사실은 여기 주석과
// tools/README.md에 남기고 help에는 기본값만 적는다.
const WAIT_FLAG_LINES = [
  `  --poll-ms <n>      폴링 간격(기본 ${WAIT_DEFAULTS.pollMs}ms)`,
  `  --deadline-ms <n>  전체 데드라인(기본 ${WAIT_DEFAULTS.deadlineMs}ms = ${WAIT_DEFAULTS.deadlineMs / 60000}분)`,
  "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
  "",
];

// 관측 레버 — 이미 존재하는 유일한 디버그 축인데 문서가 0건이었다. 값·stdin은 절대
// 기록되지 않는다(kubeseal 평문이 지나는 채널이라 seam이 stdin을 배제한다 — 계약 테스트 존재).
// 사후 소급이 불가능하므로 '사전 무장' opt-in임을 문구가 말한다.
const LEVER_LINES = [
  "관측 레버(opt-in · 사전 무장 — 소급 불가):",
  "  HOMELAB_EXEC_LEDGER=<file>  외부 명령 argv를 JSONL로 append(값·stdin은 미기록)",
  "",
];

// 요구 도메인 한 줄 — 값은 catalog 행(VerbShape.needs)이 소유하고 여기는 렌더만 한다.
const needsLines = (verb: { needs: string }): string[] => [`요구: ${verb.needs}`, ""];

// 진행 표시 — 변이 엔진이 낸 단계 전이 이벤트를 사람용 한 줄로 옮겨 **stderr**에 즉시 쓴다.
// 계약(x-contract.stdout) "사람용 텍스트·진행 표시는 전부 stderr"의 실행형이라 --json이든 아니든
// stdout은 건드리지 않는다: --json이면 stdout은 envelope 하나뿐이고, 사람 모드에서도 진행 줄은
// '결과'가 아니라 관측이다(골든 생성 줄이 `2>/dev/null`이라 생성물도 무영향).
// 문구가 셸에 있는 이유: 엔진은 표현을 모른다(op는 Envelope만 반환) — 그래서 MCP는 이 sink를
// 주입하지 않고, 같은 엔진 호출이 stdio JSON-RPC 스트림을 오염시키지 않는다.
const PROGRESS_LINE: Record<ProgressEvent["stage"], (e: ProgressEvent) => string> = {
  // 중복 PR preflight가 눈을 감은 경우에만 나온다(성공 관측은 조용하다 — 정상 경로의 노이즈를
  // 늘리지 않는다). 극성이 fail-open이라 이 줄 뒤에도 디스패치는 그대로 나가므로, 문구가 그
  // 사실을 함께 말한다. Record 타입이라 새 stage를 더하면 여기 렌더가 없을 때 컴파일이 죽는다.
  "preflight-blind": (e) => `진행: 중복 PR preflight 관측 실패(디스패치는 계속) — ${e.note}`,
  dispatched: (e) => `진행: 디스패치 접수 — correlation ${e.correlation}`,
  identified: (e) => `진행: run 식별 — ${e.runUrl}`,
  concluded: (e) => `진행: run 완료 — ${e.runUrl}`,
  pr: (e) => `진행: PR 특정 — ${e.prUrl}`,
  merged: (e) => `진행: 머지 관측 — merge SHA ${e.sha}`,
};
function progressSink(e: ProgressEvent): void {
  process.stderr.write(PROGRESS_LINE[e.stage](e) + "\n");
}

function statusUsage(): string {
  return [
    "사용법: homelab status [<app>] [--resources | --run <url> [--branch <ref>] | --pr <url>] [--json]",
    "",
    "앱 상태 관찰 — 인자 없음: 전체 앱 목록·요약 + 머지 대기 디스패처 PR(열린 PR 1회 조회 —",
    "실패해도 목록은 그대로 나오고 사유가 실린다). <app>: 배포 핀·바인딩·최근 run·",
    "열린 PR에, KUBECONFIG가 있으면 ArgoCD sync/health를 덧붙인다(없으면 라이브 구간 생략 표시).",
    "핸들 조회: --run/--pr에 GitHub URL을 주면 그 오퍼레이션 단위의 상태를 보고한다(쿼리·프래그먼트",
    "꼬리는 무시하고, job/attempts URL은 run 전체로 승격해 그 사실을 표기한다 — 짧은 번호는 거부).",
    "  --resources   db·캐시 리소스 인벤토리(레포 산출물 역방향 열거 — 로컬 전용, gh 무의존)",
    "  --run <url>   run URL(https://github.com/<o>/<r>/actions/runs/<id>) 핸들 조회",
    "  --branch <ref> --run과 함께: 그 레인 브랜치의 PR을 정확 조회(변이 pending의 run.branch를 그대로)",
    "  --pr <url>    PR URL(https://github.com/<o>/<r>/pull/<n>) 핸들 조회",
    "  --root <dir>  [고급] 앱 산출물 루트(기본: CLI 자신의 레포)",
    "  --json        결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
    ...needsLines(STATUS),
  ].join("\n");
}

function statusCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--run", "--pr", "--branch", "--root"], bool: ["--resources", "--json", "--help"] }, "homelab status", statusUsage);
  if (isOutput(p)) return p;
  const app = p.positional;
  const flags = p.flags;
  if (flags.bool("--help")) return { kind: "help", text: statusUsage() };
  const input: StatusInput = { app, runUrl: flags.str("--run"), prUrl: flags.str("--pr"), branch: flags.str("--branch"), resources: flags.bool("--resources") ? true : undefined, root: flags.str("--root") };
  const bad = statusInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab status: ${bad}`, usage: statusUsage() };
  const envelope = STATUS.op(input);
  return { kind: "result", json: flags.bool("--json"), envelope, human: () => renderStatus(envelope) };
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
    ...needsLines(DB_CREATE),
  ].join("\n");
}

function appCreateUsage(): string {
  return [
    "사용법: homelab app create <app> [--wait] [--json]",
    "",
    "빌드된 앱(GHCR 이미지 존재)을 homelab에 등록한다 — create-app 디스패처를 correlation 수령증과",
    "함께 트리거하고 run을 추적한다. create-app은 **수동 머지** 동사다(머지 = 공개 승인,",
    "auto-merge 없음): --wait는 승인 경계를 약화하지 않고, 미머지면 '사람 머지 대기' 바운디드",
    "pending을 반환하며, 대기 중 머지가 관측되면 라이브 수렴(<app>-prod Application + 표면)을 이어간다.",
    "실제 노출(공개 DNS/tunnel 또는 내부 rewrite)은 이 명령의 관측 대상이 아니다 — 결과의",
    "dnsExposure가 소관을 명시한다(공개=iac/tf-reconcile · 내부=adguard rewrite).",
    "  --wait             머지 관측 + Application 수렴까지 대기(미머지 = 바운디드 pending)",
    ...WAIT_FLAG_LINES,
    ...needsLines(APP_CREATE),
  ].join("\n");
}

function appCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: [], num: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab app create", appCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appCreateUsage() };
  const input: AppCreateInput = { app: p.positional ?? "", wait: p.flags.bool("--wait"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms"), onProgress: progressSink };
  const bad = appCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app create: ${bad}`, usage: appCreateUsage() };
  const envelope = APP_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderMutation(envelope) };
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
    ...needsLines(APP_SECRETS),
  ].join("\n");
}

function appSecretsCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: [], num: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--no-seal", "--json", "--help"] }, "homelab app secrets", appSecretsUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appSecretsUsage() };
  const input: AppSecretsInput = { app: p.positional ?? "", wait: p.flags.bool("--wait"), noSeal: p.flags.bool("--no-seal"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms"), onProgress: progressSink };
  const bad = appSecretsInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app secrets: ${bad}`, usage: appSecretsUsage() };
  const envelope = APP_SECRETS.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderMutation(envelope) };
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
    "DB/캐시(conn·CR·Valkey)는 **비접촉**이라 철거 후에도 그대로 남는다 — 결과의 resourcesRetained가",
    "그 미완 작업을 명시한다(정리는 owner-local `make teardown-resource`, attestation 필요).",
    "  --confirm <app>    파괴 확인 — 철거할 앱 이름 재입력(불일치·비-TTY 무플래그 = 거부)",
    "  --wait             머지 관측 + Application 부재(prune)까지 대기(미머지 = 바운디드 pending)",
    ...WAIT_FLAG_LINES,
    ...needsLines(APP_TEARDOWN),
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
  const p = positionalThenFlags(rest, { value: ["--confirm"], num: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab app teardown", appTeardownUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appTeardownUsage() };
  const app = p.positional ?? "";
  // 앱 이름 형식은 confirm 프롬프트 전에 검증한다(불량 이름으로 프롬프트를 띄우지 않는다).
  if (!APP_NAME_RE.test(app)) return { kind: "usage-error", message: `homelab app teardown: 앱 이름 형식 불량(소문자 kebab, 2..40): ${app}`, usage: appTeardownUsage() };
  // 대기 플래그 **범위** 검증은 confirm 프롬프트 **앞**이다 — 뒤에 두면 사람이 파괴
  // 확인을 다시 타이핑한 **뒤에야** usage 오류를 본다. 표기 축(십진 정수)은 positionalThenFlags가
  // 이미 위에서 잡았고, 여기서 남는 것은 양수 범위다. 술어는 그대로 동사가 소유한다.
  const pollMs = numFlag(p.flags, "--poll-ms");
  const deadlineMs = numFlag(p.flags, "--deadline-ms");
  const waitBad = waitInputError({ pollMs, deadlineMs });
  if (waitBad) return { kind: "usage-error", message: `homelab app teardown: ${waitBad}`, usage: appTeardownUsage() };
  // 파괴 확인 가드 — 플래그가 있으면 그 값, 없으면 TTY 재입력(비-TTY면 undefined). 일치해야만 진행.
  const confirm = p.flags.str("--confirm") ?? promptConfirm(app);
  if (confirm !== app) {
    return { kind: "usage-error", message: `homelab app teardown: 파괴 확인 실패 — '${app}' 재입력이 일치하지 않는다(입력: ${confirm ?? "(없음 — 비-TTY에는 --confirm 필수)"})`, usage: appTeardownUsage() };
  }
  const input: AppTeardownInput = { app, confirm, wait: p.flags.bool("--wait"), pollMs, deadlineMs, onProgress: progressSink };
  const bad = appTeardownInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app teardown: ${bad}`, usage: appTeardownUsage() };
  const envelope = APP_TEARDOWN.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderMutation(envelope) };
}

function appInitUsage(): string {
  const choices = ARCHETYPES.join("|"); // 어휘는 platform.ts SSOT 파생(리터럴 사본 금지 — test_platform.bats 가드)
  return [
    `사용법: homelab app init <app> --archetype ${choices} [--repo-public] [--parent-dir <절대경로>] [--dispatch-secrets <경로>] [--adopt] [--json]`,
    "",
    "앱 레포의 시작을 끝까지 만든다(멱등·재개 가능): preflight(부수효과 0) → 템플릿에서 레포 생성",
    "(기본 private) → 클론 → 스캐폴더 비대화형 실행 → invocation marker 기록 → 커밋·첫 push(빌드",
    "트리거) → [--dispatch-secrets면 디스패치 시크릿 쌍 설정]. 실패 후 같은 명령을 다시 실행하면",
    "도달한 체크포인트부터 수렴한다. 소유 증명은 마커(.homelab-init)이고, 마커 없는 기존 레포는",
    "거부한다 — 확인 후 --adopt로만 이어갈 수 있다. private key 값은 어떤 출력에도 나타나지 않는다.",
    `  --archetype <a>    ${choices} (kind는 아키타입 유도값 — CONTEXT.md 용어)`,
    "  --repo-public      **GitHub 레포**를 공개로 생성(기본 private) — 앱의 공개 노출이 아니다.",
    "                     앱 노출은 클론된 앱 레포 .app-config.yml의 route.public이 정한다(손 편집).",
    "  --parent-dir <절대경로>  클론할 부모 디렉토리(기본: 현재 디렉토리 — 클론 위치는 <부모>/<app>).",
    "                     homelab 체크아웃 안(그 하위 포함)은 거부한다: 중첩 레포는 로컬 게이트가 보지 못한다.",
    "  --dispatch-secrets <경로>  App 키 디렉토리(app-id·private-key.pem) — 새 레포에 디스패치 시크릿 쌍 설정",
    "                     ⚠️ dispatch App은 2026-09-03 org **설치 없음**(AGENTS.md 트리거 경계) — 재설치",
    "                     전에는 이 쌍을 심어도 무효다(배포 반영은 bump-poll 크론 백스톱뿐). 키 디렉토리는",
    "                     클론 트리 밖에 둔다(안이면 거부 — 첫 커밋의 add -A가 키를 원격에 올린다).",
    "  --adopt            마커 없는 기존 레포를 명시 입양(사용자 확인 — 소유 미증명 레포 이어가기)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
    ...needsLines(APP_INIT),
  ].join("\n");
}

function appInitCli(rest: string[]): VerbOutput {
  // `--public`은 **의도적으로 파서 어휘에 남긴다** — 지우면 typedFlags의 '알 수 없는 옵션'이 되어
  // 두 뜻이 갈렸다는 사실을 말할 자리가 없다. 이름 충돌은 실재했다: 여기의 가시성은
  // GitHub **레포**이고, 실물 스캐폴더의 --public은 `.app-config.yml`의 route.public(앱 **노출**)이라
  // `app init foo --public`은 '공개 레포 + 내부 전용 앱'을 만들었다. 가장 흔한 조합(비공개 레포 +
  // 공개 앱)은 이 동사의 플래그로는 도달 불가이고 클론된 트리의 파일 편집이 정답이다.
  const p = positionalThenFlags(rest, { value: ["--archetype", "--dispatch-secrets", "--parent-dir"], bool: ["--repo-public", "--public", "--adopt", "--json", "--help"] }, "homelab app init", appInitUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: appInitUsage() };
  if (p.flags.bool("--public")) {
    return {
      kind: "usage-error",
      message: "homelab app init: --public은 --repo-public으로 바뀌었다(GitHub 레포 가시성). 앱의 공개 노출은 이 플래그가 아니라 앱 레포 .app-config.yml의 route.public이며, 클론된 트리에서 편집한다",
      usage: appInitUsage(),
    };
  }
  const input: AppInitInput = {
    app: p.positional ?? "",
    archetype: p.flags.str("--archetype") ?? "",
    public: p.flags.bool("--repo-public"),
    dispatchSecrets: p.flags.str("--dispatch-secrets"),
    adopt: p.flags.bool("--adopt"),
    // MCP의 parentDir과 같은 표면·같은 술어(절대 경로 강제). 미지정은 현재 디렉토리 — 엔진의
    // 기본값이 그대로 쓰인다(undefined를 넘기는 것이 계약, identity.pathInputError 주석).
    parentDir: p.flags.str("--parent-dir"),
  };
  const bad = appInitInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab app init: ${bad}`, usage: appInitUsage() };
  const envelope = APP_INIT.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderInit(envelope) };
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
    ...needsLines(CACHE_CREATE),
  ].join("\n");
}

function cacheCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: [], num: ["--maxmemory-mi", "--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab cache create", cacheCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: cacheCreateUsage() };
  const input: CacheCreateInput = { name: p.positional ?? "", maxmemoryMi: numFlag(p.flags, "--maxmemory-mi"), wait: p.flags.bool("--wait"), pollMs: numFlag(p.flags, "--poll-ms"), deadlineMs: numFlag(p.flags, "--deadline-ms"), onProgress: progressSink };
  const bad = cacheCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab cache create: ${bad}`, usage: cacheCreateUsage() };
  const envelope = CACHE_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderMutation(envelope) };
}

function cacheUrlUsage(): string {
  return [
    "사용법: homelab cache url <name> [--rw] [--host <h>] [--env-local <file>] [--dry-run] [--json]",
    "        (--name <name> 형태도 동등 — 기존 cache:url argv 호환)",
    "",
    "캐시 접속 URL을 .env.local에 기록한다(평문 비출력 — 엔진 소유). 기본 RO, --rw=default 유저.",
    "host 기본은 127.0.0.1(선행: kubectl -n cache port-forward svc/<name> 6379:6379 — 런북 db-cache-access.md).",
    "  --rw               default 유저(관리=RW)로 기록(기본: 읽기 ACL 유저)",
    "  --host <h>         port-forward 타깃 호스트(기본 127.0.0.1 또는 CACHE_LOCAL_HOST)",
    "  --env-local <file> 대상 파일 오버라이드(기본 .env.local)",
    "  --dry-run          계획만(클러스터 무의존)",
    "  (KUBECONFIG 미설정이면 skip: exit 4 + stderr SKIP 마커 — 기록 없이 종료)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "",
    ...needsLines(CACHE_URL),
  ].join("\n");
}

// cache url — conn URL 엔진의 catalog op 소비(패스스루 소멸).
function cacheUrlCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--name", "--host", "--env-local"], bool: ["--rw", "--dry-run", "--json", "--help"], alias: "--name" }, "homelab cache url", cacheUrlUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: cacheUrlUsage() };
  const input: CacheUrlInput = { name: p.flags.str("--name") ?? p.positional ?? "", rw: p.flags.bool("--rw"), host: p.flags.str("--host"), envLocal: p.flags.str("--env-local"), dryRun: p.flags.bool("--dry-run") };
  const bad = cacheUrlInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab cache url: ${bad}`, usage: cacheUrlUsage() };
  const envelope = CACHE_URL.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderUrl(envelope) };
}

function dbCreateCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--ext"], num: ["--poll-ms", "--deadline-ms"], bool: ["--wait", "--json", "--help"] }, "homelab db create", dbCreateUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: dbCreateUsage() };
  const input: DbCreateInput = {
    name: p.positional ?? "",
    ext: p.flags.str("--ext")?.split(",").map((x) => x.trim()).filter((x) => x !== ""),
    wait: p.flags.bool("--wait"),
    pollMs: numFlag(p.flags, "--poll-ms"),
    deadlineMs: numFlag(p.flags, "--deadline-ms"),
    onProgress: progressSink,
  };
  const bad = dbCreateInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab db create: ${bad}`, usage: dbCreateUsage() };
  const envelope = DB_CREATE.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderMutation(envelope) };
}

function dbUrlUsage(): string {
  return [
    "사용법: homelab db url <name> [--rw|--admin] [--host <h>] [--env-local <file>] [--dry-run] [--json]",
    "        (--name <name> 형태도 동등 — 기존 db:url argv 호환)",
    "",
    "클러스터 DB 접속 URL을 .env.local(admin은 .env.admin.local)에 기록한다(평문 비출력 — 엔진 소유).",
    "기본 RO(읽기전용 롤), --rw=owner, --admin=superuser(F2 채널 분리 — .env.admin.local 전용).",
    "  --rw               owner(읽기쓰기)로 기록 (--admin과 상호배타)",
    "  --admin            superuser(GUI 전용 — 대상 파일 오버라이드 불가)",
    "  --host <h>         tailscale LB host(기본 TS_DB_HOST — 런북 db-cache-access.md)",
    "  --env-local <file> 대상 파일 오버라이드(기본 .env.local, admin 제외)",
    "  --dry-run          계획만(클러스터 무의존)",
    "  --json             결과를 계약 오브젝트로 stdout에 출력(사람용 보고는 stderr)",
    "  (KUBECONFIG 미설정이면 skip: exit 4 + stderr SKIP 마커 — 기록 없이 종료)",
    "",
    ...needsLines(DB_URL),
  ].join("\n");
}

// db url — conn URL 엔진의 catalog op 소비(패스스루 소멸).
function dbUrlCli(rest: string[]): VerbOutput {
  const p = positionalThenFlags(rest, { value: ["--name", "--host", "--env-local"], bool: ["--rw", "--admin", "--dry-run", "--json", "--help"], alias: "--name" }, "homelab db url", dbUrlUsage);
  if (isOutput(p)) return p;
  if (p.flags.bool("--help")) return { kind: "help", text: dbUrlUsage() };
  const input: DbUrlInput = { name: p.flags.str("--name") ?? p.positional ?? "", rw: p.flags.bool("--rw"), admin: p.flags.bool("--admin"), host: p.flags.str("--host"), envLocal: p.flags.str("--env-local"), dryRun: p.flags.bool("--dry-run") };
  const bad = dbUrlInputError(input);
  if (bad) return { kind: "usage-error", message: `homelab db url: ${bad}`, usage: dbUrlUsage() };
  const envelope = DB_URL.op(input);
  return { kind: "result", json: p.flags.bool("--json"), envelope, human: () => renderUrl(envelope) };
}

function doctorCli(rest: string[]): VerbOutput {
  let flags;
  try { flags = typedFlags(rest, { value: [], bool: ["--json", "--help"] }); }
  catch (e) {
    return { kind: "usage-error", message: `homelab doctor: ${e instanceof Error ? e.message : String(e)}`, usage: doctorUsage() };
  }
  if (flags.bool("--help")) return { kind: "help", text: doctorUsage() };
  const envelope = DOCTOR.op({});
  return { kind: "result", json: flags.bool("--json"), envelope, human: () => renderDoctor(envelope) };
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
    "등록(클라이언트):",
    "  claude mcp add homelab -- homelab mcp            # bun link 후 — PATH의 homelab",
    "  claude mcp add homelab -- bun <repo>/tools/homelab.ts mcp   # bun link 없이 — 절대 경로",
    "",
    "서버 env = 클라이언트가 준 env다(.mcp.json의 env 블록). KUBECONFIG를 주지 않으면 조용히 빠지는",
    "게 아니라 관측 가능한 결과가 된다: db/cache url은 variant skip(exitCode 4), status는 라이브",
    "계층을 생략하고 omitted=[\"live\"]로 그 사실을 선언한다. TS_DB_HOST·CACHE_LOCAL_HOST도 같은 축이다",
    "(부재 시 host 입력 필요 오류). 상세는 tools/README.md의 「MCP 서버 등록」 절.",
    "",
  ].join("\n");
}

// 도움말 토큰 — GNU/일반 CLI 관례(`-h`·`help`)를 `--help`의 별칭으로 받는다. 리프 동사에서는
// `--help`만 유효하다(`-h`는 parseFlags의 단일 대시 규약이 '알 수 없는 옵션'으로 거부) — 별칭은
// **어휘 자리**(top-level·그룹 노드)에만 산다. 그 자리에 오는 토큰은 동사 이름이지 플래그가 아니라
// 앱/리소스 이름과 충돌할 여지가 없다.
const HELP_TOKENS = new Set(["--help", "-h", "help"]);

// 그룹 노드 사용법 — 어휘는 catalog(VERBS) 파생이라 손 목록이 없다. 계약 x-contract.stdout이
// 「--help는 stdout(exit 0)」을 규약으로 적는데 리프만 그랬던 자리다.
function groupUsage(path: string[]): string {
  const prefix = path.join(" ");
  const rows = VERBS
    .filter((v) => v.path.length > path.length && v.path.slice(0, path.length).join(" ") === prefix)
    .map((v) => `  ${v.path.join(" ").padEnd(14)}${v.desc}`);
  return [
    `사용법: homelab ${prefix} <서브커맨드> [옵션]`,
    "",
    "서브커맨드:",
    ...rows,
    "",
    `각 서브커맨드의 상세는 \`homelab ${prefix} <서브커맨드> --help\`.`,
    "",
  ].join("\n");
}

// 버전 — package.json version은 최초 커밋 이후 불변이라 '어느 코드를 도는가'에 대해 거짓 확신이다
// (전역 심링크가 삭제된 worktree를 가리키는 사고가 이 호스트에서 실측됐다). 대신 **해석된 진입점
// 절대경로 + 그 체크아웃의 HEAD·브랜치 + 결과 계약 schema**를 낸다. git 조회 실패는 조용히 접지
// 않고 표기한다(설치 축 진단은 doctor 소관 — 여기는 좌표만).
function versionText(): string {
  const entry = fileURLToPath(import.meta.url);
  const dir = dirname(entry);
  const head = git(dir, ["rev-parse", "--short", "HEAD"]);
  const branch = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]);
  return [
    `homelab — ${entry}`,
    `체크아웃: ${head.ok ? head.out.trim() : "(git 미확인)"} · 브랜치 ${branch.ok ? branch.out.trim() : "(불명)"}`,
    `결과 계약: ${ENVELOPE} (tools/cli-result-schema.json)`,
    "",
  ].join("\n");
}

function main(argv: string[]): number {
  if (argv.length === 0) { process.stderr.write(usage()); return USAGE_EXIT; }
  if (HELP_TOKENS.has(argv[0]!)) { process.stdout.write(usage()); return 0; }
  if (argv[0] === "--version") { process.stdout.write(versionText()); return 0; }

  let cmd: ParsedCommand;
  try { cmd = parseCommand(argv, TREE); }
  catch (e) {
    // 그룹 노드 --help — 소비한 유효 노드 prefix(e.path) 뒤에 **정확히 도움말 토큰 하나만** 남은
    // 경우로 좁힌다. `argv.includes("--help")` 판정은 fail-open이다: `bogus --help`·`db creat --help`
    // 처럼 어휘 밖 단어가 섞인 입력까지 exit 0으로 접힌다(그 둘은 여기서 rest.length가 2라 걸린다).
    if (e instanceof CommandParseError) {
      const rest = argv.slice(e.path.length);
      if (rest.length === 1 && HELP_TOKENS.has(rest[0]!)) {
        process.stdout.write(e.path.length === 0 ? usage() : groupUsage(e.path));
        return 0;
      }
    }
    process.stderr.write(`homelab: ${e instanceof Error ? e.message : String(e)}\n\n${usage()}`);
    return USAGE_EXIT;
  }

  // parseCommand가 성공한 path는 TREE의 리프이고 TREE는 VERBS에서 파생되므로, 초기화의
  // totality 검사와 합쳐 어댑터가 항상 존재한다.
  const verb = cmd.path.join(" ");
  let out: VerbOutput;
  try { out = CLI_BY_VERB[verb]!(cmd.rest); }
  catch (e) { return internalError(verb, e); }

  // 프로세스 관심사는 여기서만: --help는 --json보다 우선(계약 stdout 절), usage 오류는 exit 2 +
  // stderr, 결과는 stdout 순수성(--json이면 stdout은 envelope 하나, 사람용은 stderr)을 지킨다.
  if (out.kind === "help") { process.stdout.write(out.text); return 0; }
  if (out.kind === "usage-error") { process.stderr.write(`${out.message}\n\n${out.usage}`); return USAGE_EXIT; }
  // 런타임 자기검증 — --json 여부와 무관하게(사람용 렌더도 같은 envelope에서 나온다) 계약 위반을
  // 방출 전에 loud하게 죽인다. 골든이 없는 셀에서 엔진이 계약을 어기면 여기가 유일한 증인이다.
  assertEnvelope(out.envelope);
  // 기계 채널 먼저 — 사람용 렌더(thunk)가 throw해도 --json 소비자의 envelope는 이미 온전하다.
  // 렌더러를 thunk로 받는 이유가 이 순서다: 종전에는 어댑터가 `human: renderX(envelope)`로 즉시
  // 평가해, 사람용 렌더 결함 하나가 JSON 출력에 도달하기도 전에 프로세스를 죽였다.
  if (out.json) process.stdout.write(JSON.stringify(out.envelope, null, 2) + "\n");
  try {
    const sink = out.json ? process.stderr : process.stdout;
    for (const line of out.human()) sink.write(line + "\n");
  } catch (e) { return internalError(verb, e); }
  // skip variant는 stderr 마커와 짝이다(계약 exitRationale — 같은 실행). 마커는 헬퍼가,
  // 종료코드는 envelope(variant 축의 exitFor 파생 — 스키마가 skip↔4를 강제)가 소유한다.
  if (out.envelope.variant === "skip") {
    skipMarker(out.envelope.verb, String((out.envelope.result as { note?: string }).note ?? "사유 미기록"));
  }
  return out.envelope.exitCode;
}

// 내부 오류 — 이 경로로 떨어지는 throw는 전부 **계약 파손**이다(correlation nonce 형식, 엔진의
// '검증 안 된 입력' 불변식, exitFor 미매핑, 렌더러 totality). 그래서:
//   · stdout을 건드리지 않는다 — --json 소비자에게 반쪽 오브젝트를 주지 않는다.
//   · 첫 줄이 `homelab <verb>: 내부 오류`다 — exit 1은 failure variant와 값이 같아서, 크래시와
//     '실패 결과'를 구별할 판별자가 종료코드 밖에 있어야 한다(계약 exitCodes 집합은 불변).
//   · 스택을 HOMELAB_DEBUG 뒤로 숨기지 않는다 — 도달 모집단이 버그 신고자라 스택이 유일한 증거다.
// ⚠️ 커버리지 경계: contract.ts의 톱레벨 스키마 로드는 **import 시점**이라 이 catch보다 먼저 돈다
//   (스키마 파일 부재·파손은 여기 오지 않고 모듈 로드 실패로 죽는다).
function internalError(verb: string, e: unknown): number {
  process.stderr.write(`homelab ${verb}: 내부 오류 — ${e instanceof Error ? e.message : String(e)}\n`);
  if (e instanceof Error && e.stack) process.stderr.write(`${e.stack}\n`);
  return 1;
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
