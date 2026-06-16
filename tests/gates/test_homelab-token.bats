#!/usr/bin/env bats
# homelab-token composite action — GitHub App 설치 토큰 발급 (DEPLOY_BOT_PAT 대체)

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/homelab-token/action.yml"; }

@test "homelab-token action declares app-id and private-key inputs" {
  run grep -E "app-id:|private-key:" "$A"
  [ "$status" -eq 0 ]
}

@test "homelab-token pins create-github-app-token to a 40-char commit SHA (not a tag)" {
  # mutable @vN 태그는 이동/공급망 침해 시 private key를 변조된 action에 넘긴다 → full SHA만 immutable
  run grep -E "actions/create-github-app-token@[0-9a-f]{40}" "$A"
  [ "$status" -eq 0 ]
  run grep -E "actions/create-github-app-token@v[0-9]" "$A"
  [ "$status" -ne 0 ] # 태그 형태는 거부
}

@test "homelab-token exposes token as output" {
  run grep -E "token:.*steps\.app-token\.outputs\.token" "$A"
  [ "$status" -eq 0 ]
}

@test "homelab-token declares scope-narrowing inputs (owner/repositories/permissions)" {
  # App 권한은 App 수준 — 토큰을 owner/repositories/permission-*로 좁혀 최소 권한을 만든다
  run grep -E "owner:" "$A"
  [ "$status" -eq 0 ]
  run grep -E "repositories:" "$A"
  [ "$status" -eq 0 ]
  run grep -E "permission-contents:" "$A"
  [ "$status" -eq 0 ]
}
