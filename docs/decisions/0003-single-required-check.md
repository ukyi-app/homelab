# 0003 — required status check는 `gate` 단일

- 상태: 수용(accepted)
- 관련: `infra/github/repo.tf`(`contexts=["gate"]`), `.github/workflows/ci.yaml`(job `gate`), `tools/test/test_make-ci-parity.bats`

## 맥락
여러 워크플로가 PR에서 돈다 — `ci`(job `gate`), `verify`, `iac`(plan/validate). branch protection의
required status check를 무엇으로 둘지 결정해야 했다(여러 개 vs 단일).

## 결정
branch protection의 required status check는 **`gate` 하나**로 둔다(`repo.tf`의 `contexts=["gate"]`).
다른 잡(verify·iac)은 신호로 두되 머지를 막지 않는다.

## 근거
- `gate`가 머지를 막아야 하는 8스텝(chart-test·ledger·audit·bats·shellcheck·telegram-e2e)을
  결정론적으로 한 잡에 모은다. 단일 required는 "머지해도 되나?"를 한 줄로 답하게 한다.
- verify(sops/pre-commit)·iac(plan)은 보조 신호다 — 실패해도 머지 차단까지 갈 필요는 없다
  (sops 왕복은 ephemeral 키, iac plan은 정보성).

## 결과
- **`gate`가 유일 머지 게이트이므로 gate를 깨는 변경은 전면 차단된다.** 그래서 gate가 쓰는
  도구는 전부 핀해야 한다 — helm 무핀(`get-helm-3` latest)이 시한폭탄이었던 이유(→ 핀 완료).
- 로컬에서 gate를 그대로 재현하는 단일 진입점이 필요하다 → `make ci`(+ `test_make-ci-parity.bats`가
  gate↔make ci 드리프트를 회귀 차단).
- 새 회귀 가드는 gate가 수집하는 글롭(tools/test·tests·platform `test_*.bats`) 안에 둬야
  required로 동작한다.
