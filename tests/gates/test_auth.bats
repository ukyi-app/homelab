#!/usr/bin/env bats
# 인증 마이그레이션 게이트 — PAT 0건 + App 토큰 경로 강제

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; WF="$ROOT/.github/workflows"; }

@test "no workflow references DEPLOY_BOT_PAT" {
  run grep -rn "DEPLOY_BOT_PAT" "$WF"
  [ "$status" -ne 0 ] # grep returns 1 when nothing matches
}

@test "bump.yaml mints an app token before checkout" {
  # 첫 checkout 전에 create-github-app-token 인라인 step이 있어야 한다 (composite는 체크아웃 필요 — 순서 딜레마)
  run grep -E "uses: actions/create-github-app-token@[0-9a-f]{40}" "$WF/bump.yaml"
  [ "$status" -eq 0 ]
}

@test "all create-github-app-token uses are pinned to a 40-char SHA (no mutable tags)" {
  run bash -c "grep -rE 'create-github-app-token@' '$ROOT/.github/' | grep -vE 'create-github-app-token@[0-9a-f]{40}'"
  [ "$status" -ne 0 ] # SHA 아닌 참조(태그 등)는 0건이어야 한다
}

@test "bump.yaml does not push directly to main (PR-first write model)" {
  # App 토큰은 branch protection을 우회하지 못한다 — main 쓰기는 PR + auto-merge로만
  run grep -E "git push origin main" "$WF/bump.yaml"
  [ "$status" -ne 0 ]
  run grep -E "pr merge --auto" "$WF/bump.yaml"
  [ "$status" -eq 0 ]
}

@test "no github_actions_secret bot_pat resource remains in terraform" {
  # App 마이그레이션 후 DEPLOY_BOT_PAT(write-capable standing PAT)는 소비자 0 — 리소스가 남으면 안 됨
  run grep -nE 'github_actions_secret"?[[:space:]]*"bot_pat"' "$ROOT/infra/github/secrets.tf"
  [ "$status" -ne 0 ]
}

@test "no variable bot_pat declared in terraform" {
  run grep -nE '^variable[[:space:]]+"bot_pat"' "$ROOT/infra/github/variables.tf"
  [ "$status" -ne 0 ]
}

@test "DEPLOY_BOT_PAT secret_name is gone from terraform" {
  # secret_name 문자열까지 사라져야 라이브 destroy가 next apply에서 발생한다
  run grep -rn 'DEPLOY_BOT_PAT' "$ROOT/infra/github/"
  [ "$status" -ne 0 ]
}

@test "tf-reconcile drift-github no longer injects TF_VAR_bot_pat" {
  # 변수 제거 후 dead 주입(오해 유발) 차단 — TF_GITHUB_TOKEN/OWNER 등 나머지 plan-only 시크릿은 보존
  run grep -nE 'TF_VAR_bot_pat' "$ROOT/.github/workflows/tf-reconcile.yaml"
  [ "$status" -ne 0 ]
}
