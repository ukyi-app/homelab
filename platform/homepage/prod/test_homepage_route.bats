#!/usr/bin/env bats
# homepage HTTPRoute(dash.home.ukyi.app·web-internal-tls) 가드. @test 이름은 영어.
setup() { H="${BATS_TEST_DIRNAME}/httproute.yaml"; }

@test "route exposes dash on the internal listener" {
  run grep -q 'kind: HTTPRoute' "$H"; [ "$status" -eq 0 ]
  run grep -q 'dash.home.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-internal-tls' "$H"; [ "$status" -eq 0 ]
  # 리스너 집합 상한 — 위 grep은 존재만 잰다(원소 추가 축 무증인). 형제(adguard) 자리에서
  # 실측: web-public parentRef를 더해도 존재 grep이 전부 통과한다.
  run yq '[.spec.parentRefs[].sectionName] | sort | join(",")' "$H"
  [ "$output" = "web-internal-tls" ] || { echo "리스너=$output"; false; }
}

@test "backend targets the homepage service with explicit group/kind/weight" {
  run grep -q 'name: homepage' "$H"; [ "$status" -eq 0 ]
  run grep -q 'port: 3000' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'weight: 1' "$H"; [ "$status" -eq 0 ]
}
