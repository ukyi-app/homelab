#!/usr/bin/env bats
# Gateway API 콜드스타트 sync-wave 순서 가드 (2026-08-14 NUC 콜드스타트 교착 2건에서 나온 것).
# ⚠️ 이 파일은 **두 축**을 본다: (1) 콜드스타트 sync-wave 순서, (2) Gateway 리스너 형상(포트·protocol·tls.mode·hostname·allowedRoutes).
#    마지막 @test가 (2)를 진다 — 그전까지 리스너 형상의 tracked 증인은 certificateRefs 이름 토큰 하나뿐이었다.
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
  # ⚠️ patch는 **resources에 든 문서**에만 붙는다 — 번들이 resources에서 빠지면 이 patch는 대상 0건이
  #    되고 위 두 단언은 그대로 초록이다(2026-09-04 실측: 6개 resources를 한 줄씩 지워도 이 파일 +
  #    image_pins·gate-secret-guard 42/42 전건 초록이었다). 그리고 CRD가 프룬되면 이 컴포넌트의
  #    Gateway API 리소스가 전부 apply 불가가 된다(#462 콜드스타트 교착 그 자체).
  # ⚠️ 건수 바닥값·length==N이 아니라 **정확 일치 멤버십**이다. `yq contains()`를 쓰지 않는 이유가
  #    바로 이 디렉토리에서 실측됐다(2026-09-04): yq의 배열 contains는 원소마다 부분문자열 판정이라
  #    `contains(["gateway.yaml"])`가 resources에 남아 있는 `rbac-gateway.yaml` 하나로 참이 된다.
  yq '.resources[]' "$D/kustomization.yaml" | grep -qxF 'gateway-api-crds.yaml' \
    || { echo "kustomization resources에 gateway-api-crds.yaml이 없다 — 렌더에서 빠지면 프룬된다"; false; }
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
  [ "$output" = "0" ] || { echo "kustomization에 예상 밖의 patch target kind가 있다 (${output}개) — wave 영향을 다시 볼 것"; false; }
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
  # wave 순서는 그 문서가 **렌더에 들어 있을 때만** 의미가 있다 — 파일을 열어 읽는 위 파생은
  # kustomization을 안 본다(2026-09-04 실측: resources에서 이 줄을 지워도 42/42 초록).
  # SA가 프룬되면 「Traefik serviceAccount.name 지정 시 SA 미생성」과 같은 자리에 떨어진다.
  yq '.resources[]' "$D/kustomization.yaml" | grep -qxF 'rbac-gateway.yaml' \
    || { echo "kustomization resources에 rbac-gateway.yaml이 없다 — 렌더에서 빠지면 프룬된다"; false; }
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
  # 위 세 파일의 wave 관계는 셋이 다 렌더에 들어 있을 때만 성립한다(2026-09-04 실측: 각각을
  # resources에서 지워도 42/42 초록). cert-issuer가 프룬되면 home-wildcard-tls가 발급되지 않아
  # web-internal-tls 리스너가 Programmed에 못 가고 내부 인입이 통째로 끊긴다.
  # ⚠️ 정확 일치로 센다 — `yq contains(["gateway.yaml"])`는 resources의 `rbac-gateway.yaml`에
  #    부분문자열로 걸려 gateway.yaml이 없어도 참이었다(2026-09-04 실측).
  for r in gatewayclass.yaml gateway.yaml cert-issuer.yaml; do
    yq '.resources[]' "$D/kustomization.yaml" | grep -qxF "$r" \
      || { echo "kustomization resources에 ${r}이 없다 — 렌더에서 빠지면 프룬된다"; false; }
  done
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
  # 같은 이유의 멤버십(2026-09-04 실측: resources에서 이 줄을 지워도 42/42 초록) — 스모크가
  # 프룬되면 Gateway가 Programmed인지 확인할 라이브 표면 자체가 없어진다.
  yq '.resources[]' "$D/kustomization.yaml" | grep -qxF 'whoami-smoke.yaml' \
    || { echo "kustomization resources에 whoami-smoke.yaml이 없다 — 렌더에서 빠지면 프룬된다"; false; }
}

@test "the Gateway listeners keep their shape (ports tied to the traefik entrypoints)" {
  # AGENTS.md 「내부 인입은 tailscale passthrough→:8443뿐」·platform/traefik/README.md의
  # 「web-internal-tls가 home.<도메인> 규약 담당」에 대한 유일한 tracked 증인이다.
  # 2026-09-03 실측: port 8443→8444 + 세 리스너 from:All→Same + hostname "*" + tls.mode Passthrough를
  # 동시에 걸어도 이 파일은 7/7 ok였다(check-skeleton·check-host-ports도 rc=0).
  # ⚠️ 이 @test가 막는 것은 **내부 인입 가용성 회귀**다 — 공개면 확대는 infra/cloudflare/tunnel.tf의
  #    hostname 열거와 tools/activate-app.ts의 .home. 차단이 이미 넣은 두 번째 잠금이다.
  # ⚠️ yq -e 금지 — 값이 false면 exit 1이라 키 부재(null)와 구별되지 않는다(traps-detail).
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 리스너 형상 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
  G="$D/gateway.yaml"; V="$D/values-traefik.yaml"
  # 바닥값 — 리스너 개명이 아래 select()를 공허 초록으로 바꾸는 것을 막는다.
  run bash -c "yq 'select(.kind==\"Gateway\") | .spec.listeners[].name' '$G' | LC_ALL=C sort | paste -sd, -"
  [ "$output" = "web-internal,web-internal-tls,web-public" ]
  # 내부 HTTPS 리스너 형상 — passthrough로 들어온 TLS를 여기서 종단한다.
  run yq 'select(.kind=="Gateway") | .spec.listeners[] | select(.name=="web-internal-tls") | .protocol' "$G"
  [ "$output" = "HTTPS" ]
  run yq 'select(.kind=="Gateway") | .spec.listeners[] | select(.name=="web-internal-tls") | .tls.mode' "$G"
  [ "$output" = "Terminate" ]
  run yq 'select(.kind=="Gateway") | .spec.listeners[] | select(.name=="web-internal-tls") | .hostname' "$G"
  [ "$output" = "*.home.ukyi.app" ]
  run yq 'select(.kind=="Gateway") | .spec.listeners[] | select(.name=="web-public") | .hostname' "$G"
  [ "$output" = "*.ukyi.app" ]
  # 교차-네임스페이스 라우트 허용 — 모든 HTTPRoute가 남의 ns에 산다. from: Same으로
  # 좀히면 내부 전 서비스의 라우트가 전건 detach된다.
  run bash -c "yq 'select(.kind==\"Gateway\") | .spec.listeners[].allowedRoutes.namespaces.from' '$G' | LC_ALL=C sort -u | paste -sd, -"
  [ "$output" = "All" ]
  # 포트는 리터럴이 아니라 **등호**로 고정한다 — 실제 파손 모드가 entrypoint↔리스너 불일치다.
  ws="$(yq '.ports.websecure.port' "$V")"; wp="$(yq '.ports.web.port' "$V")"
  [ -n "$ws" ]; [ "$ws" != "null" ]
  [ -n "$wp" ]; [ "$wp" != "null" ]
  [ "$ws" != "$wp" ]
  run yq 'select(.kind=="Gateway") | .spec.listeners[] | select(.name=="web-internal-tls") | .port' "$G"
  [ "$output" = "$ws" ] || { echo "web-internal-tls port=$output · values-traefik websecure=$ws — 같아야 한다"; false; }
  run bash -c "yq 'select(.kind==\"Gateway\") | .spec.listeners[] | select(.protocol==\"HTTP\") | .port' '$G' | LC_ALL=C sort -u | paste -sd, -"
  [ "$output" = "$wp" ] || { echo "HTTP 리스너 port=$output · values-traefik web=$wp — 같아야 한다"; false; }
}
