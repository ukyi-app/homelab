#!/usr/bin/env bats
# apps.json 구조 무결성(jq-only, terraform 비의존) — required gate가 수집(run-bats, .ci-exclude 미등재).
# 적대 리뷰: 이 검증이 advisory iac-validate(if: pull_request, 비-required)에만 있어 required gate를 우회했고,
# dns.tf의 toset()이 중복 host를 조용히 dedupe해 push-apply의 terraform plan도 통과시킨다 → host 충돌/예약어
# 탈취가 무인 적용될 수 있었다. terraform 의존 검사(validate·dns.tf grep)는 test_apps_data.bats에 잔류(excluded).
# @test 이름은 영어(CJK 인코딩 함정).

setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "apps.json is valid JSON and is an array" {
  run jq -e 'type == "array"' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json has globally unique app names and hosts (no silent collision)" {
  # 중복 host는 toset에서 조용히 사라지지만 Gateway엔 같은 hostname HTTPRoute 2개 → 오라우팅.
  run jq -e '(.|length) == ([.[].name]|unique|length) and (.|length) == ([.[].host]|unique|length)' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved names (apex/www/home suffix)" {
  run jq -e 'all(.[]; (.host != "ukyi.app") and (.host != "www.ukyi.app") and ((.host | endswith(".home.ukyi.app")) | not))' "$C/apps.json"
  [ "$status" -eq 0 ]
}
