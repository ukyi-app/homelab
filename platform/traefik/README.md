# traefik

**역할** — Gateway-API 인그레스(Traefik HelmRelease) + Gateway-API CRDs + GatewayClass + Gateway + cert-manager Issuer. `web-internal-tls` 리스너가 `home.<도메인>` 내부 호스트 규약을 담당(tailscale passthrough→:8443). `gateway` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/traefik/prod`을 `traefik-prod` Application으로 자동 발견(appset 생성). 내부 wave 값의 SSOT는 `platform/argocd/root/SYNC-WAVES.md`의 「traefik 내부 wave」 표다(가드 `platform/traefik/prod/test_gateway_sync_wave.bats`) — 숫자를 여기 베끼지 않는다. 규칙은 **Gateway API 리소스(GatewayClass·Gateway)는 그것을 Healthy로 만들어 주는 컨트롤러보다 뒤**에 온다는 것이고, 앱 HTTPRoute(앱별 wave 2)는 이미 Programmed된 Gateway에 attach된다.

**라이브 디버그** — `argo` 스킬(sync/health, HTTPRoute parentRefs OutOfSync).

**함정 SSOT** — docs/traps-detail.md: Traefik 차트는 `serviceAccount.name` 지정 시 SA를 생성하지 않음, SSA + atomic 리스트(HTTPRoute `parentRefs`/`backendRefs`)는 서버 주입 기본값이 영구 OutOfSync → manifest에 기본값(group/kind/weight) 명시. gateway-api CRD는 벤더 파일이라 직접 수정 금지.
