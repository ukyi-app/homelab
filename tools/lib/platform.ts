// 플랫폼 좌표 SSOT — homelab CLI(doctor·이후 init/status 등)가 참조하는 canonical 레포·아키타입.
// 콜사이트마다 문자열이 갈리면 doctor가 검증한 대상과 init이 실제로 쓰는 대상이 어긋나는
// 표면이 생기므로 한 곳에서만 정의한다(identity.ts와 같은 원칙 — 저긴 이름 형식, 여긴 좌표).
export const HOMELAB_REPO = "ukyi-app/homelab";
export const TEMPLATE_REPO = "ukyi-app/homelab-app-template";
// 레포 owner — 소비자(init·secrets 등)가 각자 split하면 파생 지점이 갈리므로 여기서만 유도한다.
export const OWNER = HOMELAB_REPO.split("/")[0];

// 아키타입 어휘(CONTEXT.md 용어 — kind는 아키타입 유도값이라 여기 없다). 어휘 리터럴은 이 배열
// 한 곳뿐이고 나머지 표면은 전부 파생이다: MCP inputSchema enum(mcp.ts)·결과 계약 enum(생성기)·
// CLI 사용법(homelab.ts)·doctor 검사 대상(COMPILED_ARCHETYPES). test_platform.bats 전역 가드가 강제.
//
// 확장 절차(아키타입 추가): ① 이 배열에 추가(순서 = 결과 계약 enum 순서) → ② arch 중립이면
// ARCH_NEUTRAL_ARCHETYPES에도 추가(기본은 컴파일 = doctor TARGETARCH 검사 대상, fail-closed) →
// ③ `bun tools/generate-result-schema.ts --write`(결과 계약 재생성 — byte 드리프트 게이트가 강제) →
// ④ bats 손 앵커 갱신(독립 앵커 원칙상 의도된 이중부기 — test_platform·test_homelab-mcp·
// test_result-schema-gen·test_homelab-appinit·test_homelab-doctor, 각 red가 위치를 가리킨다).
export const ARCHETYPES = ["api", "fullstack", "site", "worker"] as const;
export type Archetype = (typeof ARCHETYPES)[number];

// 산출물이 arch 중립인 아키타입 — Dockerfile에 TARGETARCH가 없는 것이 정상이라 doctor의
// TARGETARCH 파라미터화 검사에서 제외한다(site: ticket 03 amd64 스모크 실측, 커밋 a37834c —
// exec format error red → 수리 후 스모크 green). 명시 opt-out 목록이다: 여기 없는 아키타입은 전부 검사 대상.
export const ARCH_NEUTRAL_ARCHETYPES = ["site"] as const satisfies readonly Archetype[];

// TARGETARCH 파라미터화 검사 대상 = ARCHETYPES − 중립. 리터럴 사본이 아니라 여집합이라 신규
// 아키타입은 기본으로 검사 대상에 편입된다 — 4종 전수 검사면 정상 템플릿(site)에서 fail이므로
// 중립만 뺀다.
export const COMPILED_ARCHETYPES: readonly Archetype[] =
  ARCHETYPES.filter((a) => !(ARCH_NEUTRAL_ARCHETYPES as readonly string[]).includes(a));
