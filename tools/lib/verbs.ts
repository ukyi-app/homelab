// 동사 operation catalog — transport 중립·부수효과 없는 import-safe SSOT(structure r1 A1·B1:
// bin 모듈(homelab.ts)은 import하면 main이 실행되므로 MCP가 재사용할 catalog는 lib에 산다).
// 행 하나 = 동사 하나: path(라우팅 어휘)·desc(--help 열거)·op(operation — 타입 입력을 받아
// 계약 Envelope 반환, 프로세스/표현 관심사 없음). argv 파싱·렌더링·stdout·종료코드는 CLI 셸
// (homelab.ts) 소유이고, MCP 서버(후속 티켓)는 op를 직접 호출해 같은 envelope을 tool 결과로 쓴다.
// MCP 노출 정책 필드는 MCP 티켓에서 이 descriptor에 추가한다.
import { ENVELOPE, exitFor, type Envelope } from "./contract.ts";
import { runDoctor } from "./doctor.ts";
import { APP_NAME_RE, CACHE_MAXMEMORY_MI, EXT_RE, resourceNameError } from "./identity.ts";
import { runMutation, waitInputError, waitOpts, type WaitInput } from "./mutation.ts";
import { appSecretsInputError, runAppSecrets, type AppSecretsInput } from "./secrets.ts";
import { runStatus, statusInputError, type StatusInput } from "./status.ts";

// 동사 형상 — I가 그 동사의 타입 입력(structure r2-a1: op를 입력 0개로 고정하면 입력 있는
// 동사가 catalog를 우회해야 한다). 동사 추가 = 입력 타입 + 구체 Verb 타입 + union 멤버 +
// named export + VERBS 행 — 전부 이 파일 안이라 우회 표면이 없다.
type VerbShape<I> = { path: readonly string[]; desc: string; op: (input: I) => Envelope };

// doctor는 입력이 없는 동사다 — 입력 필드가 생기면 이 타입에서 확장한다.
export type DoctorInput = Record<string, never>;
export type DoctorVerb = VerbShape<DoctorInput>;

export type StatusVerb = VerbShape<StatusInput>;

// db create — 첫 변이 동사(공유 변이 엔진 lib/mutation.ts의 첫 인스턴스).
export type DbCreateInput = WaitInput & { name: string; ext?: string[] };
export type DbCreateVerb = VerbShape<DbCreateInput>;

// cache create — 변이 엔진의 두 번째 인스턴스(create-cache 디스패처).
export type CacheCreateInput = WaitInput & { name: string; maxmemoryMi?: number };
export type CacheCreateVerb = VerbShape<CacheCreateInput>;

// CLI 전용 패스스루 동사 — 산출이 로컬 파일 기록이라 envelope 계약 밖(같은 동작 재노출이 계약).
// MCP에서의 형상은 MCP 티켓이 결정한다.
export type CliOnlyVerb = { path: readonly string[]; desc: string; cliOnly: true };

// app create — 수동 머지 변이(머지 = 공개 승인, auto-merge:false — _create-app.yaml).
export type AppCreateInput = WaitInput & { app: string };
export type AppCreateVerb = VerbShape<AppCreateInput>;

// app secrets — 이중 모드 변이(lib/secrets.ts 엔진이 연쇄, 디스패치는 공유 변이 엔진).
export type AppSecretsVerb = VerbShape<AppSecretsInput>;

// 전 동사의 union — 후속 동사가 멤버로 추가된다.
export type Verb = DoctorVerb | StatusVerb | DbCreateVerb | CacheCreateVerb | AppCreateVerb | AppSecretsVerb | CliOnlyVerb;

function doctorOp(_input: DoctorInput): Envelope {
  const { checks, summary } = runDoctor();
  const variant = summary.fail > 0 ? "failure" : "success";
  return { schema: ENVELOPE, verb: "doctor", variant, exitCode: exitFor(variant), omitted: [], result: { checks, summary } };
}

// 디스패처 체크박스 5종과 1:1 — 목록 밖 확장은 ext_extra로 간다(디스패처 계약).
const KNOWN_EXTS = ["pg_trgm", "pgcrypto", "citext", "vector", "postgis"] as const;

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)가 공유. 이름·확장 형식은 identity SSOT.
export function dbCreateInputError(input: DbCreateInput): string | null {
  const nameErr = resourceNameError("db", input.name ?? "");
  if (nameErr) return nameErr;
  for (const e of input.ext ?? []) {
    if (!EXT_RE.test(e)) return `확장 이름 형식 불량: ${e}`;
  }
  return waitInputError(input);
}

function dbCreateOp(input: DbCreateInput): Envelope {
  const bad = dbCreateInputError(input);
  if (bad) throw new Error(`계약 파손: dbCreateOp에 검증 안 된 입력 — ${bad}`);
  const exts = input.ext ?? [];
  const extra = exts.filter((e) => !(KNOWN_EXTS as readonly string[]).includes(e));
  const { variant, omitted, result } = runMutation({
    action: "create-database",
    workflow: "create-database.yaml",
    dispatchInputs: [
      ["name", input.name],
      ...KNOWN_EXTS.map((k): [string, string] => [`ext_${k}`, String(exts.includes(k))]),
      ["ext_extra", extra.join(",")],
    ],
    branchFor: (runId) => `create-database/${input.name}-${runId}`, // 명명 SSOT: _create-database.yaml
    applications: [ // 명명된 수렴 집합(스펙 대기 매트릭스) + 관측 표면(provision-db 산출 경로)
      { name: "cnpg-data", surfacePath: `platform/cnpg/prod/databases/${input.name}.yaml` },
      { name: "data-conn-prod", surfacePath: `platform/data-conn/prod/db-${input.name}-conn.sealed.yaml` },
    ],
    resultBase: { action: "create-database", name: input.name },
  }, waitOpts(input));
  return { schema: ENVELOPE, verb: "db create", variant, exitCode: exitFor(variant), omitted, result };
}

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)가 공유. 범위는 디스패처 계약(16..1024).
export function cacheCreateInputError(input: CacheCreateInput): string | null {
  const nameErr = resourceNameError("cache", input.name ?? "");
  if (nameErr) return nameErr;
  if (input.maxmemoryMi !== undefined && !(Number.isInteger(input.maxmemoryMi) && input.maxmemoryMi >= CACHE_MAXMEMORY_MI.min && input.maxmemoryMi <= CACHE_MAXMEMORY_MI.max)) {
    return `--maxmemory-mi는 ${CACHE_MAXMEMORY_MI.min}..${CACHE_MAXMEMORY_MI.max} 정수여야 한다: ${input.maxmemoryMi}`;
  }
  return waitInputError(input);
}

function cacheCreateOp(input: CacheCreateInput): Envelope {
  const bad = cacheCreateInputError(input);
  if (bad) throw new Error(`계약 파손: cacheCreateOp에 검증 안 된 입력 — ${bad}`);
  const { variant, omitted, result } = runMutation({
    action: "create-cache",
    workflow: "create-cache.yaml",
    dispatchInputs: [
      ["name", input.name],
      // 빈 값 = 디스패처 기본(64) 소유 — CLI가 기본값을 복제하지 않는다.
      ["maxmemory_mi", input.maxmemoryMi === undefined ? "" : String(input.maxmemoryMi)],
    ],
    branchFor: (runId) => `create-cache/${input.name}-${runId}`, // 명명 SSOT: _create-cache.yaml
    applications: [ // 명명된 수렴 집합(스펙 대기 매트릭스) + 관측 표면(provision-cache 산출 경로)
      { name: "cache-prod", surfacePath: `platform/cache/prod/${input.name}/deployment.yaml` },
      { name: "data-conn-prod", surfacePath: `platform/data-conn/prod/cache-${input.name}-conn.sealed.yaml` },
    ],
    resultBase: { action: "create-cache", name: input.name },
  }, waitOpts(input));
  return { schema: ENVELOPE, verb: "cache create", variant, exitCode: exitFor(variant), omitted, result };
}

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)가 공유.
export function appCreateInputError(input: AppCreateInput): string | null {
  if (!APP_NAME_RE.test(input.app ?? "")) return `앱 이름 형식 불량(소문자 kebab, 2..40): ${input.app}`;
  return waitInputError(input);
}

function appCreateOp(input: AppCreateInput): Envelope {
  const bad = appCreateInputError(input);
  if (bad) throw new Error(`계약 파손: appCreateOp에 검증 안 된 입력 — ${bad}`);
  const { variant, omitted, result } = runMutation({
    action: "create-app",
    workflow: "create-app.yaml",
    dispatchInputs: [["app", input.app]],
    branchFor: (runId) => `create-app/${input.app}-${runId}`, // 명명 SSOT: _create-app.yaml
    applications: [ // 해당 앱 Application + 배포 핀 표면(create-app 산출)
      { name: `${input.app}-prod`, surfacePath: `apps/${input.app}/deploy/prod/values.yaml` },
    ],
    resultBase: { action: "create-app", name: input.app },
    manualMerge: true, // 머지 = 공개 승인 — auto-merge를 켜는 어떤 경로도 없다
  }, waitOpts(input));
  return { schema: ENVELOPE, verb: "app create", variant, exitCode: exitFor(variant), omitted, result };
}

function appSecretsOp(input: AppSecretsInput): Envelope {
  const bad = appSecretsInputError(input);
  if (bad) throw new Error(`계약 파손: appSecretsOp에 검증 안 된 입력 — ${bad}`);
  const { variant, omitted, result } = runAppSecrets(input);
  return { schema: ENVELOPE, verb: "app secrets", variant, exitCode: exitFor(variant), omitted, result };
}

function statusOp(input: StatusInput): Envelope {
  // 입력 검증은 어댑터(CLI usage 오류)·MCP(invalid params)가 같은 술어로 선행한다 — 도달하면 결함.
  const bad = statusInputError(input);
  if (bad) throw new Error(`계약 파손: statusOp에 검증 안 된 입력 — ${bad}`);
  const { variant, omitted, result } = runStatus(input);
  return { schema: ENVELOPE, verb: "status", variant, exitCode: exitFor(variant), omitted, result };
}

// named export — CLI 어댑터·MCP가 정확한 입력 타입으로 호출한다(union 좁히기 불필요).
export const DOCTOR: DoctorVerb = {
  path: ["doctor"],
  desc: "플랫폼 전제 진단(gh 인증·owner 일치·스코프 / bun·kubeseal / KUBECONFIG / 템플릿 호환성)",
  op: doctorOp,
};

// named export — CLI 어댑터·MCP가 정확한 입력 타입으로 호출한다.
export const STATUS: StatusVerb = {
  path: ["status"],
  desc: "앱 상태 관찰(목록/단일 앱: 핀·바인딩·run·PR·ArgoCD) + 핸들(run/PR URL) 조회",
  op: statusOp,
};

// named export — CLI 어댑터·MCP가 정확한 입력 타입으로 호출한다.
export const DB_CREATE: DbCreateVerb = {
  path: ["db", "create"],
  desc: "공유 CNPG에 논리 DB 생성(create-database 디스패치 + correlation 추적, --wait=배포 수렴까지)",
  op: dbCreateOp,
};

// 기존 도구 재노출(같은 동작) — tools/db-url.ts 패스스루(CLI 셸이 spawn).
export const DB_URL: CliOnlyVerb = {
  path: ["db", "url"],
  desc: "클러스터 DB 접속 URL을 .env.local에 기록(기존 db:url 재노출 — 평문 stdout 비노출)",
  cliOnly: true,
};

export const CACHE_CREATE: CacheCreateVerb = {
  path: ["cache", "create"],
  desc: "앱별 Valkey 캐시 생성(create-cache 디스패치 + correlation 추적, --wait=배포 수렴까지)",
  op: cacheCreateOp,
};

// 기존 도구 재노출(같은 동작) — tools/cache-url.ts 패스스루(CLI 셸이 spawn).
export const CACHE_URL: CliOnlyVerb = {
  path: ["cache", "url"],
  desc: "캐시 접속 URL을 .env.local에 기록(기존 cache:url 재노출 — port-forward 선행, 평문 stdout 비노출)",
  cliOnly: true,
};

// 열거 SSOT — 라우팅 어휘(TREE)·usage·MCP tool 목록이 여기서 파생된다.
export const APP_CREATE: AppCreateVerb = {
  path: ["app", "create"],
  desc: "빌드된 앱을 homelab에 등록(create-app 디스패치 — 수동 머지: 머지가 곧 공개 승인)",
  op: appCreateOp,
};

export const APP_SECRETS: AppSecretsVerb = {
  path: ["app", "secrets"],
  desc: "앱 시크릿 봉인본 배선(앱 레포 안: seal→커밋→push→디스패치 연쇄 / 밖: update-secrets 디스패치만)",
  op: appSecretsOp,
};

export const VERBS: readonly Verb[] = [DOCTOR, STATUS, DB_CREATE, DB_URL, CACHE_CREATE, CACHE_URL, APP_CREATE, APP_SECRETS];
