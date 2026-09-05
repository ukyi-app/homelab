#!/usr/bin/env bats
# 인증 마이그레이션 게이트 — PAT 0건 + App 토큰 경로 강제
# ⚠️ 부재 단언은 `-eq 1`이다 — grep은 대상 부재/읽기불가에 rc 2를 내는데 `-ne 0`은 그것을 무매치와
#    구별하지 않아 대상이 리네임/삭제돼도 조용히 통과한다. 디렉토리 피연산자는 `-eq 1`로도 안
#    닫히므로 setup의 실재 단언 + 각 @test의 양성 대조(같은 피연산자 — 트리가 비면 그쪽이 먼저
#    red다)가 한 쌍으로 닫는다. 아무도 대조하지 않는 손 관리 건수 바닥값은 두지 않는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"
  [ -d "$WF" ]
  [ -d "$ROOT/infra/github" ]
}

@test "no workflow references DEPLOY_BOT_PAT" {
  # 양성 대조 — 열거 대상이 실제 워크플로 트리인지(`on:` 키는 이 디렉토리에서 사라질 리 없다)
  run grep -rlE '^on:' "$WF"
  [ "$status" -eq 0 ]
  # rc 2(대상 부재)를 통과로 읽지 않는다 — 위 양성 대조가 같은 트리의 비공허성을 증언한다
  run grep -rn "DEPLOY_BOT_PAT" "$WF"
  [ "$status" -eq 1 ] # grep returns 1 when nothing matches
}

@test "bump.yaml mints an app token before checkout" {
  # 첫 checkout 전에 create-github-app-token 인라인 step이 있어야 한다 (composite는 체크아웃 필요 — 순서 딜레마)
  run grep -E "uses: actions/create-github-app-token@[0-9a-f]{40}" "$WF/bump.yaml"
  [ "$status" -eq 0 ]
}

@test "bump.yaml does not push directly to main (PR-first write model)" {
  # App 토큰은 branch protection을 우회하지 못한다 — main 쓰기는 PR + auto-merge로만.
  # Phase 6 races-6으로 raw `pr merge --auto`가 공유 스크립트(auto-merge-or-fail.sh)로 수렴 — 둘 중 하나면 PR-first.
  # rc 2(파일 부재)를 통과로 읽지 않는다 — 아래 양성 단언이 같은 파일의 실재를 함께 증언한다
  run grep -E "git push origin main" "$WF/bump.yaml"
  [ "$status" -eq 1 ]
  run grep -E "pr merge --auto|auto-merge-or-fail" "$WF/bump.yaml"
  [ "$status" -eq 0 ]
}

@test "bump.yaml writeback only reacts to this repo's main (blocks fork/PR builds)" {
  # wf-ci-build-bump-1: write-back(bump.yaml)의 유일한 신뢰 경계인 head_repository.full_name 비교는
  # 어느 가드에도 증인이 없었다(전 레포에서 'head_repository' 리터럴이 이 파일 하나뿐 — grep 0건 확인).
  # 오늘은 build.yaml 트리거(push main-only + workflow_dispatch actor 가드)가 이 조건을 항상 참으로
  # 만들지만, 향후 build.yaml에 pull_request 트리거가 생기거나 동명(📦 build) 워크플로가 생기면
  # 이 조건이 유일한 방어선이 된다 — 회귀 방지용 defense-in-depth 커버리지.
  run bash -c "yq -r '.jobs.writeback.if' '$WF/bump.yaml'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'head_repository.full_name == github.repository'
  printf '%s' "$output" | grep -qF "head_branch == 'main'"
}

@test "no github_actions_secret bot_pat resource remains in terraform" {
  # App 마이그레이션 후 DEPLOY_BOT_PAT(write-capable standing PAT)는 소비자 0 — 리소스가 남으면 안 됨
  # 양성 대조 — secrets.tf가 실재하고 여전히 시크릿 리소스를 선언하는 파일인지
  run grep -nE '^resource[[:space:]]+"github_actions_secret"' "$ROOT/infra/github/secrets.tf"
  [ "$status" -eq 0 ]
  # rc 2(파일 부재/리네임)를 통과로 읽지 않는다
  run grep -nE 'github_actions_secret"?[[:space:]]*"bot_pat"' "$ROOT/infra/github/secrets.tf"
  [ "$status" -eq 1 ]
}

@test "no variable bot_pat declared in terraform" {
  # 양성 대조 — variables.tf가 실재하고 여전히 variable 선언 파일인지(리네임 시 red)
  run grep -nE '^variable[[:space:]]+"' "$ROOT/infra/github/variables.tf"
  [ "$status" -eq 0 ]
  run grep -nE '^variable[[:space:]]+"bot_pat"' "$ROOT/infra/github/variables.tf"
  [ "$status" -eq 1 ]
}

@test "DEPLOY_BOT_PAT secret_name is gone from terraform" {
  # secret_name 문자열까지 사라져야 라이브 destroy가 next apply에서 발생한다
  # 양성 대조 — 열거 대상이 실제 terraform 루트인지(resource/variable 선언은 사라질 리 없다)
  run grep -rlE '^(resource|variable)[[:space:]]+"' "$ROOT/infra/github/"
  [ "$status" -eq 0 ]
  run grep -rn 'DEPLOY_BOT_PAT' "$ROOT/infra/github/"
  [ "$status" -eq 1 ]
}

@test "tf-reconcile drift-github no longer injects TF_VAR_bot_pat" {
  # 변수 제거 후 dead 주입(오해 유발) 차단 — TF_GITHUB_TOKEN/OWNER 등 나머지 plan-only 시크릿은 보존
  # 양성 대조 — 그 워크플로가 실재하고 여전히 TF_VAR_* 주입을 하는 파일인지
  run grep -nE 'TF_VAR_|TF_GITHUB_TOKEN' "$ROOT/.github/workflows/tf-reconcile.yaml"
  [ "$status" -eq 0 ]
  run grep -nE 'TF_VAR_bot_pat' "$ROOT/.github/workflows/tf-reconcile.yaml"
  [ "$status" -eq 1 ]
}
