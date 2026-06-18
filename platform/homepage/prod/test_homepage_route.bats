#!/usr/bin/env bats
# homepage HTTPRoute(dash.home.ukyi.app·web-internal-tls) 가드. @test 이름은 영어.
setup() { H="${BATS_TEST_DIRNAME}/httproute.yaml"; }

@test "route exposes dash on the internal listener" {
  run grep -q 'kind: HTTPRoute' "$H"; [ "$status" -eq 0 ]
  run grep -q 'dash.home.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-internal-tls' "$H"; [ "$status" -eq 0 ]
}

@test "backend targets the homepage service with explicit group/kind/weight" {
  run grep -q 'name: homepage' "$H"; [ "$status" -eq 0 ]
  run grep -q 'port: 3000' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'weight: 1' "$H"; [ "$status" -eq 0 ]
}
