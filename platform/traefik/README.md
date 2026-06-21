# traefik

**역할** — Gateway-API 인그레스(Traefik HelmRelease) + Gateway-API CRDs + GatewayClass + Gateway + cert-manager Issuer. `web-internal` 리스너가 `home.<도메인>` 내부 호스트 규약을 담당. `gateway` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/traefik/prod`을 `traefik-prod` Application으로 자동 발견(appset 생성). manifest의 Gateway-API CRDs/RBAC/GatewayClass/Gateway는 **sync-wave -8**(gateway 계층, 가장 먼저)로 핀 — 앱 HTTPRoute(앱별 wave 2)가 이미 Programmed된 Gateway에 attach된다.

**라이브 디버그** — `argo` 스킬(sync/health, HTTPRoute parentRefs OutOfSync).

**함정 SSOT** — docs/traps-detail.md: Traefik 차트는 `serviceAccount.name` 지정 시 SA를 생성하지 않음, SSA + atomic 리스트(HTTPRoute `parentRefs`/`backendRefs`)는 서버 주입 기본값이 영구 OutOfSync → manifest에 기본값(group/kind/weight) 명시. gateway-api CRD는 벤더 파일이라 직접 수정 금지.
