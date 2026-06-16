# 0002 — terraform github/tailscale 루트는 owner 로컬 apply 전용

- 상태: 수용(accepted)
- 관련: `AGENTS.md`(tf 루트 관리 모델), `.github/workflows/tf-reconcile.yml`, `infra/_test/test_tf_reconcile.bats`

## 맥락
terraform 3 루트가 있다 — cloudflare(DNS/tunnel), github(Actions 시크릿·branch protection),
tailscale(ACL·auth-key). cloudflare는 `iac.yaml`이 push apply + `tf-reconcile`가 드리프트
수렴한다(좁은 스코프라 안전). github/tailscale도 CI 무인 apply로 통일하자는 제안이 있었다.

## 결정
github/tailscale 루트는 **owner 로컬 apply 전용**으로 둔다. CI는 이 둘에 대해
tf-reconcile에서 **plan-only 드리프트 알림**만 한다(무인 apply 금지).

## 근거
- github 루트는 CI Actions 시크릿(`secrets.tf`)과 branch protection(`repo.tf` `contexts=[gate]`)을,
  tailscale 루트는 ACL/auth-key를 관리한다 — 이 둘은 **CI 자신의 신뢰 앵커**다.
- CI 무인 apply는 광범위 admin PAT/OAuth를 CI 시크릿에 저장해야 한다. 그러면 CI 침해 시
  공격자가 branch protection을 끄고 자기 시크릿을 심을 수 있다 — 신뢰 앵커가 자신을 보호 못 한다.
- cloudflare는 DNS/tunnel만이라 스코프가 좁아 CI apply가 허용된다(앵커 아님).

## 기각된 대안
- **전 루트 CI apply**: 신뢰 앵커를 CI에 위임 → 보안 모델 붕괴.
- **plan도 안 함**: 드리프트가 조용히 쌓여 DR 시 재현 불가.

## 결과
- 신규 `TF_GITHUB_*`/`TF_TAILSCALE_*` 시크릿이 있을 때만 plan-only preflight가 돈다(없으면 skip).
- 무료 플랜 rate-limit entitlement(period·mitigation 둘 다 10초 고정 등)는 plan 통과해도
  apply에서만 400으로 드러난다 — owner가 로컬 apply로 확인한다.
