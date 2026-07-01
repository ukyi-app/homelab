#!/usr/bin/env bats
# files HTTPRoute 2종 + 공개 표면 경계 가드. @test 이름은 영어.
I="$BATS_TEST_DIRNAME/httproute-internal.yaml"
P="$BATS_TEST_DIRNAME/httproute-public.yaml"

@test "internal route: web-internal-tls, files.home host, backend files-internal:8080" {
  run yq '.spec.parentRefs[0].sectionName' "$I"; [ "$output" = "web-internal-tls" ]
  run yq '.spec.hostnames[0]' "$I"; [ "$output" = "files.home.ukyi.app" ]
  run yq '.spec.rules[0].backendRefs[0].port' "$I"; [ "$output" = "8080" ]
}

@test "internal route parentRefs spell out group/kind (SSA atomic-list guard)" {
  run yq '.spec.parentRefs[0].group' "$I"; [ "$output" = "gateway.networking.k8s.io" ]
  run yq '.spec.parentRefs[0].kind' "$I"; [ "$output" = "Gateway" ]
}

@test "public route: web-public, files.ukyi.app host" {
  run yq '.spec.parentRefs[0].sectionName' "$P"; [ "$output" = "web-public" ]
  run yq '.spec.hostnames[0]' "$P"; [ "$output" = "files.ukyi.app" ]
}

@test "PUBLIC BOUNDARY: public route backend is files-public:8081, NEVER 8080" {
  run yq '.spec.rules[0].backendRefs[0].port' "$P"; [ "$output" = "8081" ]
  run yq '.spec.rules[0].backendRefs[0].name' "$P"; [ "$output" = "files-public" ]
}

@test "PUBLIC BOUNDARY: public route matches GET only (defense-in-depth)" {
  run yq '.spec.rules[0].matches[0].method' "$P"; [ "$output" = "GET" ]
}
