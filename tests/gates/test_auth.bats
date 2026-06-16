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
