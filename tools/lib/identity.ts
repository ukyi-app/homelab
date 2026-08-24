// 앱-이름 식별자 SSOT — 모든 mutator(create-app/teardown-app/validate-mutation/
// activate-app/bump-tag)가 이 정규식을 공유한다. 정책은 validate-mutation의 화이트리스트:
// 소문자 시작, 소문자/숫자/하이픈, **trailing hyphen 금지**, 길이 2..40.
// path traversal·오라우팅 방어의 1차 게이트이므로 분기 금지(콜사이트마다 다르면 우회 표면이 생긴다).
export const APP_NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;

// db/cache 리소스 이름 SSOT — provision-db/provision-cache(실행기)·validate-mutation(디스패처)·
// db-url/cache-url/teardown-resource(소비자)가 공유. 정책: 소문자 시작, kebab, trailing hyphen 금지,
// 길이 1..30(single-char 허용·k8s 파생명 db-<name>-ro-conn ≤63 여유). 디스패처가 느슨하면
// 통과시킨 이름을 실행기가 거부하는 계약 갭이 생긴다 — 한 곳에서만 정의한다.
export const RESOURCE_NAME_RE = /^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$/;

// postgres extension 이름 — underscore 허용(pg_trgm 등). validate-mutation·provision-db 공유.
export const EXT_RE = /^[a-z][a-z0-9_-]*$/;

// cache maxmemory 범위 SSOT — 디스패처(validate-mutation)·실행기(provision-cache)·CLI(verbs)가
// 공유한다. 셋이 갈리면 디스패처가 통과시킨 값을 실행기가 거부하는 계약 갭이 생긴다(이름과 동일 원칙).
export const CACHE_MAXMEMORY_MI = { min: 16, max: 1024 } as const;

// correlation nonce SSOT — 변이 디스패처 run-name 에코용 수령증(CLI가 호출마다 생성해 자기 run을
// 권위 있게 특정). 정책: 소문자/숫자/하이픈, 선행·후행 하이픈 금지, 길이 8..64.
// validate-mutation(디스패처)·CLI 생성기가 공유 — 둘이 다르면 CLI가 만든 nonce를 디스패처가 거부하는 계약 갭.
export const CORRELATION_RE = /^[a-z0-9][a-z0-9-]{6,62}[a-z0-9]$/;

// canonical 클론 판정 SSOT — init(ensureClone)·secrets(runAppSecrets)가 공유한다(cli-deepening 심화 1).
// 앵커드 3-scheme + .git 허용, host 무앵커/경로 중첩/credential/포트 전부 거부. 판정이 콜사이트마다
// 다르면 오귀속(엉뚱한 레포에 마커·push·디스패치) 우회 표면이 생긴다 — APP_NAME_RE와 같은 원칙.
// owner·app은 이름 정책(APP_NAME_RE류)을 통과한 값이라 regex 메타문자가 없다.
export function isCanonicalClone(owner: string, app: string, originUrl: string): boolean {
  return new RegExp(`^(https://github\\.com/|git@github\\.com:|ssh://git@github\\.com/)${owner}/${app}(\\.git)?$`).test(originUrl.trim());
}

// push 라우팅 안전 — push 지향 관측(exec.ts pushRoutes: `git remote get-url --push --all`)이 열거한
// 목적지 **전부**가 canonical일 때만 통과. 0개 = fail-closed. remote.origin.url(원본 설정값)이
// canonical이어도 pushurl/insteadOf/pushInsteadOf가 push를 다른 곳으로 보낼 수 있으므로(설계 게이트
// r1 D1·r2 D1′ — ls-remote --get-url은 fetch 지향이라 pushInsteadOf를 못 본다) 구성 신원과 별개 축이다.
export function isSafePushRoute(owner: string, app: string, routes: string[]): boolean {
  return routes.length > 0 && routes.every((r) => isCanonicalClone(owner, app, r));
}

// push 라우팅 진단 — 관측 결과(routes: 관측 실패면 null)를 받아 거부 사유 또는 null(안전)을 낸다.
// init·secrets가 같은 진단을 공유해, 관측 실패 vs 비-canonical의 구분이 동사 간에 갈리지 않는다.
// 관측 자체는 exec.ts pushRoutes 소유 — 이 함수는 순수하다.
export function pushRouteError(owner: string, app: string, routes: string[] | null): string | null {
  if (routes === null) return "push 경로 관측 실패(git remote get-url --push --all origin)";
  if (!isSafePushRoute(owner, app, routes)) {
    return `push 경로가 canonical ${owner}/${app}가 아니다(${routes.join(", ") || "0개"}) — pushurl/insteadOf 재배선 의심`;
  }
  return null;
}

// db/cache 예약 이름 — 실행기·디스패처 공유(둘이 다르면 디스패처 통과→실행기 거부 갭).
// db: 시스템 롤/DB·bootstrap initdb(app)와 충돌하면 클러스터가 깨진다.
const DB_RESERVED_NAMES = new Set(["app", "postgres", "pg", "template0", "template1", "streaming_replica"]);

// 리소스 이름 정책(형식 + 예약) 단일 검사. null=유효, 아니면 거부 사유.
//   '-ro' 접미사: db·cache 공통 예약(foo-ro의 conn이 foo의 읽기전용 conn과 충돌 — provision-db/cache 양쪽에 있던 가드, F8).
export function resourceNameError(kind: "db" | "cache", name: string): string | null {
  if (!RESOURCE_NAME_RE.test(name)) return `이름 형식 불량(소문자 kebab, trailing hyphen 금지, ≤30): ${name}`;
  if (/-ro$/.test(name)) return `'-ro' 접미사 예약: ${name} (읽기전용 conn 이름과 충돌)`; // db·cache 공통(F8)
  if (kind === "db" && DB_RESERVED_NAMES.has(name)) return `예약된 DB 이름: ${name}`;
  return null;
}
