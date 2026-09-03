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
}

@test "legacy tailscale Ingress is removed (kustomization no longer references it)" {
  run grep -q 'ts-ingress' "$K"; [ "$status" -eq 1 ]
  run grep -q 'httproute.yaml' "$K"; [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_DIRNAME/ts-ingress.yaml" ]
}
