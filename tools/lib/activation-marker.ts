// .activation 마커(공개 앱 재노출 게이트의 SSOT) — create-app(공개 생성)과 activate-app(--flip)이
// 동일 포맷으로 남기고, audit-orphans가 registry projection으로 미검증 노출 드리프트를 잡는다.
// 마커가 없는 active&&public 앱은 재노출 게이트에서 영구 제외되므로, 두 생성 경로가 반드시 기록한다.
// (registry projection·마커 shape을 한 곳에 두어 콜사이트 간 키 순서/필드 drift를 방지 — 중복 구현 금지.)

export type RegistryProjection = { name: string; host: string | null; public: boolean };

// apps.json 행 → 마커 registry projection. 키 순서(name, host, public)는 audit의 JSON.stringify
// 동일성 비교 계약이므로 고정한다(순서가 다르면 비교가 오탐).
export function registryProjection(row: { name: string; host?: string | null; public?: boolean }): RegistryProjection {
  return { name: row.name, host: row.host ?? null, public: row.public ?? false };
}

export type ActivationMarker = {
  app: string;
  sha: string | null;
  syncedRev: string | null;
  surfaceHash: string;
  registry: RegistryProjection;
  activatedAt: string;
};

// 마커 오브젝트 빌더. sha/syncedRev는 activate-app(--flip)에선 증명된 값, create-app에선 생성 시점
// 미확정(PR 머지 sha는 미래)이라 null. surfaceHash는 canonical(.activation 제외).
export function buildActivationMarker(opts: {
  app: string;
  surfaceHash: string;
  registry: RegistryProjection;
  sha?: string | null;
  syncedRev?: string | null;
  activatedAt?: string;
}): ActivationMarker {
  return {
    app: opts.app,
    sha: opts.sha ?? null,
    syncedRev: opts.syncedRev ?? null,
    surfaceHash: opts.surfaceHash,
    registry: opts.registry,
    activatedAt: opts.activatedAt ?? new Date().toISOString(),
  };
}
