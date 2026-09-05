#!/usr/bin/env bats
# AdGuard UI 노출 가드: 인터널 도메인(adguard.home.ukyi.app) HTTPRoute로 web-internal-tls 리스너에 붙는다.
# 구 tailscale Ingress(.ts.net)는 제거됨 — break-glass는 kubectl port-forward(파드 up·DNS broken 시).
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글 인코딩 깨짐. 중간 단언은 [ ]/grep 단순 명령.)
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③

H="$BATS_TEST_DIRNAME/httproute.yaml"
K="$BATS_TEST_DIRNAME/kustomization.yaml"

@test "UI is exposed via HTTPRoute on the internal domain (web-internal-tls)" {
  run grep -q 'kind: HTTPRoute' "$H"; [ "$status" -eq 0 ]
  run grep -q 'adguard.home.ukyi.app' "$H"; [ "$status" -eq 0 ]
  run grep -q 'sectionName: web-internal-tls' "$H"; [ "$status" -eq 0 ]
  # 백엔드는 adguard-ui Service:80(→3000)
  run grep -q 'name: adguard-ui' "$H"; [ "$status" -eq 0 ]
  # parentRefs/backendRefs에 group/kind/weight 명시 — SSA atomic-list OutOfSync 함정 회피
  run grep -q 'kind: Gateway' "$H"; [ "$status" -eq 0 ]
  run grep -qE 'weight: 1' "$H"; [ "$status" -eq 0 ]
  # 리스너 집합 상한 — 위 grep들은 존재만 잰다(원소 추가 축 무증인). web-public parentRef를
  # 더해도 존재 grep 6줄이 전부 통과했다(2026-09-03 실측). 경로는 이미 `/` 전면이라 상한이
  # 무의미해 리스너 축만 닫는다.
  run yq '[.spec.parentRefs[].sectionName] | sort | join(",")' "$H"
  [ "$output" = "web-internal-tls" ] || { echo "리스너=$output"; false; }
  # ⚠️ 백엔드/매치 집합 상한 — 위는 rules[0]만 본다. 두 번째 rule로 `/api` PathPrefix →
  #    다른 Service backendRef를 더해도 위 grep·리스너 등호가 전부 통과했다(2026-09-04 실측:
  #    격리 사본에 그 rule을 추가해도 2/2 ok). 내부 라우트라 위협은 공개 노출이 아니라
  #    **백엔드 바꿔치기·경로 우회**다(처방 형제: platform/files/prod/test_files_route.bats,
  #    착지형 46c799c). `(.matches // [{}])`가 load-bearing — matches 없는 rule은 Gateway API
  #    기본값 PathPrefix `/` + 전 method로 집합에 들어간다.
  run yq '[.spec.rules[].backendRefs[] | .name + ":" + (.port|tostring)] | sort | join(",")' "$H"
  [ "$output" = "adguard-ui:80" ] || { echo "백엔드 집합=$output"; false; }
  run yq '[.spec.rules[] | (.matches // [{}])[] | (.path.value // "/") + "|" + (.method // "ANY")] | sort | join(",")' "$H"
  [ "$output" = "/|ANY" ] || { echo "매치 집합=$output"; false; }
}

@test "legacy tailscale Ingress is removed (kustomization no longer references it)" {
  run grep -q 'ts-ingress' "$K"; [ "$status" -eq 1 ]
  run grep -q 'httproute.yaml' "$K"; [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_DIRNAME/ts-ingress.yaml" ]
}
