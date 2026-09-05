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
  # ⚠️ 리스너 집합 상한 — parentRefs[0]만 보면 web-public parentRef를 하나 더 붙여도(내부 표면이
  #    Cloudflare 터널로 나가도) 무증인이었다(뮤테이션 C 실측: 33 ok/0 not ok).
  run yq '[.spec.parentRefs[].sectionName] | sort | join(",")' "$I"
  [ "$output" = "web-internal-tls" ] || { echo "내부 리스너 집합=$output"; false; }
}

@test "public route: web-public, files.ukyi.app host" {
  run yq '.spec.parentRefs[0].sectionName' "$P"; [ "$output" = "web-public" ]
  run yq '.spec.hostnames[0]' "$P"; [ "$output" = "files.ukyi.app" ]
}

@test "PUBLIC BOUNDARY: public route backend is files-public:8081, NEVER 8080" {
  run yq '.spec.rules[0].backendRefs[0].port' "$P"; [ "$output" = "8081" ]
  run yq '.spec.rules[0].backendRefs[0].name' "$P"; [ "$output" = "files-public" ]
  # ⚠️ 백엔드 집합 상한 — rules[0].backendRefs[0]만 보면 두 번째 rule로 files-internal:8080을
  #    붙여도(write/admin API 인터넷 노출) 무증인이었다(뮤테이션 A 실측: 33 ok/0 not ok).
  run yq '[.spec.rules[].backendRefs[] | .name + ":" + (.port|tostring)] | sort | join(",")' "$P"
  [ "$output" = "files-public:8081" ] || { echo "공개 백엔드 집합=$output"; false; }
  # ⚠️ filters 축 상한(감사 6라운드 httproute-1 형제, argocd/extras/test_argocd_extras.bats:a759d33
  #    형태) — 경로/백엔드 집합은 URLRewrite(ReplacePrefixMatch /)를 못 잡는다(매치 경로는 그대로다).
  #    rule-level과 backendRef-level 둘 다 센다.
  run yq '[.spec.rules[] | ((.filters // [{"type":"NONE"}])[] , (.backendRefs[]? | (.filters // [])[])) | .type] | sort | join(",")' "$P"
  [ "$output" = "NONE" ] || { echo "공개 filters 집합=$output"; false; }
}

@test "PUBLIC BOUNDARY: public route matches GET only (defense-in-depth)" {
  run yq '.spec.rules[0].matches[0].method' "$P"; [ "$output" = "GET" ]
  # ⚠️ 매치 집합 상한 — rules[0].matches[0]만 보면 matches 없는 rule(Gateway API 기본 PathPrefix `/`
  #    + 전 method)이나 method 없는 match를 더해도 무증인이었다(뮤테이션 B·exact-platform-1 ①③ 실측:
  #    5/5 ok). `(.matches // [{}])`가 load-bearing — matches 없는 rule을 값으로 바꿔야 red가 된다.
  run yq '[.spec.rules[] | (.matches // [{}])[] | (.path.value // "/") + "|" + (.method // "ANY")] | sort | join(",")' "$P"
  [ "$output" = "/|GET" ] || { echo "공개 매치 집합=$output"; false; }
}
