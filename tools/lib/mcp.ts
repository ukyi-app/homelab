// homelab MCP 서버 — stdio JSON-RPC 2.0(개행 구분) 위에 파괴 제외 전 동사를 tool로 노출한다.
// 이 모듈은 MCP 프레젠테이션 계층이다(homelab.ts가 CLI 프레젠테이션을 소유하듯): tool 이름·입력
// 스키마·인자→op 입력 매핑·JSON-RPC 프레이밍만 갖고, 동사의 실체는 lib/verbs.ts의 op다.
//
// 계약(스펙 "MCP 서버 모드"):
//   - 노출 = VERBS 중 destructive가 아닌 전부(teardown 제외). 제외 근거는 descriptor의 destructive 표시.
//   - 각 tool 호출은 동기·바운디드 — --wait류 장기 대기는 스키마에 없다(입력에 wait/pollMs/deadlineMs 부재).
//     ⚠️ 그 '바운디드'는 **스키마 축**이다: 대기 옵션이 입력 표면에 없다는 뜻이지, 호출 하나의
//     wall-clock 상한이 있다는 뜻이 아니다. 하위 프로세스 wall-clock 상한은 **두지 않는다**
//     (owner 결정 Q7). 근거는 init.ts가 timeoutMs:0을 고른 두 자리다 — 스캐폴더는 lock 재생성
//     `bun install`을 품어 30s SIGTERM이 rollback 전에 트리를 죽였고, 첫 push는 서버에 반영된 뒤
//     클라이언트만 죽으면 성공한 부수효과가 '실패'로 보고된다. 상한을 씌우면 그 두 함정이 MCP
//     경로로 되돌아온다. 대신 **run 출현 대기**만 MCP_DEADLINE_MS로 바운드한다(아래).
//   - JSON-RPC 프레이밍: 응답은 요청 1건당 1줄, 알림(id 부재)에는 0줄. ping은 빈 result(MCP 필수
//     유틸리티), id:null·id 붙은 initialized는 -32600(스펙상 각각 금지·알림 전용).
//   - 결과 = CLI --json과 같은 계약 오브젝트(op가 낸 envelope). isError는 variant로 매핑(x-contract.mcp).
//   - 디렉토리 추론 없음 — secrets는 앱 레포 경로(repoPath), init은 부모 디렉토리(parentDir)를 명시 입력으로.
//     경로 입력 3종(repoPath·parentDir·envDir)은 **절대 경로만**(pattern "^/" + identity.pathInputError — 상대 경로·'~'는
//     -32602, 서버가 확장·추론하지 않는다). 존재하지 않는/앱 레포 아닌 명시 repoPath는 레포 밖이 아니라 거부다
//     (dispatch-only 폴백은 CLI 암묵 cwd 전용 — homelab-cli-r2 티켓 02, owner 결정 2026-09-07).
//   - 서버는 무상태 — 동시 호출은 각자 run/PR URL 핸들로 독립 조회되고(status 핸들 모드), 재시작 후 재호출 정상.
//
// ⚠️ **입력 표면 선언 3벌(verbs.ts의 op 입력 타입 · 이 파일의 tool inputSchema · 결과 계약의 verb 축)은
//    의도된 중복이다 — 카탈로그 한 벌로 합치지 않는다.** structure 게이트 r1 B1이 "표현 관심사는 각
//    셸(CLI·MCP)이 소유한다"로 정했고, 전면 카탈로그화는 transport 발산(스키마 표현력·검증 시점·에러
//    매핑의 차이)을 전부 표현하는 행이 대체 대상만큼 복잡해지는 **shallow config-language 위험**이
//    지적되어 이연됐다. 그래서 cli-deepening 심화 6은 실측된 드리프트 지점(archetype enum — 확장 시
//    MCP만 -32602로 거부하던 리터럴 사본) **하나만** ARCHETYPES 파생으로 좁혔다. 전면 카탈로그화를
//    재시도하려면 B1 재협상이 선행이다(원 결정 기록은 git 히스토리의 docs/reviews — CONTRIBUTING
//    '문서 관례'의 복구 레시피로 꺼낸다).
import { createInterface } from "node:readline";
import { cacheUrlInputError, dbUrlInputError, type CacheUrlInput, type DbUrlInput } from "./conn-url.ts";
import { assertEnvelope, mcpIsError, type Envelope } from "./contract.ts";
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

// MCP 변이의 run 식별 시간 상한 — identifyOnly라도 run '출현' 대기(step2)는 **주어진** deadline까지
// 폴링한다. CLI 기본값(WAIT_DEFAULTS.deadlineMs = 20분)을 그대로 물려받으면 stdio 서버가 run 미출현 시
// 그만큼 블로킹되므로, MCP는 아래 짧은 deadline을 **명시해** 그 대기를 바운드한다(release r2-a2/b3).
// 반환되는 pending은 두 갈래이고 재개 경로가 서로 다르다(티켓 09):
//   · run 식별됨 → result.run.{url,branch}가 좌표다: `status --run <url> --branch <branch>`.
//   · run 미출현 → 이 봉투에는 **run이 없다** — status의 어떤 모드도 쓸 수 없다. 재디스패치가
//     아니라 Actions에서 run-name의 [correlation] 에코를 확인하는 것이 유일한 경로다
//     (owner 결정 Q2: correlation 핸들 모드는 열지 않는다 — PR 본문에 에코가 없어 reusable 5벌
//     계약 변경이 선행이라 재개 조건 미충족). pendingReason이 그 사실을 문장으로 담는다.
// env로 주입 가능(테스트 시간 심).
// ⚠️ 위 인용은 손 사본이 아니다 — test_homelab-mcp.bats가 WAIT_DEFAULTS에서 분(minute)을 유도해 대조한다.
//
// 서버 env 판독 — 설정됐는데 양의 십진 정수가 아니면 **모듈 로드 시** 죽인다(기동 거부).
// 종전엔 `Number(env ?? "30000")`이라 "abc"→NaN·""→0이 조용히 MCP_MUT에 실렸고, 서버는 정상
// 기동해 tools/list까지 멀쩡한 채 **변이 tool만 전부** `-32602 --deadline-ms는 양의 정수여야
// 한다: NaN`으로 죽었다 — 클라이언트가 준 적 없는 CLI 플래그를 탓하는 진단이라 운영자가 자기
// 서버 설정을 못 찾는다(함정 원장 「TS 바닥값은 coercion 뒤에서 조용히 꺼진다」). 진단이 반드시
// **env 이름**을 말해야 하고, 시점은 첫 변이 호출이 아니라 기동이어야 한다.
// ⚠️ homelab.ts가 이 모듈을 정적 import하므로 불량 env는 mcp 모드가 아닌 동사도 기동 거부한다 —
// 의도된 blast radius다(계약 밖 값이 프로세스 환경에 있으면 그 프로세스의 어떤 경로도 그 값을
// 신뢰할 수 없다). 해소는 그 env를 지우거나 양의 정수로 고치는 것이고, stderr가 이름을 준다.
function envPositiveIntMs(name: string, dflt: number): number {
  const raw = process.env[name];
  if (raw === undefined) return dflt;
  // 표기만 본다 — Number()는 "1e3"·" 5 "·"12.5"를 조용히 삼키고 ""를 0으로 접는다.
  if (!/^[1-9][0-9]*$/.test(raw)) throw new Error(`계약 파손: ${name}=${JSON.stringify(raw)} — 양의 정수 ms여야 한다(MCP 서버 env)`);
  return Number(raw);
}
const MCP_DEADLINE_MS = envPositiveIntMs("HOMELAB_MCP_DEADLINE_MS", 30000);
const MCP_POLL_MS = envPositiveIntMs("HOMELAB_MCP_POLL_MS", 2000);
// 변이 tool 공통 대기 입력 — 짧은 식별 deadline + identifyOnly.
// ⚠️ `onProgress`(변이 엔진의 진행 이벤트 싱크, 티켓 07)는 **의도적으로 없다** — 이 서버의 stdout은
// JSON-RPC 프레임 전용이고, 진행 줄은 CLI 셸(homelab.ts)이 stderr에 내는 표현이다. 여기에 싱크를
// 주입하면 그 줄이 어디로 가든 프레이밍 계약이 표현 결정에 의존하게 된다(test_homelab-mcp.bats가
// stdout 전 줄의 JSON-RPC 적합을 단언한다).
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
// envDir = 대상 env 파일의 기준 디렉토리 명시 입력(서버 cwd 추론 없음 — 절대 경로만, 상대 경로면 서버 cwd 아래에
// 자격 파일이 떨어지므로 거부). envLocal 축은 엔진에 존재하지만 MCP에는 노출하지 않는다(설계 Q9 — 파일 기록 축
// 확대는 별도 신뢰 경계 결정).

// 경로 속성 description — 에이전트가 경로 의미론을 알 유일한 채널(tools/list)이다. 강제하는 성질만 서술한다
// (플래그 광고 금지 — mcp-3 류 드리프트 방지): 절대 경로, 기준점 없음, 그 자리에 무엇이 생기는가.
const ABS_HINT = "절대 경로만(예: /home/<user>/apps). 상대 경로·'~'는 거부된다 — 서버 cwd·HOME을 기준점으로 삼지 않으며 '~'는 확장되지 않는다.";
const DESC_REPO_PATH = `앱 레포 루트의 ${ABS_HINT} 존재하지 않거나 앱 레포(.app-config.yml 마커 + canonical remote)가 아니면 디스패치 없이 거부된다.`;
const DESC_PARENT_DIR = `클론 대상 부모 디렉토리의 ${ABS_HINT} 그 아래에 <app>/ 클론·스캐폴드·첫 push가 만들어진다.`;
const DESC_ENV_DIR = `자격 파일(.env.local / admin은 .env.admin.local)이 기록될 기준 디렉토리의 ${ABS_HINT}`;
const DESC_DISPATCH_SECRETS = "GitHub App 키 파일(app-id·private-key.pem)이 있는 디렉토리 경로. 지정 시 두 파일이 모두 있어야 하고, 클론 트리(parentDir/<app>) 안이면 거부된다(첫 커밋이 키를 원격에 올린다). 값은 파일 경로로만 전달되며 서버가 읽지 않는다. 참고: dispatch App은 2026-09-03 org 설치가 제거돼 재설치 전까지 이 쌍은 무효다(배포 반영은 bump-poll 크론 백스톱).";
// 이름 충돌 분리(appverbs-2) — 이 축은 GitHub 레포 가시성이고, 앱 노출은 별도 SSOT다.
const DESC_REPO_PUBLIC = "GitHub 레포를 공개로 만든다(기본 private). 앱의 공개 노출이 아니다 — 그건 앱 레포 .app-config.yml의 route.public이고, 클론된 트리에서 편집한다.";
// 변이 pending의 result.run.branch를 그대로 넘기는 자리 — 재개 경로를 스키마가 광고한다(티켓 09).
const DESC_RESOURCES = "레포 산출물에서 db·캐시 리소스 인벤토리를 낸다(관측 전용·로컬 디스크만). app·run·pr과 상호배타이며, 행은 role별 산출물 실존 + cache 원장 행 + tombstone이다.";
const DESC_BRANCH = "변이 pending이 돌려준 result.run.branch를 그대로. run과 함께만 쓰며(단독 조회 아님) 그 레인 브랜치의 PR을 정확 조회한다. 그 run의 좌표가 아닌 브랜치는 거부된다.";

// 변이 tool의 MCP 소유 꼬리말 — description은 tools/list의 **에이전트 대면 채널**이라 CLI 셸의
// 어휘(플래그 이름)를 빌려 쓰지 않는다. 빌려 쓰면 inputSchema가 -32602로 거부하는 입력을 LLM에게
// 권하는 드리프트가 된다(mcp-3: desc가 `--wait=배포 수렴까지`를 광고했는데 wait는 스키마에 없다).
// verbs.ts의 desc는 이제 transport 중립 문장만 담고, 이 축(대기·재개 경로)은 여기가 소유한다.
const DESC_MUT_PENDING = " 디스패치 후 run 핸들을 pending으로 즉시 반환한다 — 진행은 status(run·branch)로 재조회하며, 이 표면에는 대기 옵션이 없다.";
// app_secrets만의 축 — repoPath 기준 동작(cwd 어휘는 stdio 서버에서 의미가 없다).
const DESC_SECRETS_MODE = ` 앱 레포 루트(repoPath)에서 seal→커밋→push→디스패치 연쇄를 돈다. ${DESC_MUT_PENDING.trim()}`;

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
      properties: { app: { type: "string" }, run: { type: "string" }, pr: { type: "string" }, branch: { type: "string", description: DESC_BRANCH }, resources: { type: "boolean", description: DESC_RESOURCES } },
    },
    call: (a) => {
      const input: StatusInput = { app: str(a, "app"), runUrl: str(a, "run"), prUrl: str(a, "pr"), branch: str(a, "branch"), resources: a?.resources === true ? true : undefined };
      const bad = statusInputError(input);
      return bad ? usage(bad) : envelope(STATUS.op(input));
    },
  },
  {
    name: "db_create",
    description: DB_CREATE.desc + DESC_MUT_PENDING,
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
    description: CACHE_CREATE.desc + DESC_MUT_PENDING,
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
    description: APP_CREATE.desc + DESC_MUT_PENDING,
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
    description: APP_SECRETS.desc + DESC_SECRETS_MODE,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["app", "repoPath"],
      properties: { app: { type: "string", minLength: 1 }, repoPath: { type: "string", minLength: 1, pattern: "^/", description: DESC_REPO_PATH }, noSeal: { type: "boolean" } },
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
        parentDir: { type: "string", minLength: 1, pattern: "^/", description: DESC_PARENT_DIR },
        repoPublic: { type: "boolean", description: DESC_REPO_PUBLIC },
        dispatchSecrets: { type: "string", minLength: 1, description: DESC_DISPATCH_SECRETS }, adopt: { type: "boolean" },
      },
    },
    call: (a) => {
      const input: AppInitInput = {
        app: str(a, "app") ?? "", archetype: str(a, "archetype") ?? "",
        public: bool(a, "repoPublic"), dispatchSecrets: str(a, "dispatchSecrets"),
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
        host: { type: "string" }, envDir: { type: "string", minLength: 1, pattern: "^/", description: DESC_ENV_DIR }, dryRun: { type: "boolean" },
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
        host: { type: "string" }, envDir: { type: "string", minLength: 1, pattern: "^/", description: DESC_ENV_DIR }, dryRun: { type: "boolean" },
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

  // id 경계 — JSON-RPC 2.0은 요청 id로 null을 금지한다. `"id" in req`이라 알림도 아니어서
  // 종전엔 정상 요청으로 처리돼 `{"id":null,"result":…}`를 냈다(응답과 알림 응답이 구별 불가).
  if (!isNotification && id === null) return err(null, -32600, "invalid request: 요청 id는 null일 수 없다");

  if (method === "initialize") {
    return ok(id, { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: "homelab", version: "1" } });
  }
  if (method === "notifications/initialized" || method === "initialized") {
    // 알림 전용 method다. id가 붙어 오면 **삼키지 않는다** — 종전엔 무응답이라 그 id를 기다리는
    // 클라이언트가 영구 대기했다. 코드는 -32600: 스펙상 알림 전용이라는 사실 자체가 사유다.
    return isNotification ? null : err(id, -32600, `invalid request: ${method}는 알림 전용이라 id를 붙일 수 없다`);
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
    // 방출 전 자기검증(CLI 셸과 같은 지점) — 위반 throw는 서버 루프의 -32603 격리가 받는다.
    assertEnvelope(r.envelope);
    return ok(id, { content: [{ type: "text", text: JSON.stringify(r.envelope) }], isError: mcpIsError(r.envelope.variant) });
  }
  if (isNotification) return null;
  // ping — MCP 2024-11-05 basic/utilities/ping: 수신자는 빈 result로 즉시 응답해야 한다(종전엔
  // -32601이라 keepalive로 ping을 쓰는 호스트가 연결 이상으로 읽을 수 있었다).
  // ⚠️ 자리는 알림 분기 **뒤**다: 앞에 두면 id 없는 ping에 id 없는 응답 한 줄을 써서 stdio
  // 프레이밍(요청 1건당 1줄·알림 0줄)을 깬다.
  if (method === "ping") return ok(id, {});
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
