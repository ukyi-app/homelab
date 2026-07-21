#!/usr/bin/env bats
# F-0: bump-poll/** ref 네임스페이스를 writer App 전용으로 예약하는 ruleset의 강제 불변식이
# 무인 편집으로 약화되지 못하게 잠근다(구조 회귀 가드 — 라이브 API 미호출, 파일 구조만).
#  - 타깃 = refs/heads/bump-poll/** (전 브랜치로 넓어지지 않음).
#  - creation·update 둘 다 restrict(true).
#  - bypass = writer App 하나 — github_app data source로 배선(하드코딩 아님) + actor_type=Integration + bypass_mode=always.
#  - enforcement=active (disabled/evaluate 강등 아님).
#  - 광범위 역할(RepositoryRole/OrganizationAdmin) bypass 미추가.
# deletion은 이번 increment 범위 밖이라 단언하지 않는다(후속이 정리경로와 함께 추가).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — AGENTS.md).

TF="$BATS_TEST_DIRNAME/../../infra/github/rulesets.tf"

@test "bump-poll ruleset resource exists" {
  run grep -E 'resource[[:space:]]+"github_repository_ruleset"' "$TF"
  [ "$status" -eq 0 ]
}

@test "ruleset targets the refs/heads/bump-poll/** namespace" {
  run grep -F 'refs/heads/bump-poll/**' "$TF"
  [ "$status" -eq 0 ]
}

@test "ref pattern is not broadened to all branches" {
  # 전 브랜치를 삼키는 형태(refs/heads/** 단독 · ~ALL)로 변형 금지.
  run grep -F '"refs/heads/**"' "$TF"
  [ "$status" -ne 0 ]
  run grep -F '"~ALL"' "$TF"
  [ "$status" -ne 0 ]
}

@test "creation rule is restricted (true)" {
  run grep -E 'creation[[:space:]]*=[[:space:]]*true' "$TF"
  [ "$status" -eq 0 ]
}

@test "update rule is restricted (true)" {
  run grep -E 'update[[:space:]]*=[[:space:]]*true' "$TF"
  [ "$status" -eq 0 ]
}

@test "enforcement is active" {
  run grep -E 'enforcement[[:space:]]*=[[:space:]]*"active"' "$TF"
  [ "$status" -eq 0 ]
}

@test "enforcement is never demoted to disabled or evaluate" {
  run grep -E 'enforcement[[:space:]]*=[[:space:]]*"(disabled|evaluate)"' "$TF"
  [ "$status" -ne 0 ]
}

@test "bypass actor is the writer App wired via github_app data source (not hardcoded)" {
  run grep -E 'data[[:space:]]+"github_app"' "$TF"
  [ "$status" -eq 0 ]
  run grep -E 'actor_id[[:space:]]*=.*data\.github_app' "$TF"
  [ "$status" -eq 0 ]
}

@test "bypass actor type is Integration" {
  run grep -E 'actor_type[[:space:]]*=[[:space:]]*"Integration"' "$TF"
  [ "$status" -eq 0 ]
}

@test "bypass mode is always (not weakened to pull_request)" {
  run grep -E 'bypass_mode[[:space:]]*=[[:space:]]*"always"' "$TF"
  [ "$status" -eq 0 ]
}

@test "no broad-role bypass (RepositoryRole / OrganizationAdmin) is added" {
  run grep -E 'actor_type[[:space:]]*=[[:space:]]*"(RepositoryRole|OrganizationAdmin)"' "$TF"
  [ "$status" -ne 0 ]
}
