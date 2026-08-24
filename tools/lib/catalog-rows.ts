// 변이 레인 신원 SSOT — 디스패처 한 레인의 신원(디스패치 입력 이름 · PR 브랜치 문법 ·
// 수렴 Application 집합 · 표면 경로)을 동사당 한 행으로 성문화한다(cli-deepening 심화 2).
// 생성 방향(verbs·secrets의 MutationSpec 조립)과 파싱 방향(status의 레인 판별)이 같은 행에서
// 파생되어, "명명 SSOT: _*.yaml" 주석으로만 연결되던 리터럴 사본들이 소멸한다. 워크플로 YAML과의
// 일치는 정적 parity 가드가 대조한다(티켓 03 — reusable 필드가 그 대조 축이다).
//
// ⚠️ 순수 기술자 — import 0 계약(설계 게이트 r1 D3): 계약 독자(contract.ts)도, 생성물 JSON도,
// 엔진(mutation.ts)도, 이미지 핀(image-pin.ts)도 참조하지 않는다. 스키마 생성기(심화 3)와
// 런타임이 순환 없이 같은 행을 소비하기 위한 전제이며, test_lane-rows.bats가 import 0을 강제한다.
//
// 패턴 토큰 3종: {key}(앱/리소스 이름) · {runId}(디스패처 run id — 형식 \d+는 이 레인 문법의
// 소유라 여기서 검증) · {tag}(배포 핀 tag — 형식 SSOT는 image-pin.ts TAG_RE이고 import 0
// 계약상 검증은 소비자(status.ts)가 조합한다).

export type LaneApp = { name: string; surfacePath: string }; // 이름·경로 모두 {key} 패턴 허용(산출 필드명과 동일)
export type LaneAction = "create-database" | "create-cache" | "create-app" | "update-secrets" | "teardown-app";

export type LaneRow = {
  action: LaneAction;
  workflow: string;            // 디스패처 파일(workflow_dispatch 진입점 — 변이 argv의 대상)
  reusable: string;            // _*.yaml — branch: 원본(정적 parity 가드의 대조 축)
  keyKind: "app" | "resource"; // status 앱 필터 대상 여부(리소스 키 레인은 앱 필터 밖)
  inputs: readonly string[];   // 디스패치 입력 이름(correlation 제외 — 엔진이 뒤에 붙인다)
  branchPattern: string;       // "…/{key}-{runId}" — 생성·파싱 쌍의 SSOT
  applications: readonly LaneApp[]; // 수렴 집합 + 관측 표면(실행기 산출 경로의 소비 사본)
};

export const LANES: Record<LaneAction, LaneRow> = {
  "create-database": {
    action: "create-database",
    workflow: "create-database.yaml",
    reusable: "_create-database.yaml",
    keyKind: "resource",
    inputs: ["name", "ext_pg_trgm", "ext_pgcrypto", "ext_citext", "ext_vector", "ext_postgis", "ext_extra"],
    branchPattern: "create-database/{key}-{runId}",
    applications: [
      { name: "cnpg-data", surfacePath: "platform/cnpg/prod/databases/{key}.yaml" },
      { name: "data-conn-prod", surfacePath: "platform/data-conn/prod/db-{key}-conn.sealed.yaml" },
    ],
  },
  "create-cache": {
    action: "create-cache",
    workflow: "create-cache.yaml",
    reusable: "_create-cache.yaml",
    keyKind: "resource",
    inputs: ["name", "maxmemory_mi"],
    branchPattern: "create-cache/{key}-{runId}",
    applications: [
      { name: "cache-prod", surfacePath: "platform/cache/prod/{key}/deployment.yaml" },
      { name: "data-conn-prod", surfacePath: "platform/data-conn/prod/cache-{key}-conn.sealed.yaml" },
    ],
  },
  "create-app": {
    action: "create-app",
    workflow: "create-app.yaml",
    reusable: "_create-app.yaml",
    keyKind: "app",
    inputs: ["app"],
    branchPattern: "create-app/{key}-{runId}",
    applications: [{ name: "{key}-prod", surfacePath: "apps/{key}/deploy/prod/values.yaml" }],
  },
  "update-secrets": {
    action: "update-secrets",
    workflow: "update-secrets.yaml",
    reusable: "_update-secrets.yaml",
    keyKind: "app",
    inputs: ["app"],
    branchPattern: "update-secrets/{key}-{runId}",
    applications: [{ name: "{key}-prod", surfacePath: "apps/{key}/deploy/prod/{key}-secrets.sealed.yaml" }],
  },
  "teardown-app": {
    action: "teardown-app",
    workflow: "teardown-app.yaml",
    reusable: "_teardown-app.yaml",
    keyKind: "app",
    inputs: ["app", "confirm"],
    branchPattern: "teardown/teardown-app-{key}-{runId}",
    applications: [{ name: "{key}-prod", surfacePath: "apps/{key}/deploy/prod/values.yaml" }],
  },
};

// create-database 디스패처 체크박스 확장 목록 — 행 inputs에서 파생한다(ext_ 접두 규약,
// ext_extra는 목록 밖 확장 전용 입력이라 제외). 파생 규약은 행 옆(여기)이 소유한다 —
// 소비자(verbs.ts)가 접두 규약을 재구현하지 않는다.
export const DB_CHECKBOX_EXTS: readonly string[] = LANES["create-database"].inputs
  .filter((i) => i.startsWith("ext_") && i !== "ext_extra")
  .map((i) => i.slice("ext_".length));

// CLI 동사 없는 파싱 전용 레인 — bump-poll(브랜치는 GHA 플래너가 생성, tail=tag). 행 스키마가
// 이 변주를 수용해야 status의 6번째 파싱 축이 표 밖으로 새지 않는다.
export const PARSE_ONLY_LANES = [
  { lane: "bump-poll", branchPattern: "bump-poll/{key}-{tag}", tailKind: "tag" },
] as const;

// 중립 패턴 채움 — {key}는 항상, {runId}·{tag}는 주어진 것만 치환한다(순수 문자열 유도).
export function fillLanePattern(pattern: string, vars: { key: string; runId?: number | string; tag?: string }): string {
  let out = pattern.split("{key}").join(vars.key);
  if (vars.runId !== undefined) out = out.split("{runId}").join(String(vars.runId));
  if (vars.tag !== undefined) out = out.split("{tag}").join(vars.tag);
  return out;
}

// 패턴의 tail 토큰 판정 — 정확히 한 종류가 정확히 1회, 그리고 말미여야 한다. 아니면 행 데이터
// 결함이므로 fail-closed로 던진다(토큰 없는 패턴을 스니핑하면 slice가 엉뚱한 접두를 만들어
// 임의 head에 non-null tail을 내는 fail-open이 된다 — 리뷰 실측).
function tailToken(pattern: string): "{runId}" | "{tag}" {
  const count = (t: string): number => pattern.split(t).length - 1;
  const runId = count("{runId}");
  const tag = count("{tag}");
  const ok = (runId === 1 && tag === 0 && pattern.endsWith("{runId}")) || (tag === 1 && runId === 0 && pattern.endsWith("{tag}"));
  if (!ok) throw new Error(`계약 파손: branchPattern은 tail 토큰({runId}|{tag}) 정확히 1개로 끝나야 한다 — ${pattern}`);
  return pattern.endsWith("{runId}") ? "{runId}" : "{tag}";
}

// 파싱 방향 — head가 (pattern, key)의 구조에 부합하면 tail(말미 토큰 자리의 문자열)을 낸다.
// 접두만 보면 하이픈 앱명에서 형제를 오귀속하므로(page ↔ page-extra), tail "형식" 검증까지
// 합쳐야 판정이 완성된다: runId는 isDispatchLaneBranch가 여기서 소유하고, tag는 TAG_RE
// 소유자(소비자)가 조합한다.
export function laneBranchTail(pattern: string, key: string, head: string): string | null {
  const token = tailToken(pattern);
  const prefix = fillLanePattern(pattern.slice(0, pattern.length - token.length), { key });
  return head.startsWith(prefix) ? head.slice(prefix.length) : null;
}

// 디스패처 레인 브랜치 판정 — 구조(prefix) + tail 형식(\d+ = run id)까지.
export function isDispatchLaneBranch(pattern: string, key: string, head: string): boolean {
  const t = laneBranchTail(pattern, key, head);
  return t !== null && /^\d+$/.test(t);
}

// 채움 결과에 토큰이 남으면 행 데이터 결함 — 조용히 "{runId}" 박힌 경로가 흐르는 대신 던진다.
function assertFilled(s: string): string {
  if (s.indexOf("{") >= 0) throw new Error(`계약 파손: 패턴 토큰 잔존 — ${s}`);
  return s;
}

// MutationSpec의 레인 파생 필드(action·workflow·branchFor·applications) — 콜사이트는 여기에
// dispatchInputs(값)·resultBase·variant 축(manualMerge/converge/noopOnMissingPr)을 더한다.
// branchFor 시그니처는 mutation.ts 계약과 동일.
export function laneMutationFields(action: LaneAction, key: string): {
  action: LaneAction;
  workflow: string;
  branchFor: (runId: number) => string;
  applications: Array<{ name: string; surfacePath: string }>;
} {
  const row = LANES[action];
  return {
    action,
    workflow: row.workflow,
    branchFor: (runId: number) => assertFilled(fillLanePattern(row.branchPattern, { key, runId })),
    applications: row.applications.map((a) => ({
      name: assertFilled(fillLanePattern(a.name, { key })),
      surfacePath: assertFilled(fillLanePattern(a.surfacePath, { key })),
    })),
  };
}
