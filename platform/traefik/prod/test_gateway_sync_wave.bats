#!/usr/bin/env bats
# Gateway API 콜드스타트 sync-wave 순서 가드 (2026-08-14 NUC 콜드스타트 교착 2건에서 나온 것).
#
# ArgoCD는 **wave N의 전 리소스가 Healthy가 될 때까지 wave N+1로 넘어가지 않는다.** 그래서
# "health가 늦은 wave의 무언가를 기다리는 리소스"를 앞 wave에 두면 **자기 자신을 기다리는 교착**이 된다.
# 이 컴포넌트가 실제로 밟은 두 고리:
#   1. CRD(wave 0) < GatewayClass/Gateway(wave -8) → resource mapping not found ... ensure CRDs
#      are installed first → SyncFailed (`#462`가 CRD를 -9로 올려 해소)
#   2. Gateway(wave -8)의 health가 traefik 컨트롤러(Helm 차트 Deployment, wave 0)와
#      home-wildcard-tls Secret(Certificate 발급물, wave 0)을 기다림 →
#      17시간 waiting for healthy state of gateway.networking.k8s.io/Gateway/homelab
# ⚠️ 라이브 Mac에서는 원리적으로 드러나지 않는다(전부 이미 존재) — 콜드스타트 전용 결함이다.
# ⚠️ CRD 번들은 upstream 재벤더링 대상이라 파일을 직접 고치지 않는다. kustomization의 patch가
#    wave를 붙이며, 이 @test가 그 patch를 고정한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 진단 메시지에 백틱을 쓰지 말 것 — 음성 @test가 $output을 재해석하는 관용구가 레포에 있다.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
#    `run sh -c` 파이프라인 자리는 비대상이다 — rc가 sh의 것이고 판정도 $output으로 한다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/traefik/prod"; }

wave_of_kind() { # $1=파일 $2=최상위 kind — 그 문서의 sync-wave(annotation 부재 = ArgoCD 기본값 0)
  # ⚠️ 파일 단위 grep -m1 로 읽지 말 것 — 한 파일에 문서가 여럿이면 남의 값을 집는다.
  #    그리고 annotations가 kind: 뒤에 오는 문서에서는 첫 매치가 아예 다른 리소스의 것이 된다.
  # ⚠️ 접두 제거를 치환으로 하지 말 것 — 숫자만 뽑는 매치가 BSD/GNU 양쪽에서 같다.
  LC_ALL=C awk -v want="$2" '
    function flush(   w, s) {
      if (doc ~ ("(^|\n)kind: " want "([ \t]|\n)")) {
        w = "0"
        if (match(doc, /argocd\.argoproj\.io\/sync-wave: *"?-?[0-9]+/)) {
          s = substr(doc, RSTART, RLENGTH)
          if (match(s, /-?[0-9]+$/)) w = substr(s, RSTART, RLENGTH)
        }
        print w
      }
      doc = ""
    }
    /^---[ \t]*$/ { flush(); next }
    { doc = doc $0 "\n" }
    END { flush() }
  ' "$1"
}

@test "the kustomization patches a sync-wave onto the vendored Gateway API CRDs" {
  # 번들 파일에는 annotation이 없다(upstream 그대로) — patch가 유일한 경로다.
  run grep -qE '^ *kind: CustomResourceDefinition' "$D/kustomization.yaml"
  [ "$status" -eq 0 ]
  run grep -qE 'argocd\.argoproj\.io~1sync-wave' "$D/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "the vendored CRD bundle itself stays unedited (no hand-added wave annotation)" {
  # 번들에 손으로 wave를 박으면 재벤더링(curl) 때 조용히 사라진다 — patch 경로를 강제한다.
  run grep -qE 'argocd\.argoproj\.io/sync-wave' "$D/gateway-api-crds.yaml"
  [ "$status" -eq 1 ]
  # 양성 대조 — 대상 0(파일이 비었거나 경로 오타)을 매치 0으로 오독하지 않는다.
  run grep -qE '^kind: CustomResourceDefinition' "$D/gateway-api-crds.yaml"
  [ "$status" -eq 0 ]
}

@test "the traefik controller stays at the default wave 0 (nothing pushes it earlier)" {
  # wave 0 = Helm 차트가 내는 traefik Deployment/Service + Issuer/Certificate + KSOPS Secret.
  # 아래 단언들은 전부 이 '컨트롤러 = 0' 전제 위에 서 있다.
  run grep -qE 'argocd\.argoproj\.io/sync-wave' "$D/helmrelease.yaml"
  [ "$status" -eq 1 ]
  run grep -qE 'argocd\.argoproj\.io/sync-wave' "$D/values-traefik.yaml"
  [ "$status" -eq 1 ]
  # 양성 대조 — 두 파일이 실재하고 비어 있지 않다.
  run grep -qE '^kind: HelmChartInflationGenerator' "$D/helmrelease.yaml"
  [ "$status" -eq 0 ]
  run grep -qE '^providers:' "$D/values-traefik.yaml"
  [ "$status" -eq 0 ]
  # kustomization의 patch는 CustomResourceDefinition만 겨냥해야 한다 — 다른 kind를 끌어당겨
  # 음수 wave를 붙이면 같은 교착이 재발한다.
  run sh -c "LC_ALL=C grep -E '^ *kind: ' '$D/kustomization.yaml' | LC_ALL=C grep -vcE 'kind: (Kustomization|CustomResourceDefinition)'"
  [ "$output" = "0" ] || { echo "kustomization에 예상 밖의 patch target kind가 있다 ($output개) — wave 영향을 다시 볼 것"; false; }
}

@test "CRDs are applied before every Gateway API resource that needs them" {
  crd="$(LC_ALL=C grep -A6 'kind: CustomResourceDefinition' "$D/kustomization.yaml" \
         | LC_ALL=C grep -m1 -oE 'value: *"?-?[0-9]+' | LC_ALL=C grep -oE '\-?[0-9]+$')"
  [ -n "$crd" ]
  gc="$(wave_of_kind "$D/gatewayclass.yaml" GatewayClass)"
  gw="$(wave_of_kind "$D/gateway.yaml" Gateway)"
  hr="$(wave_of_kind "$D/whoami-smoke.yaml" HTTPRoute)"
  [ -n "$gc" ] && [ -n "$gw" ] && [ -n "$hr" ]
  [ "$crd" -lt "$gc" ] || { echo "CRD wave=$crd · GatewayClass wave=$gc — CRD가 더 앞이어야 한다"; false; }
  [ "$crd" -lt "$gw" ] || { echo "CRD wave=$crd · Gateway wave=$gw — CRD가 더 앞이어야 한다"; false; }
  [ "$crd" -lt "$hr" ] || { echo "CRD wave=$crd · HTTPRoute wave=$hr — CRD가 더 앞이어야 한다"; false; }
}

@test "the ServiceAccount the controller pod needs is applied before the controller" {
  sa="$(wave_of_kind "$D/rbac-gateway.yaml" ServiceAccount)"
  [ -n "$sa" ]
  # 컨트롤러는 wave 0(Helm 차트) — SA가 그보다 앞이어야 파드 생성이 거부되지 않는다.
  [ "$sa" -lt 0 ] || { echo "ServiceAccount wave=$sa — traefik 컨트롤러(wave 0)보다 앞(음수)이어야 한다"; false; }
}

@test "GatewayClass and Gateway come after the controller that must accept and program them" {
  gc="$(wave_of_kind "$D/gatewayclass.yaml" GatewayClass)"
  gw="$(wave_of_kind "$D/gateway.yaml" Gateway)"
  [ -n "$gc" ] && [ -n "$gw" ]
  # GatewayClass의 Accepted·Gateway의 Programmed는 둘 다 traefik 컨트롤러(wave 0)가 붙어야 선다.
  # 컨트롤러보다 앞 wave에 두면 ArgoCD가 거기서 멈춰 컨트롤러가 영원히 apply되지 않는다.
  [ "$gc" -gt 0 ] || { echo "GatewayClass wave=$gc — traefik 컨트롤러(wave 0)보다 뒤여야 한다"; false; }
  [ "$gw" -gt 0 ] || { echo "Gateway wave=$gw — traefik 컨트롤러(wave 0)보다 뒤여야 한다"; false; }
  # Gateway의 web-internal-tls 리스너는 Certificate 발급물(home-wildcard-tls, wave 0)도 필요하다.
  run grep -qE 'name: home-wildcard-tls' "$D/gateway.yaml"
  [ "$status" -eq 0 ]
  run grep -qE 'secretName: home-wildcard-tls' "$D/cert-issuer.yaml"
  [ "$status" -eq 0 ]
  run grep -qE 'argocd\.argoproj\.io/sync-wave' "$D/cert-issuer.yaml"
  [ "$status" -eq 1 ] || { echo "cert-issuer.yaml에 sync-wave가 생겼거나 파일이 사라졌다 (rc=$status) — Gateway wave와의 관계를 다시 볼 것"; false; }
}

@test "the whoami smoke HTTPRoute attaches only after its Gateway is programmed" {
  gw="$(wave_of_kind "$D/whoami-smoke.yaml" HTTPRoute)"
  gwv="$(wave_of_kind "$D/gateway.yaml" Gateway)"
  dep="$(wave_of_kind "$D/whoami-smoke.yaml" Deployment)"
  svc="$(wave_of_kind "$D/whoami-smoke.yaml" Service)"
  [ -n "$gw" ] && [ -n "$gwv" ] && [ -n "$dep" ] && [ -n "$svc" ]
  [ "$gwv" -lt "$gw" ] || { echo "Gateway wave=$gwv · HTTPRoute wave=$gw — Gateway가 더 앞이어야 한다"; false; }
  # backend는 라우트와 같은 wave에 묶는다 — 라우트만 먼저 서면 ResolvedRefs가 실패한다.
  [ "$svc" -eq "$gw" ] || { echo "whoami Service wave=$svc · HTTPRoute wave=$gw — 같아야 한다"; false; }
  [ "$dep" -eq "$gw" ] || { echo "whoami Deployment wave=$dep · HTTPRoute wave=$gw — 같아야 한다"; false; }
}
