# infra/github

**역할** — GitHub terraform 루트: CI Actions 시크릿(`secrets.tf`) + branch protection(`repo.tf`, required check `contexts=["gate"]`) 관리. App Platform 신뢰 앵커.

**적용 방식** — **owner 로컬 apply 전용 신뢰 앵커**. CI 무인 apply는 광범위 admin PAT를 CI에 저장해야 해 보안 모델 위반 → 금지. CI는 `tf-reconcile`에서 **plan-only 드리프트 알림**만(신규 `TF_GITHUB_*` 시크릿 있을 때만, 없으면 preflight skip).

**라이브 디버그** — terraform plan 로그(owner 로컬). App 인증 경계는 런북 `docs/runbooks/app-platform.md`.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": github/tailscale 루트=신뢰 앵커라 CI 무인 apply 금지(plan-only). required check는 `gate` 단일. fine-grained PAT 능력은 실제 push 테스트로만 확인(repo GET `permissions`는 역할만 표시). provider lock 첫 커밋은 라이브 state writer 버전 이상으로 핀.
