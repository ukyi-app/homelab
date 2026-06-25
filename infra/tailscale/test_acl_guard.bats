#!/usr/bin/env bats
# tailscale ACL F2 회귀 가드 — CNPG pg(5432)가 전 tailnet 멤버(autogroup:member)에 열리지 않게 강제.
# crown-jewel DB 직결은 owner(autogroup:admin)만. grep 기반(terraform 불요 → CI-safe, required gate).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐). 중간 단언은 [ ]만(bash 3.2).
setup() { ACL="${BATS_TEST_DIRNAME}/acl.tf"; }

@test "pg 5432 is exposed to the owner (autogroup:admin), not all members" {
  run grep -Eq 'tag:k8s:5432' "$ACL"; [ "$status" -eq 0 ]
  # 5432 규칙과 같은 줄에 autogroup:admin(src)이 있어야 한다(owner-only).
  run grep -Eq 'autogroup:admin.*tag:k8s:5432' "$ACL"; [ "$status" -eq 0 ]
}

@test "pg 5432 is never opened to autogroup:member (F2 over-exposure guard)" {
  # member rule(현재 80,443)에 5432가 섞이면 전 tailnet 노출 → 같은 줄에 member와 5432 공존 시 실패.
  run grep -E 'autogroup:member.*5432|5432.*autogroup:member' "$ACL"
  [ "$status" -ne 0 ]
}
