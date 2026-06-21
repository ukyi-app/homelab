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

// db/cache 예약 이름 — 실행기·디스패처 공유(둘이 다르면 디스패처 통과→실행기 거부 갭).
// db: 시스템 롤/DB·bootstrap initdb(app)와 충돌하면 클러스터가 깨진다.
export const DB_RESERVED_NAMES = new Set(["app", "postgres", "pg", "template0", "template1", "streaming_replica"]);

// 리소스 이름 정책(형식 + 예약) 단일 검사. null=유효, 아니면 거부 사유.
//   '-ro' 접미사: db·cache 공통 예약(foo-ro의 conn이 foo의 읽기전용 conn과 충돌 — provision-db/cache 양쪽에 있던 가드, F8).
export function resourceNameError(kind: "db" | "cache", name: string): string | null {
  if (!RESOURCE_NAME_RE.test(name)) return `이름 형식 불량(소문자 kebab, trailing hyphen 금지, ≤30): ${name}`;
  if (/-ro$/.test(name)) return `'-ro' 접미사 예약: ${name} (읽기전용 conn 이름과 충돌)`; // db·cache 공통(F8)
  if (kind === "db" && DB_RESERVED_NAMES.has(name)) return `예약된 DB 이름: ${name}`;
  return null;
}
