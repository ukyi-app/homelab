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
