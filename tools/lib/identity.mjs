// 앱-이름 식별자 SSOT — 모든 mutator(create-app/onboard-app/teardown-app/validate-mutation/
// activate-app/bump-tag)가 이 정규식을 공유한다. 정책은 validate-mutation의 화이트리스트:
// 소문자 시작, 소문자/숫자/하이픈, **trailing hyphen 금지**, 길이 2..40.
// path traversal·오라우팅 방어의 1차 게이트이므로 분기 금지(콜사이트마다 다르면 우회 표면이 생긴다).
export const APP_NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;
