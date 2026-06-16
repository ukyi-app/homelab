# adguard

**역할** — LAN/tailnet DNS 서버(AdGuard Home). split-horizon rewrite(`*.home.ukyi.app`)와 광고 차단을 담당한다. `edge` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/adguard/prod`을 `adguard-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**(edge 계층, stateful 이후). 대상 NS `edge`는 `platform/namespaces`가 소유.

**라이브 디버그** — `argo` 스킬(sync/health), `observability` 스킬. 런북 `docs/runbooks/lan-dns.md`(split-horizon + 라우터 DNS).

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": (1) split-horizon rewrite는 DR 재구축 시 traefik-ts tailscale IP가 바뀌어 stale → seed + 라이브 PVC 둘 다 갱신, (2) ConfigMap은 첫 부팅 시드 전용(initContainer `cp -n`) — 갱신 시 PVC 안 `AdGuardHome.yaml`도 함께 수정+재시작, (3) setcap 바이너리라 `allowPrivilegeEscalation: false`와 양립 불가(baseline NS 강제).
