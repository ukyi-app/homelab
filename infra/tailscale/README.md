# infra/tailscale

**역할** — Tailscale terraform 루트: tailnet ACL(`acl.tf`) + operator OAuth/auth-key(`oauth.tf`) 관리. App Platform 신뢰 앵커.

**적용 방식** — **owner 로컬 apply 전용 신뢰 앵커**. CI 무인 apply는 광범위 OAuth를 CI에 저장해야 해 보안 모델 위반 → 금지. CI는 `tf-reconcile`에서 **plan-only 드리프트 알림**만(신규 `TF_TAILSCALE_*` 시크릿 있을 때만, 없으면 preflight skip).

**라이브 디버그** — terraform plan 로그(owner 로컬). operator 런타임은 `platform/tailscale`, DNS 연동은 런북 `docs/runbooks/lan-dns.md`.

**함정 SSOT** — docs/traps-detail.md: github/tailscale 루트=신뢰 앵커라 CI 무인 apply 금지(plan-only). provider lock 첫 커밋은 라이브 state writer 버전 이상으로 핀. (운영 측 함정: DR 재구축 시 traefik-ts tailscale IP 변동 → AdGuard rewrite stale.)
