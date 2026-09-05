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
  # ⚠️ 백엔드/매치 집합 상한 — 위 grep은 rules[0]만 본다. 두 번째 rule로 `/api` PathPrefix →
  #    다른 Service backendRef를 더해도 위 grep 3줄이 전부 통과했다(2026-09-04 실측: 격리
  #    사본에 그 rule을 추가해도 2/2 ok). 내부 라우트라 위협은 공개 노출이 아니라 **백엔드
  #    바꿔치기·경로 우회**다(처방 형제: platform/files/prod/test_files_route.bats, 착지형
  #    46c799c). `(.matches // [{}])`가 load-bearing — matches 없는 rule은 Gateway API
  #    기본값 PathPrefix `/` + 전 method로 집합에 들어간다.
  run yq '[.spec.rules[].backendRefs[] | .name + ":" + (.port|tostring)] | sort | join(",")' "$H"
  [ "$output" = "homepage:3000" ] || { echo "백엔드 집합=$output"; false; }
  run yq '[.spec.rules[] | (.matches // [{}])[] | (.path.value // "/") + "|" + (.method // "ANY")] | sort | join(",")' "$H"
  [ "$output" = "/|ANY" ] || { echo "매치 집합=$output"; false; }
}
