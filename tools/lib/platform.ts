// 플랫폼 좌표 SSOT — homelab CLI(doctor·이후 init/status 등)가 참조하는 canonical 레포·아키타입.
// 콜사이트마다 문자열이 갈리면 doctor가 검증한 대상과 init이 실제로 쓰는 대상이 어긋나는
// 표면이 생기므로 한 곳에서만 정의한다(identity.ts와 같은 원칙 — 저긴 이름 형식, 여긴 좌표).
export const HOMELAB_REPO = "ukyi-app/homelab";
export const TEMPLATE_REPO = "ukyi-app/homelab-app-template";

// 아키타입 어휘(CONTEXT.md 용어 — kind는 아키타입 유도값이라 여기 없다).
export const ARCHETYPES = ["api", "fullstack", "site", "worker"] as const;

// TARGETARCH 파라미터화 검사 대상 = 컴파일 아키타입 3종만. site는 산출물이 arch 중립이라
// Dockerfile에 TARGETARCH가 없는 것이 정상이다 — 4종 전수 검사면 정상 템플릿에서 fail
// (ticket 03 실측, docs/reviews/homelab-cli/ticket-03-amd64-smoke.md).
export const COMPILED_ARCHETYPES = ["api", "fullstack", "worker"] as const;
