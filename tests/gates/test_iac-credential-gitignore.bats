#!/usr/bin/env bats
# IaC 자격 파일의 **접미사 사본**이 .gitignore를 빠져나가지 못하게 잠근다.
#
# 이 레포는 같은 사고를 두 번 겪었다:
#  · 2026-08-17 — `terraform.tfvars.pre-cutover.bak`이 `*.tfvars`에 안 걸려 untracked로 남았다.
#    `*.tfvars.*`로 고쳤지만 **가드는 안 붙였다.**
#  · 2026-08-19 — 맥 폐기 절차에서 apply 경로를 닫으려고 `backend.hcl` 3개를
#    `.MOVED-TO-NUC-20260819`로 rename했더니 `git add -A`가 **전부 스테이징했다**(`backend.hcl`
#    한 줄만 있었기 때문). 이 파일들엔 R2 state의 access_key/secret_key가 평문으로 들어 있고
#    **레포는 public이다.** 커밋 직전에 잡았다.
# ⇒ 두 번째가 첫 번째의 반복이라는 것이 요점이다. 패턴만 고치고 가드를 안 달면 다음 파일에서 또 난다.
#
# ⚠️ `.example`은 **추적돼야 한다** — 부트스트랩 템플릿이라 무시하면 신규 구축이 막힌다.
#    그래서 "전부 무시"가 아니라 "사본은 무시, 예시는 추적"이 계약이다.
# 🔴 `--no-index`가 **필수다.** `git check-ignore`는 기본적으로 **추적 중인 파일을 건너뛴다**
#    ("tracked files are not subject to exclude rules"). 그래서 `.example`에 대해 그냥 부르면
#    negation 규칙을 지워도 "무시 안 됨"이 나와 이 가드가 **공허하게 통과한다** — 초판이 실제로
#    그랬고 뮤테이션(`!*.tfvars.example` 삭제)이 물지 않아 발각됐다(2026-08-19).
#    `--no-index`는 인덱스를 무시하고 **규칙만** 평가한다 — 우리가 검증하려는 것이 그 규칙이다.
# @test 이름은 영어. 중간 부정 단언은 run + [ ]로만(bash 3.2에서 중간 `!`는 조용히 통과한다).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "the .example templates are actually tracked (floor — otherwise the negative assertions below are vacuous)" {
  # 🔴 예시 파일이 사라지면 아래 "예시는 무시되면 안 된다" 단언이 공허해진다.
  n="$(git ls-files | grep -cE '(backend\.hcl|tfvars)\.example$')"
  [ "$n" -ge 2 ]
}

@test "suffixed backend.hcl copies are ignored (they carry R2 state credentials in plaintext)" {
  for f in infra/github/backend.hcl \
           infra/github/backend.hcl.bak \
           infra/github/backend.hcl.MOVED-TO-NUC-20260819 \
           infra/cloudflare/backend.hcl.2026 \
           infra/tailscale/backend.hcl.old; do
    run git check-ignore --no-index -q "$f"
    [ "$status" -eq 0 ]
  done
}

@test "suffixed terraform.tfvars copies are ignored (2026-08-17 lesson, never locked until now)" {
  for f in infra/github/terraform.tfvars \
           infra/tailscale/terraform.tfvars.pre-cutover.bak \
           infra/cloudflare/terraform.tfvars.bak; do
    run git check-ignore --no-index -q "$f"
    [ "$status" -eq 0 ]
  done
}

@test "the .example templates are NOT ignored (bootstrap would break)" {
  run git check-ignore --no-index -q infra/_backend/backend.hcl.example
  [ "$status" -ne 0 ]
  run git check-ignore --no-index -q infra/github/terraform.tfvars.example
  [ "$status" -ne 0 ]
}

@test "no real credential file is tracked right now (the invariant itself, not just the pattern)" {
  # 패턴이 맞아도 과거에 강제 추가된 파일은 계속 추적된다 — 상태 자체를 본다.
  run bash -c "git ls-files | grep -E '(^|/)(backend\.hcl|terraform\.tfvars)(\..*)?$' | grep -v '\.example$' | grep -q ."
  [ "$status" -ne 0 ]
}
