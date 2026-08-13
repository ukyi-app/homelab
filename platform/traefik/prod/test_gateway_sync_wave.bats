#!/usr/bin/env bats
# Gateway API CRD ↔ 인스턴스 sync-wave 순서 가드 (2026-08-14 NUC 콜드스타트 교착에서 나온 것).
#
# ⚠️ CRD가 그 인스턴스보다 늦은 wave면 **자기 자신을 기다리는 교착**이 된다:
#    GatewayClass(-8)가 CRD(0)보다 먼저 apply → `resource mapping not found for kind
#    "GatewayClass" — ensure CRDs are installed first` → SyncFailed → ArgoCD가 그 wave에서
#    멈추므로 **뒤 wave의 CRD는 영원히 apply되지 않는다**.
# ⚠️ 라이브 Mac에서는 원리적으로 드러나지 않는다(CRD가 이미 등록돼 있다) — 콜드스타트 전용이다.
# ⚠️ CRD 번들은 upstream 재벤더링 대상이라 파일을 직접 고치지 않는다. kustomization의 patch가
#    wave를 붙이며, 이 @test가 그 patch를 고정한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/traefik/prod"; }

wave_of() { # $1=파일 — 첫 sync-wave 값(없으면 ArgoCD 기본값 0)
  # ⚠️ 접두 제거를 sed로 하지 말 것 — BSD/GNU가 `\?`를 다르게 다뤄 조용히 원문을 그대로 낸다.
  #    숫자(음수 포함)만 뽑는 grep이 두 플랫폼에서 동일하게 동작한다.
  w="$(LC_ALL=C grep -m1 -oE 'argocd\.argoproj\.io/sync-wave: *"?-?[0-9]+' "$1" 2>/dev/null \
       | LC_ALL=C grep -oE '\-?[0-9]+$')"
  [ -n "$w" ] || w=0
  printf '%s' "$w"
}

@test "the kustomization patches a sync-wave onto the vendored Gateway API CRDs" {
  # 번들 파일에는 annotation이 없다(upstream 그대로) — patch가 유일한 경로다.
  run grep -qE '^ *kind: CustomResourceDefinition' "$D/kustomization.yaml"
  [ "$status" -eq 0 ]
  run grep -qE 'argocd\.argoproj\.io~1sync-wave' "$D/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "CRDs are applied before the GatewayClass and Gateway that need them" {
  crd="$(LC_ALL=C grep -A6 'kind: CustomResourceDefinition' "$D/kustomization.yaml" \
         | LC_ALL=C grep -m1 -oE 'value: *"?-?[0-9]+' | LC_ALL=C grep -oE '\-?[0-9]+$')"
  [ -n "$crd" ]
  gc="$(wave_of "$D/gatewayclass.yaml")"
  gw="$(wave_of "$D/gateway.yaml")"
  [ "$crd" -lt "$gc" ] || { echo "CRD wave=$crd · GatewayClass wave=$gc — CRD가 더 앞이어야 한다"; false; }
  [ "$crd" -lt "$gw" ] || { echo "CRD wave=$crd · Gateway wave=$gw — CRD가 더 앞이어야 한다"; false; }
}

@test "the vendored CRD bundle itself stays unedited (no hand-added wave annotation)" {
  # 번들에 손으로 wave를 박으면 재벤더링(curl) 때 조용히 사라진다 — patch 경로를 강제한다.
  run grep -qE 'argocd\.argoproj\.io/sync-wave' "$D/gateway-api-crds.yaml"
  [ "$status" -ne 0 ]
}
