# tailscale

**역할** — Tailscale Kubernetes operator(HelmRelease). tailnet 인그레스를 제공하고 `traefik-ts` Ingress로 Gateway를 tailnet에 노출한다. OAuth 자격은 SealedSecret/KSOPS(`operator-oauth.enc.yaml`). `edge` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/tailscale/prod`을 `tailscale-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**(edge 계층). 대상 NS `edge`는 `platform/namespaces`가 소유.

**라이브 디버그** — `argo` 스킬(sync/health). split-horizon rewrite 연동은 런북 `docs/runbooks/lan-dns.md`. ACL/auth-key는 `infra/tailscale`(terraform).

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": tailscale operator의 Ingress reconcile은 metadata-only 변경(annotation nudge)을 무시 → 재처리는 operator 재시작. DR 재구축 시 `traefik-ts` tailscale IP가 바뀌면 AdGuard rewrite가 stale(adguard 참고).
