// 변이 레인 신원 SSOT — 디스패처 한 레인의 신원(디스패치 입력 이름 · PR 브랜치 문법 ·
// 수렴 Application 집합 · 표면 경로)을 동사당 한 행으로 성문화한다.
// 생성 방향(verbs·secrets의 MutationSpec 조립)과 파싱 방향(status의 레인 판별)이 같은 행에서
// 파생되어, "명명 SSOT: _*.yaml" 주석으로만 연결되던 리터럴 사본들이 소멸한다. 워크플로 YAML과의
// 일치는 정적 parity 가드가 대조한다(reusable 필드가 그 대조 축이다).
//
// ⚠️ 순수 기술자 — import 0 계약(설계 게이트 r1 D3): 계약 독자(contract.ts)도, 생성물 JSON도,
// 엔진(mutation.ts)도, 이미지 핀(image-pin.ts)도 참조하지 않는다. 스키마 생성기(심화 3)와
// 런타임이 순환 없이 같은 행을 소비하기 위한 전제이며, test_lane-rows.bats가 import 0을 강제한다.
//
// 패턴 토큰 2종: {key}(앱/리소스 이름) · {runId}(디스패처 run id — 형식 \d+는 이 레인 문법의
// 소유라 여기서 검증). bump-poll 브랜치 문법은 이 표의 소관이 아니다 — SSOT는
// tools/lib/bump-plan.ts(parseBranch, kind 인코딩)이고, 파싱 전용 행을 여기 두면 두 번째 진실이
// 된다(18에서 폐기 — 낡은 `bump-poll/{key}-{tag}` 문법을 자기 테스트만 소비하며 고정하고 있었다).

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

// ── 결과 계약 행 ──────────────────────────────────────────────────────────────
// verb당 한 행: 허용 variant 집합 · (mutation 계열) action 고정·chain 극성 · result 정의 참조.
// cli-result-schema.json의 행렬 분기(allOf member 0)와 verb enum이 이 행에서 생성된다
// (tools/generate-result-schema.ts — byte 동일 드리프트 게이트가 강제). 행 순서가 곧 분기·enum
// 순서다. definitions 본문·x-contract·variant→exitCode 재진술은 생성기 내 수제 조각으로 남고,
// 열거 붕괴를 막는 손 앵커는 계약 bats가 소유한다.

export type MutationVariantName = "success" | "failure" | "race" | "pending" | "superseded" | "no-op";

export type ContractRow = {
  verb: string;
  // mutation 행렬 동사 — 공유 mutation* 정의에 action 고정 + chain·exposure 극성 결합으로 전개된다.
  // refusedOnFailure: failure가 **디스패치 전 거부**(mutationRefused)와의 oneOf인 동사 —
  // app secrets의 연쇄 거부와 app create의 사전 판정 거부. 거부 형상의 필수 증거는
  // 별도 칸이 아니라 chain 극성에서 파생한다(chain 레인=chain · 비-chain 레인=preflight).
  // exposure: 결과에 공개 노출 경계 부인문(dnsExposure)이 실리는 레인 — 공개 표면을 만드는 create-app뿐.
  // 극성 결합이라 다른 레인은 그 필드를 **실을 수 없다**(chain과 같은 관용구 — verb↔필드 교차 배선 차단).
  mutation?: { action: LaneAction; chain: boolean; exposure?: true; variants: readonly MutationVariantName[]; refusedOnFailure?: true };
  // 단순 동사 — variant 집합별 result 정의 참조.
  simple?: readonly { variants: readonly string[]; ref: string }[];
};

export const CONTRACT_ROWS: readonly ContractRow[] = [
  // doctor·status는 variant별 ref로 갈라져 있다(teardown 선례) — 한 ref가 여러 variant를 받으면
  // verb→variant 집합만 묶이고 **variant→result 형상**은 안 묶여서, success에 error가 실린
  // envelope·failure에 성공 형상이 실린 envelope이 전부 스키마 유효였다(리뷰 실측).
  // doctor는 summary.fail 상/하한으로 갈라 exitCode 거짓말을 스키마가 독립 검출한다.
  { verb: "doctor", simple: [
    { variants: ["success"], ref: "doctorOk" },
    { variants: ["failure"], ref: "doctorFailed" },
  ] },
  // status의 race — `--branch` 정확 조회에서 브랜치 하나에 PR이 2개인 경우(신원 판정 불가, exit 3).
  // 리더도 fail-closed다: 임의로 하나를 고르면 그 뒤의 모든 보고가 오귀속이 된다. 형상이 성공·실패와
  // 달라(observedPrs + error) 별도 ref로 분리한다 — 성공 union(statusOk)에 넣으면 성공 봉투가 race
  // 형상으로도 유효해진다.
  { verb: "status", simple: [
    { variants: ["success"], ref: "statusOk" },
    { variants: ["failure"], ref: "statusError" },
    { variants: ["race"], ref: "statusRace" },
  ] },
  { verb: "db create", mutation: { action: "create-database", chain: false, variants: ["success", "failure", "race", "pending", "superseded"] } },
  { verb: "cache create", mutation: { action: "create-cache", chain: false, variants: ["success", "failure", "race", "pending", "superseded"] } },
  { verb: "app create", mutation: { action: "create-app", chain: false, exposure: true, variants: ["success", "failure", "race", "pending", "superseded"], refusedOnFailure: true } },
  { verb: "app secrets", mutation: { action: "update-secrets", chain: true, variants: ["success", "failure", "race", "pending", "superseded", "no-op"], refusedOnFailure: true } },
  { verb: "app teardown", simple: [
    { variants: ["success"], ref: "teardownSuccess" },
    { variants: ["failure"], ref: "teardownFailure" },
    { variants: ["race"], ref: "teardownRace" },
    { variants: ["pending"], ref: "teardownPending" },
  ] },
  { verb: "app init", simple: [
    { variants: ["success", "no-op"], ref: "initSuccess" },
    { variants: ["failure"], ref: "initFailure" },
  ] },
  // skip: 클러스터 도메인 부재(KUBECONFIG 미설정 — conn-url 엔진의 skipNoCluster) — exitCode 4 +
  // CLI 셸의 stderr 마커(x-contract.exitRationale)와 짝이다.
  { verb: "db url", simple: [{ variants: ["success", "failure", "skip"], ref: "urlResult" }] },
  { verb: "cache url", simple: [{ variants: ["success", "failure", "skip"], ref: "urlResult" }] },
];

// create-database 디스패처 체크박스 확장 목록 — 행 inputs에서 파생한다(ext_ 접두 규약,
// ext_extra는 목록 밖 확장 전용 입력이라 제외). 파생 규약은 행 옆(여기)이 소유한다 —
// 소비자(verbs.ts)가 접두 규약을 재구현하지 않는다.
export const DB_CHECKBOX_EXTS: readonly string[] = LANES["create-database"].inputs
  .filter((i) => i.startsWith("ext_") && i !== "ext_extra")
  .map((i) => i.slice("ext_".length));

// 중립 패턴 채움 — {key}는 항상, {runId}는 주어진 것만 치환한다(순수 문자열 유도).
export function fillLanePattern(pattern: string, vars: { key: string; runId?: number | string }): string {
  let out = pattern.split("{key}").join(vars.key);
  if (vars.runId !== undefined) out = out.split("{runId}").join(String(vars.runId));
  return out;
}

// 패턴의 tail 토큰 판정 — {runId}가 정확히 1회, 그리고 말미여야 한다. 아니면 행 데이터
// 결함이므로 fail-closed로 던진다(토큰 없는 패턴을 스니핑하면 slice가 엉뚱한 접두를 만들어
// 임의 head에 non-null tail을 내는 fail-open이 된다 — 리뷰 실측). {tag} 토큰은 18에서 폐기 —
// tag tail은 bump 문법이고 그 SSOT는 bump-plan.ts다.
function tailToken(pattern: string): "{runId}" {
  const count = (t: string): number => pattern.split(t).length - 1;
  if (!(count("{runId}") === 1 && pattern.endsWith("{runId}"))) {
    throw new Error(`계약 파손: branchPattern은 tail 토큰({runId}) 정확히 1개로 끝나야 한다 — ${pattern}`);
  }
  return "{runId}";
}

// 파싱 방향 — head가 (pattern, key)의 구조에 부합하면 tail(말미 토큰 자리의 문자열)을 낸다.
// 접두만 보면 하이픈 앱명에서 형제를 오귀속하므로(page ↔ page-extra), tail "형식" 검증까지
// 합쳐야 판정이 완성된다: runId 형식은 isDispatchLaneBranch가 여기서 소유한다.
export function laneBranchTail(pattern: string, key: string, head: string): string | null {
  const token = tailToken(pattern);
  // assertFilled — 미지 토큰이 남은 행 데이터 결함은 조용한 영구 미매치가 아니라 loud다(생성
  // 방향의 laneMutationFields와 대칭 — 파싱 방향만 조용하면 결함이 null로 위장한다).
  const prefix = assertFilled(fillLanePattern(pattern.slice(0, pattern.length - token.length), { key }));
  return head.startsWith(prefix) ? head.slice(prefix.length) : null;
}

// 디스패처 레인 브랜치 판정 — 구조(prefix) + tail 형식(\d+ = run id)까지.
export function isDispatchLaneBranch(pattern: string, key: string, head: string): boolean {
  const t = laneBranchTail(pattern, key, head);
  return t !== null && /^\d+$/.test(t);
}

// 파싱 방향의 **전수 역함수** — head 하나로 (레인 행 · 키 · run id)를 낸다.
// isDispatchLaneBranch는 (pattern, key, head) 3항이라 "키를 이미 아는" 질문만 답한다. 열린 PR
// 목록에서 "이건 어느 레인의 무슨 키인가"를 물을 때는 키가 미지수이고, 소비자가 자기 정규식을
// 유도하면 브랜치 문법의 두 번째 진실이 된다 — 그래서 행 데이터가 이 역도 소유한다.
// 판정 = 패턴의 {key} 앞 접두 일치 + {key}·{runId} 사이 구분자의 **마지막** 출현 + tail이 \d+.
// 마지막 출현을 쓰는 이유는 {runId}가 tail 토큰이기 때문이다(하이픈 키 `my-app`이 접두 분할에서
// 잘리지 않는다 — laneBranchTail이 tail 형식까지 봐야 완성되는 것과 같은 이유).
// ⚠️ 키의 **이름 정책은 여기서 판정하지 않는다** — import 0 계약(순수 기술자)이라 identity.ts를
//    읽을 수 없고, 형식을 여기 베끼면 그게 두 번째 진실이다. 형식 검증은 콜사이트가 행의
//    keyKind에 맞는 SSOT RE(APP_NAME_RE / RESOURCE_NAME_RE)로 한다.
export function parseDispatchLaneBranch(head: string): { action: LaneAction; key: string; runId: number } | null {
  for (const row of Object.values(LANES)) {
    const token = tailToken(row.branchPattern);          // 행 데이터 결함이면 loud(조용한 미매치 금지)
    const parts = row.branchPattern.split("{key}");
    if (parts.length !== 2) continue;                    // {key}가 정확히 1개가 아닌 패턴은 이 역의 도메인 밖
    const before = parts[0]!;
    const sep = parts[1]!.slice(0, parts[1]!.length - token.length); // {key}와 {runId} 사이
    if (sep === "" || !head.startsWith(before)) continue;
    const rest = head.slice(before.length);
    const cut = rest.lastIndexOf(sep);
    if (cut <= 0) continue;                              // 키가 비면 판정 아님(빈 키는 신원이 아니다)
    const tail = rest.slice(cut + sep.length);
    if (!/^\d+$/.test(tail)) continue;
    return { action: row.action, key: rest.slice(0, cut), runId: Number(tail) };
  }
  return null;
}

// 채움 결과에 토큰이 남으면 행 데이터 결함 — 조용히 "{runId}" 박힌 경로가 흐르는 대신 던진다.
function assertFilled(s: string): string {
  if (s.indexOf("{") >= 0) throw new Error(`계약 파손: 패턴 토큰 잔존 — ${s}`);
  return s;
}

// MutationSpec의 레인 파생 필드(action·workflow·branchFor·branchPattern·key·applications) —
// 콜사이트는 여기에 dispatchInputs(값)·resultBase·variant 축(manualMerge/converge/noopOnMissingPr)을
// 더한다. branchFor 시그니처는 mutation.ts 계약과 동일.
// branchPattern·key는 **채우지 않은 좌표**다 — 엔진의 중복 디스패치 preflight가 "열린 PR 하나가
// 이 레인·이 키의 것인가"를 물을 때 run id를 모르기 때문에 채운 브랜치(branchFor)로는 답이 없다.
// 여기서 함께 내보내야 콜사이트 5곳이 `...lane` 스프레드만으로 배선되고, 새 레인이 그 배선을
// 잊을 자리가 없다(MutationSpec의 필수 필드라 타입이 강제한다).
export function laneMutationFields(action: LaneAction, key: string): {
  action: LaneAction;
  workflow: string;
  branchFor: (runId: number) => string;
  branchPattern: string;
  key: string;
  applications: Array<{ name: string; surfacePath: string }>;
} {
  const row = LANES[action];
  return {
    action,
    workflow: row.workflow,
    branchFor: (runId: number) => assertFilled(fillLanePattern(row.branchPattern, { key, runId })),
    branchPattern: row.branchPattern,
    key,
    applications: row.applications.map((a) => ({
      name: assertFilled(fillLanePattern(a.name, { key })),
      surfacePath: assertFilled(fillLanePattern(a.surfacePath, { key })),
    })),
  };
}
