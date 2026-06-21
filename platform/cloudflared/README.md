# cloudflared

**역할** — Cloudflare Tunnel 커넥터(외부 인그레스). 퍼블릭 트래픽을 터널로 받아 내부 Gateway/Service로 보낸다. 터널 자격은 SealedSecret/KSOPS(`tunnel.enc.yaml`). `edge` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/cloudflared/prod`을 `cloudflared-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**(edge 계층). 대상 NS `edge`는 `platform/namespaces`가 소유.

**라이브 디버그** — `argo` 스킬(sync/health). 터널/DNS 자체는 `infra/cloudflare`(terraform)와 연동.

**함정 SSOT** — docs/traps-detail.md: `*.enc.yaml` 직접 수정 금지(평문 메타데이터도 SOPS MAC 포함, 복호화→편집→재암호화만), `envFrom` 시크릿 변경은 파드 재시작이 있어야 반영.
