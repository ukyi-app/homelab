// homelab MCP 서버 — stdio JSON-RPC 2.0(개행 구분) 위에 파괴 제외 전 동사를 tool로 노출한다.
// 이 모듈은 MCP 프레젠테이션 계층이다(homelab.ts가 CLI 프레젠테이션을 소유하듯): tool 이름·입력
// 스키마·인자→op 입력 매핑·JSON-RPC 프레이밍만 갖고, 동사의 실체는 lib/verbs.ts의 op다.
//
// 계약(스펙 "MCP 서버 모드"):
//   - 노출 = VERBS 중 destructive가 아닌 전부(teardown 제외). 제외 근거는 descriptor의 destructive 표시.
//   - 각 tool 호출은 동기·바운디드 — --wait류 장기 대기는 스키마에 없다(입력에 wait/pollMs/deadlineMs 부재).
//   - 결과 = CLI --json과 같은 계약 오브젝트(op가 낸 envelope). isError는 variant로 매핑(x-contract.mcp).
//   - 디렉토리 추론 없음 — secrets는 앱 레포 경로(repoPath), init은 부모 디렉토리(parentDir)를 명시 입력으로.
//   - 서버는 무상태 — 동시 호출은 각자 run/PR URL 핸들로 독립 조회되고(status 핸들 모드), 재시작 후 재호출 정상.
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { ENVELOPE, compact, exitFor, mcpIsError, type Envelope } from "./contract.ts";
import { sh } from "./exec.ts";
import { appInitInputError, type AppInitInput } from "./init.ts";
import { appSecretsInputError, type AppSecretsInput } from "./secrets.ts";
import { statusInputError, type StatusInput } from "./status.ts";
import {
  APP_CREATE, APP_INIT, APP_SECRETS, CACHE_CREATE, DB_CREATE, DOCTOR, STATUS, VERBS,
  appCreateInputError, cacheCreateInputError, dbCreateInputError,
} from "./verbs.ts";

const PROTOCOL_VERSION = "2024-11-05";
type Json = Record<string, unknown>;

// tool 호출 결과 — 계약 envelope(전 동사, url 포함) 또는 usage 오류(invalid params -32602).
type ToolResult =
  | { kind: "envelope"; envelope: Envelope }
  | { kind: "usage"; message: string };

type McpTool = {
  name: string;
  description: string;
  inputSchema: Json;
  call: (args: Json) => ToolResult;
};

// 인자 헬퍼 — 타입 안전 추출(스키마가 이미 형상을 강제하지만 런타임 방어).
const str = (a: Json, k: string): string | undefined => (typeof a[k] === "string" ? (a[k] as string) : undefined);
const bool = (a: Json, k: string): boolean => a[k] === true;
const num = (a: Json, k: string): number | undefined => (typeof a[k] === "number" ? (a[k] as number) : undefined);
const strArr = (a: Json, k: string): string[] | undefined =>
  Array.isArray(a[k]) ? (a[k] as unknown[]).map((x) => String(x)) : undefined;

const envelope = (e: Envelope): ToolResult => ({ kind: "envelope", envelope: e });
const usage = (m: string): ToolResult => ({ kind: "usage", message: m });

// url tool(db url/cache url) — 로컬 .env 파일에 접속 URL을 기록하는 도구. 다른 tool과 같은 결과 계약
// (envelope)을 낸다(release r1 a5). 평문 자격은 결과에 담지 않는다: 계획(mode/envKey/envFile)은
// --dry-run(클러스터 무의존, 평문 비출력)으로 캡처하고, 실제 기록은 wrote 불리언으로만 표기한다.
// stdio 오염 방지를 위해 inherit이 아니라 캡처(sh)로 실행하고, 명시 envDir을 cwd로 준다(서버 cwd 추론 없음).
function urlEnvelope(verb: string, tool: string, name: string, baseArgv: string[], dryRun: boolean, envDir: string): ToolResult {
  const toolPath = fileURLToPath(new URL(`../${tool}`, import.meta.url));
  const result: Record<string, unknown> = { name, dryRun };
  const plan = sh(process.execPath, [toolPath, ...baseArgv, "--dry-run"], { cwd: envDir });
  if (plan.ok) { try { Object.assign(result, JSON.parse(plan.out)); } catch { /* 계획 파싱 실패는 변이 아님 */ } }
  result.name = name; result.dryRun = dryRun; // 계획의 name으로 덮이지 않게 재고정
  let variant = "success";
  if (dryRun) {
    result.wrote = false;
    if (!plan.ok) { variant = "failure"; result.error = plan.err.split("\n")[0] || `${tool} 계획 실패`; }
  } else {
    const real = sh(process.execPath, [toolPath, ...baseArgv], { cwd: envDir });
    result.wrote = real.ok;
    if (!real.ok) { variant = "failure"; result.error = real.err.split("\n")[0] || `${tool} 실패`; }
  }
  const env: Envelope = { schema: ENVELOPE, verb, variant, exitCode: exitFor(variant), omitted: [], result: compact(result) };
  return { kind: "envelope", envelope: env };
}

// MCP tool 테이블 — VERBS 순서를 따르되 destructive(teardown)·서버 모드(mcp)는 제외한다.
// 각 tool은 op를 --wait 없이 호출한다(wait 미노출 = 동기 바운디드).
const TOOLS: McpTool[] = [
  {
    name: "doctor",
    description: DOCTOR.desc,
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    call: () => envelope(DOCTOR.op({})),
  },
  {
    name: "status",
    description: STATUS.desc,
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { app: { type: "string" }, run: { type: "string" }, pr: { type: "string" } },
    },
    call: (a) => {
      const input: StatusInput = { app: str(a, "app"), runUrl: str(a, "run"), prUrl: str(a, "pr") };
      const bad = statusInputError(input);
      return bad ? usage(bad) : envelope(STATUS.op(input));
    },
  },
  {
    name: "db_create",
    description: DB_CREATE.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name"],
      properties: { name: { type: "string" }, ext: { type: "array", items: { type: "string" } } },
    },
    call: (a) => {
      const input = { name: str(a, "name") ?? "", ext: strArr(a, "ext"), wait: false, identifyOnly: true };
      const bad = dbCreateInputError(input);
      return bad ? usage(bad) : envelope(DB_CREATE.op(input));
    },
  },
  {
    name: "cache_create",
    description: CACHE_CREATE.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name"],
      properties: { name: { type: "string" }, maxmemoryMi: { type: "integer" } },
    },
    call: (a) => {
      const input = { name: str(a, "name") ?? "", maxmemoryMi: num(a, "maxmemoryMi"), wait: false, identifyOnly: true };
      const bad = cacheCreateInputError(input);
      return bad ? usage(bad) : envelope(CACHE_CREATE.op(input));
    },
  },
  {
    name: "app_create",
    description: APP_CREATE.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app"],
      properties: { app: { type: "string" } },
    },
    call: (a) => {
      const input = { app: str(a, "app") ?? "", wait: false, identifyOnly: true };
      const bad = appCreateInputError(input);
      return bad ? usage(bad) : envelope(APP_CREATE.op(input));
    },
  },
  {
    name: "app_secrets",
    description: APP_SECRETS.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app", "repoPath"],
      properties: { app: { type: "string" }, repoPath: { type: "string" }, noSeal: { type: "boolean" } },
    },
    call: (a) => {
      // repoPath = 앱 레포 경로 명시 입력(서버 cwd 추론 없음 — input.cwd로 흐른다).
      const input: AppSecretsInput = { app: str(a, "app") ?? "", noSeal: bool(a, "noSeal"), wait: false, identifyOnly: true, cwd: str(a, "repoPath") };
      const bad = appSecretsInputError(input);
      return bad ? usage(bad) : envelope(APP_SECRETS.op(input));
    },
  },
  {
    name: "app_init",
    description: APP_INIT.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app", "archetype", "parentDir"],
      properties: {
        app: { type: "string" }, archetype: { enum: ["api", "fullstack", "site", "worker"] },
        parentDir: { type: "string" }, public: { type: "boolean" },
        dispatchSecrets: { type: "string" }, adopt: { type: "boolean" },
      },
    },
    call: (a) => {
      const input: AppInitInput = {
        app: str(a, "app") ?? "", archetype: str(a, "archetype") ?? "",
        public: bool(a, "public"), dispatchSecrets: str(a, "dispatchSecrets"),
        adopt: bool(a, "adopt"), parentDir: str(a, "parentDir"),
      };
      const bad = appInitInputError(input);
      return bad ? usage(bad) : envelope(APP_INIT.op(input));
    },
  },
  {
    name: "db_url",
    description: "클러스터 DB 접속 URL을 envDir의 .env.local(admin은 .env.admin.local)에 기록(값 비출력). dryRun=계획만.",
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name", "envDir"],
      properties: {
        name: { type: "string" }, mode: { enum: ["ro", "rw", "admin"] },
        host: { type: "string" }, envDir: { type: "string" }, dryRun: { type: "boolean" },
      },
    },
    call: (a) => {
      const name = str(a, "name") ?? "";
      const argv = ["--name", name];
      const mode = str(a, "mode");
      if (mode === "rw") argv.push("--rw");
      else if (mode === "admin") argv.push("--admin");
      const host = str(a, "host"); if (host !== undefined) argv.push("--host", host);
      return urlEnvelope("db url", "db-url.ts", name, argv, bool(a, "dryRun"), str(a, "envDir") ?? "");
    },
  },
  {
    name: "cache_url",
    description: "캐시 접속 URL을 envDir의 .env.local에 기록(port-forward 선행, 값 비출력). dryRun=계획만.",
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name", "envDir"],
      properties: {
        name: { type: "string" }, rw: { type: "boolean" },
        host: { type: "string" }, envDir: { type: "string" }, dryRun: { type: "boolean" },
      },
    },
    call: (a) => {
      const name = str(a, "name") ?? "";
      const argv = ["--name", name];
      if (bool(a, "rw")) argv.push("--rw");
      const host = str(a, "host"); if (host !== undefined) argv.push("--host", host);
      return urlEnvelope("cache url", "cache-url.ts", name, argv, bool(a, "dryRun"), str(a, "envDir") ?? "");
    },
  },
];

// totality — 노출 대상(비-destructive·비-서버) VERBS가 전부 tool로 배선됐는지 초기화 시 강제한다.
// (파괴 동사가 실수로 노출되거나, 신규 동사가 조용히 누락되는 것을 fail-closed로 막는다.)
const EXPOSED_VERB_PATHS = VERBS.filter((v) => v.destructive !== true).map((v) => v.path.join("_"));
const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));
for (const p of EXPOSED_VERB_PATHS) {
  if (!TOOL_NAMES.has(p)) throw new Error(`계약 파손: 비-파괴 동사 '${p}'가 MCP tool로 배선되지 않았다`);
}
// 역방향 — 파괴 동사가 tool에 새어 들어오지 않았는지.
for (const v of VERBS) {
  if (v.destructive === true && TOOL_NAMES.has(v.path.join("_"))) {
    throw new Error(`계약 파손: 파괴 동사 '${v.path.join(" ")}'가 MCP에 노출됐다`);
  }
}

const TOOL_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]));

// ── JSON-RPC 처리 ──
function ok(id: unknown, result: Json): Json { return { jsonrpc: "2.0", id, result }; }
function err(id: unknown, code: number, message: string): Json { return { jsonrpc: "2.0", id, error: { code, message } }; }

// 요청 하나를 처리해 응답 오브젝트를 돌려준다. 알림(id 없음)은 null(무응답).
export function handleRequest(req: Json): Json | null {
  const method = typeof req.method === "string" ? req.method : "";
  const id = req.id;
  const isNotification = !("id" in req);

  if (method === "initialize") {
    return ok(id, { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: "homelab", version: "1" } });
  }
  if (method === "notifications/initialized" || method === "initialized") {
    return null; // 알림 — 무응답
  }
  if (method === "tools/list") {
    return ok(id, { tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })) });
  }
  if (method === "tools/call") {
    const params = (req.params ?? {}) as Json;
    const name = typeof params.name === "string" ? params.name : "";
    const args = (params.arguments ?? {}) as Json;
    const tool = TOOL_BY_NAME.get(name);
    if (!tool) return err(id, -32602, `알 수 없는 tool: ${name}`); // 파괴 동사·오타 전부 여기(노출 표면 밖)
    // inputSchema.required를 서버측 **타입 인식으로** 강제한다 — 스키마의 required는 클라이언트 광고일
    // 뿐 신뢰 경계가 아니다. 존재만 검사하면 null/숫자/빈 문자열 경로가 통과해 str()에서 undefined로
    // 접히고, 명시 경로(repoPath/parentDir/envDir)가 cwd 폴백으로 새어 서버 디렉토리에 변이·자격 기록이
    // 일어난다(release r1 a3=b1·a4=b2). 값의 존재 + 타입(문자열은 비어 있지 않은 문자열)까지 검증한다.
    const props = (tool.inputSchema.properties as Record<string, { type?: string }> | undefined) ?? {};
    const required = (tool.inputSchema.required as string[] | undefined) ?? [];
    for (const k of required) {
      const v = args[k];
      if (v === undefined || v === null) return err(id, -32602, `필수 입력 누락: ${k}`);
      if (props[k]?.type === "string" && (typeof v !== "string" || v === "")) {
        return err(id, -32602, `${k}는 비어 있지 않은 문자열이어야 한다`);
      }
    }
    const r = tool.call(args);
    if (r.kind === "usage") return err(id, -32602, r.message); // usage 오류 = invalid params
    // envelope — CLI --json과 같은 계약 오브젝트를 content로, isError는 variant 매핑.
    return ok(id, { content: [{ type: "text", text: JSON.stringify(r.envelope) }], isError: mcpIsError(r.envelope.variant) });
  }
  if (isNotification) return null;
  return err(id, -32601, `알 수 없는 method: ${method}`);
}

// stdio 서버 루프 — 개행 구분 JSON-RPC. stdin EOF에 종료(exit 0). stdout은 응답만(사람 텍스트·
// 하위 도구 출력은 캡처되거나 stderr로 — JSON-RPC 스트림 오염 없음).
export function runMcpServer(): Promise<number> {
  const write = (obj: Json) => process.stdout.write(JSON.stringify(obj) + "\n");
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin });
    rl.on("line", (line) => {
      const t = line.trim();
      if (t === "") return;
      let req: unknown;
      try { req = JSON.parse(t); }
      catch { write(err(null, -32700, "parse error")); return; }
      // 비-오브젝트(원시값·배열·null)는 Invalid Request(-32600) — 프로퍼티 접근/`in` 연산자가
      // throw하기 전에 막는다(불량 라인 하나가 서버를 죽이지 않게: stateless-resilience).
      if (typeof req !== "object" || req === null || Array.isArray(req)) { write(err(null, -32600, "invalid request")); return; }
      // 처리 중 예외(op 계약 파손 throw 등)가 이벤트 루프 밖으로 새어 프로세스를 죽이지 않도록 격리한다.
      let resp: Json | null;
      try { resp = handleRequest(req as Json); }
      catch (e) { write(err((req as Json).id ?? null, -32603, `internal error: ${e instanceof Error ? e.message : String(e)}`)); return; }
      if (resp !== null) write(resp);
    });
    rl.on("close", () => resolve(0));
  });
}
