#!/usr/bin/env bats
# apps.json 레지스트리 — 데이터 기반 DNS/tunnel의 terraform 게이트(이 파일은 terraform 의존이라 .ci-exclude).
# ★구조 무결성(JSON 배열·host 유일성·예약어 충돌)은 terraform 비의존이라 test_apps_structure.bats로 분리해
#   required gate가 수집한다(advisory-only 우회 차단). 여기엔 terraform validate + .tf grep만 잔류.

setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "terraform validate passes with data-driven dns" {
  cd "$C" && run terraform validate
  [ "$status" -eq 0 ]
}

@test "dns.tf consumes apps.json via for_each" {
  run grep -E "for_each" "$C/dns.tf"
  [ "$status" -eq 0 ]
  run grep -E "apps.json" "$C/dns.tf"
  [ "$status" -eq 0 ]
}

@test "dns exposure is gated on public && active" {
  run grep -E 'a.public && a.active' "$C/dns.tf"
  [ "$status" -eq 0 ]
}

@test "tunnel ingress is deterministically ordered with 404 catch-all last" {
  # map 순회는 순서 비보장 — ingress는 리스트라 sort 없으면 영구 드리프트
  run grep -E "sort\(" "$C/tunnel.tf"
  [ "$status" -eq 0 ]
  run grep -E "http_status:404" "$C/tunnel.tf"
  [ "$status" -eq 0 ]
}
