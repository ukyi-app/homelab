#!/usr/bin/env bats
# apps.json 레지스트리 — 데이터 기반 DNS/tunnel의 SSOT 게이트

setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "apps.json is valid JSON and is an array" {
  run jq -e 'type == "array"' "$C/apps.json"
  [ "$status" -eq 0 ]
}

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

@test "tunnel ingress is deterministically ordered with 404 catch-all last" {
  # map 순회는 순서 비보장 — ingress는 리스트라 sort 없으면 영구 드리프트
  run grep -E "sort\(" "$C/tunnel.tf"
  [ "$status" -eq 0 ]
  run grep -E "http_status:404" "$C/tunnel.tf"
  [ "$status" -eq 0 ]
}

@test "apps.json has globally unique app names and hosts (no silent collision)" {
  # 중복 host는 toset에서 조용히 사라지지만 Gateway엔 같은 hostname HTTPRoute 2개 → 오라우팅
  run jq -e '(.|length) == ([.[].name]|unique|length) and (.|length) == ([.[].host]|unique|length)' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved names (apex/www/home suffix)" {
  run jq -e 'all(.[]; (.host != "ukyi.app") and (.host != "www.ukyi.app") and ((.host | endswith(".home.ukyi.app")) | not))' "$C/apps.json"
  [ "$status" -eq 0 ]
}
