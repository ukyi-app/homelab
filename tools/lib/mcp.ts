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
import { cacheUrlInputError, dbUrlInputError, type CacheUrlInput, type DbUrlInput } from "./conn-url.ts";
import { mcpIsError, type Envelope } from "./contract.ts";
import { schemaErrors } from "./schema-check.ts";
import { appInitInputError, type AppInitInput } from "./init.ts";
import { ARCHETYPES } from "./platform.ts";
import { appSecretsInputError, type AppSecretsInput } from "./secrets.ts";
import { statusInputError, type StatusInput } from "./status.ts";
import {
  APP_CREATE, APP_INIT, APP_SECRETS, CACHE_CREATE, CACHE_URL, DB_CREATE, DB_URL, DOCTOR, STATUS, VERBS,
  appCreateInputError, cacheCreateInputError, dbCreateInputError,
} from "./verbs.ts";

const PROTOCOL_VERSION = "2024-11-05";
type Json = Record<string, unknown>;

// MCP 변이의 run 식별 시간 상한 — identifyOnly라도 run '출현' 대기(step2)는 공유 deadline까지 폴링하므로,
// run 미출현 시 최대 20분 서버 블로킹이 남는다(release r2-a2/b3). MCP는 짧은 deadline으로 그 대기를
// 바운드한다(미출현이면 pending 반환, status(run) 재조회로 재개). env로 주입 가능(테스트 시간 심).
const MCP_DEADLINE_MS = Number(process.env.HOMELAB_MCP_DEADLINE_MS ?? "30000");
const MCP_POLL_MS = Number(process.env.HOMELAB_MCP_POLL_MS ?? "2000");
// 변이 tool 공통 대기 입력 — 짧은 식별 deadline + identifyOnly.
const MCP_MUT = { wait: false, identifyOnly: true, deadlineMs: MCP_DEADLINE_MS, pollMs: MCP_POLL_MS } as const;

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

// url tool(db url/cache url) — 다른 tool과 같은 경로: conn URL 엔진의 op를 직접 소비한다
// (cli-deepening 심화 5 — 자식 프로세스 이중 실행·계획 키 화이트리스트(release r2-a5 땜질)는
// 엔진의 타입 결과(UrlResult ↔ urlResult 1:1)로 소멸했다). 평문 비출력·F2 채널 분리는 엔진 소유.
// envDir = 대상 env 파일의 기준 디렉토리 명시 입력(서버 cwd 추론 없음). envLocal 축은 엔진에
// 존재하지만 MCP에는 노출하지 않는다(설계 Q9 — 파일 기록 축 확대는 별도 신뢰 경계 결정).

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
      properties: { name: { type: "string", minLength: 1 }, ext: { type: "array", items: { type: "string" } } },
    },
    call: (a) => {
      const input = { name: str(a, "name") ?? "", ext: strArr(a, "ext"), ...MCP_MUT };
      const bad = dbCreateInputError(input);
      return bad ? usage(bad) : envelope(DB_CREATE.op(input));
    },
  },
  {
    name: "cache_create",
    description: CACHE_CREATE.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name"],
      properties: { name: { type: "string", minLength: 1 }, maxmemoryMi: { type: "integer" } },
    },
    call: (a) => {
      const input = { name: str(a, "name") ?? "", maxmemoryMi: num(a, "maxmemoryMi"), ...MCP_MUT };
      const bad = cacheCreateInputError(input);
      return bad ? usage(bad) : envelope(CACHE_CREATE.op(input));
    },
  },
  {
    name: "app_create",
    description: APP_CREATE.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app"],
      properties: { app: { type: "string", minLength: 1 } },
    },
    call: (a) => {
      const input = { app: str(a, "app") ?? "", ...MCP_MUT };
      const bad = appCreateInputError(input);
      return bad ? usage(bad) : envelope(APP_CREATE.op(input));
    },
  },
  {
    name: "app_secrets",
    description: APP_SECRETS.desc,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app", "repoPath"],
      properties: { app: { type: "string", minLength: 1 }, repoPath: { type: "string", minLength: 1 }, noSeal: { type: "boolean" } },
    },
    call: (a) => {
      // repoPath = 앱 레포 경로 명시 입력(서버 cwd 추론 없음 — input.cwd로 흐른다).
      const input: AppSecretsInput = { app: str(a, "app") ?? "", noSeal: bool(a, "noSeal"), ...MCP_MUT, cwd: str(a, "repoPath") };
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
        // archetype enum은 아키타입 SSOT(platform.ts ARCHETYPES)의 파생이다 — 리터럴 사본이면 아키타입
        // 확장 시 init 엔진은 수용하는데 MCP만 -32602로 거부하는 입력 표면 드리프트가 난다(cli-deepening 심화 6).
        app: { type: "string", minLength: 1 }, archetype: { enum: [...ARCHETYPES] },
        parentDir: { type: "string", minLength: 1 }, public: { type: "boolean" },
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
        name: { type: "string", minLength: 1 }, mode: { enum: ["ro", "rw", "admin"] },
        host: { type: "string" }, envDir: { type: "string", minLength: 1 }, dryRun: { type: "boolean" },
      },
    },
    call: (a) => {
      const mode = str(a, "mode");
      const input: DbUrlInput = {
        name: str(a, "name") ?? "", rw: mode === "rw", admin: mode === "admin",
        host: str(a, "host"), envDir: str(a, "envDir"), dryRun: bool(a, "dryRun"),
      };
      const bad = dbUrlInputError(input);
      return bad ? usage(bad) : envelope(DB_URL.op(input));
    },
  },
  {
    name: "cache_url",
    description: "캐시 접속 URL을 envDir의 .env.local에 기록(port-forward 선행, 값 비출력). dryRun=계획만.",
    inputSchema: {
      type: "object", additionalProperties: false, required: ["name", "envDir"],
      properties: {
        name: { type: "string", minLength: 1 }, rw: { type: "boolean" },
        host: { type: "string" }, envDir: { type: "string", minLength: 1 }, dryRun: { type: "boolean" },
      },
    },
    call: (a) => {
      const input: CacheUrlInput = {
        name: str(a, "name") ?? "", rw: bool(a, "rw"),
        host: str(a, "host"), envDir: str(a, "envDir"), dryRun: bool(a, "dryRun"),
      };
      const bad = cacheUrlInputError(input);
      return bad ? usage(bad) : envelope(CACHE_URL.op(input));
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
    // 인자 전체를 inputSchema로 서버측 검증한다 — 스키마의 required/type/enum/additionalProperties는
    // 클라이언트 광고일 뿐 신뢰 경계가 아니다. required만 검사하면 (release r1 a3=b1·a4=b2) null/숫자/빈
    // 문자열 경로가 str()에서 undefined로 접혀 cwd 폴백으로 서버 디렉토리에 변이·자격 기록이 나가고,
    // optional만 검사 밖이면 (release r2-b1) dryRun:'true'(문자열)가 bool()에서 false로 접혀 실제 자격
    // 쓰기가 실행된다. 전체 검증(type·enum·minLength·additionalProperties)으로 이 접힘 표면을 통째로 닫는다.
    const errs = schemaErrors(args, tool.inputSchema, tool.inputSchema);
    if (errs.length > 0) return err(id, -32602, `입력 검증 실패: ${errs.slice(0, 3).join("; ")}`);
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
