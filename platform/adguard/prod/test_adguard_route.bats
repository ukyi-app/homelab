#!/usr/bin/env bats
# AdGuard UI 노출 가드: 인터널 도메인(adguard.home.ukyi.app) HTTPRoute로 web-internal-tls 리스너에 붙는다.
# 구 tailscale Ingress(.ts.net)는 제거됨 — break-glass는 kubectl port-forward(파드 up·DNS broken 시).
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글 인코딩 깨짐. 중간 단언은 [ ]/grep 단순 명령.)

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
}

@test "legacy tailscale Ingress is removed (kustomization no longer references it)" {
  run grep -q 'ts-ingress' "$K"; [ "$status" -ne 0 ]
  run grep -q 'httproute.yaml' "$K"; [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_DIRNAME/ts-ingress.yaml" ]
}
