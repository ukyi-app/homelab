#!/usr/bin/env bats
# homepage kustomize render 가드 — grep-on-source가 못 잡는 조립 출력 + 인시던트 #65/#66 회귀.
# yq로 객체-스코프 단언(같은 Deployment 마운트·같은 egress 규칙 결속). @test 이름 영어. ⚠️ 중간 단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # CI(required gate)에선 skip 금지 — 툴 부재면 fail-closed(이 가드가 dead-green 되면 theme 클래스 재현, F6).
  # GitHub Actions는 CI=true. 로컬(CI 미설정)만 skip 허용.
  if ! command -v kustomize >/dev/null || ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 kustomize/yq 부재 — gate setup-toolchain 회귀(dead-green 방지)"; return 1; }
    skip "kustomize/yq 미설치(로컬만 — CI는 setup-toolchain 제공)"
  fi
  RENDERED="$BATS_TEST_TMPDIR/homepage-render.yaml"
  ( cd "$ROOT" && kustomize build platform/homepage/prod ) > "$RENDERED" 2>/dev/null
}

@test "homepage kustomize build succeeds and emits the core kinds + namespace" {
  [ -s "$RENDERED" ]
  for kind in Deployment Service HTTPRoute NetworkPolicy ConfigMap; do
    run yq -e "select(.kind == \"$kind\") | .kind" "$RENDERED"
    [ "$status" -eq 0 ]
  done
  run yq -e 'select(.metadata.namespace == "homepage") | .metadata.name' "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "configMapGenerator names are bound to the Deployment volume references (assembled nameReference rewrite, F4)" {
  D='select(.kind == "Deployment" and .metadata.name == "homepage")'
  # 생성된 해시접미 ConfigMap 이름 캡처(config=homepage-<hash>, assets=homepage-assets-<hash>)
  # ⚠️ 이 정규식 자체가 alertmanager(kustomization-4)와 같은 클래스의 자동 rollout 의존 가드를
  #    이미 겸한다 — `disableNameSuffixHash`를 최상위/per-generator 어느 철자로 켜도 이름이
  #    해시 접미 없는 리터럴 `homepage`/`homepage-assets`가 되어 `^homepage-[a-z0-9]+$`에 안
  #    걸리므로 이 @test와 아래 "generated ConfigMaps enumerate…"가 함께 red다(감사 6라운드
  #    티켓64 c64-9 실측 — 3가지 철자 전부 확인: 최상위·homepage 단독·homepage-assets 단독).
  #    별도 witness는 불필요(homepage/prod는 KSOPS 없이 CI에서 실제 kustomize build를 돌기까지
  #    한다 — alertmanager/victoria-stack보다 강한 커버리지).
  cm_config="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-[a-z0-9]+$"))) | .metadata.name' "$RENDERED")"
  cm_assets="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-assets-[a-z0-9]+$"))) | .metadata.name' "$RENDERED")"
  [ -n "$cm_config" ]; [ -n "$cm_assets" ]
  # config-src/assets 볼륨이 그 **정확한 생성 이름**을 참조(literal homepage 참조면 런타임 실패 — grep-on-source 못 잡음).
  # ★볼륨의 configMap.name을 추출해 bash 비교 — yq -e "==" 의 멀티독 출력이 yq 버전 따라 달라(CI v4.44 != 로컬 v4.52)
  #   "true" 단언이 깨졌다. 추출+비교는 버전 무관. grep -v '---'로 멀티독 구분자 제거.
  vol_config="$(yq "$D | .spec.template.spec.volumes[] | select(.name == \"config-src\") | .configMap.name" "$RENDERED" | grep -v '^---$' | head -1)"
  vol_assets="$(yq "$D | .spec.template.spec.volumes[] | select(.name == \"assets\") | .configMap.name" "$RENDERED" | grep -v '^---$' | head -1)"
  [ "$vol_config" = "$cm_config" ]
  [ "$vol_assets" = "$cm_assets" ]
}

@test "generated ConfigMaps enumerate every config/ and public/ source file" {
  # configMapGenerator의 files 열거에 증인이 0이었다 — 소스 파일을 지우지 않고 목록에서만 빼면
  # test_homepage_config.bats의 11 @test가 **클러스터에 없는 디스크 파일**을 계속 측정한다.
  # 실측 2026-09-03: config/services.yaml + public/logo.png 두 줄을 지워도 homepage bats 41/41 초록.
  # ⚠️ 기대값을 리터럴로 박지 않는다 — 디스크 디렉토리에서 파생해야 「파일 추가 후 열거 누락」(더 흔한
  #    방향)까지 덮고, kustomization에서 파생하면 뮤테이션과 함께 붕괴해 공허해진다.
  # ⚠️ 추출→bash 비교 관용구(위 :33-38) 유지 — yq 버전차(CI v4.44 vs 로컬 v4.52)의 멀티독 출력 때문.
  local want got
  want="$(LC_ALL=C ls "$BATS_TEST_DIRNAME/config" | LC_ALL=C sort | paste -sd, -)"
  [ -n "$want" ]
  got="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-[a-z0-9]+$"))) | .data | keys | sort | join(",")' "$RENDERED" | grep -v '^---$' | head -1)"
  [ "$want" = "$got" ] || { echo "config/ 디스크=$want · 렌더 ConfigMap 키=$got — 열거가 어긋났다"; false; }
  want="$(LC_ALL=C ls "$BATS_TEST_DIRNAME/public" | LC_ALL=C sort | paste -sd, -)"
  [ -n "$want" ]
  got="$(yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^homepage-assets-[a-z0-9]+$"))) | .binaryData | keys | sort | join(",")' "$RENDERED" | grep -v '^---$' | head -1)"
  [ "$want" = "$got" ] || { echo "public/ 디스크=$want · 렌더 assets 키=$got — 열거가 어긋났다"; false; }
}

@test "EROFS regression guard (#65): config emptyDir + seed binds + WRITABLE (readOnly!=true) mounts" {
  D='select(.kind == "Deployment" and .metadata.name == "homepage")'
  run yq -e "$D | .spec.template.spec.volumes[] | select(.name == \"config\") | has(\"emptyDir\")" "$RENDERED"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]           # config 볼륨이 emptyDir(RO configMap 직접 마운트 아님)
  # seed-config: config-src(RO)→/tmp/cfg, config(emptyDir)→/app/config
  run yq -e "$D | .spec.template.spec.initContainers[] | select(.name == \"seed-config\").volumeMounts[] | select(.name == \"config-src\" and .mountPath == \"/tmp/cfg\") | .name" "$RENDERED"
  [ "$status" -eq 0 ]
  # init의 config 마운트가 **writable**(readOnly!=true) — RO면 #65 EROFS 재현(F9)
  run yq -e "$D | .spec.template.spec.initContainers[] | select(.name == \"seed-config\").volumeMounts[] | select(.name == \"config\" and .mountPath == \"/app/config\" and (.readOnly != true)) | .name" "$RENDERED"
  [ "$status" -eq 0 ]
  # 메인 컨테이너 config 마운트도 **writable**(readOnly!=true)
  run yq -e "$D | .spec.template.spec.containers[] | select(.name == \"homepage\").volumeMounts[] | select(.name == \"config\" and .mountPath == \"/app/config\" and (.readOnly != true)) | .name" "$RENDERED"
  [ "$status" -eq 0 ]
}

@test "apiserver egress regression guard (#66): one egress rule binds node CIDR + TCP/6443, no ClusterIP" {
  N='select(.kind == "NetworkPolicy" and .metadata.name == "allow-egress-to-apiserver")'
  # 한 egress 규칙이 노드 CIDR + (protocol=TCP, port=6443) 포트 엔트리를 동시에(체인 select = 같은 규칙·같은 엔트리 결속, F9)
  run yq -e "$N | .spec.egress[] | select(.to[].ipBlock.cidr == \"192.168.117.0/24\") | select(.ports[] | (.port == 6443 and .protocol == \"TCP\")) | .ports" "$RENDERED"
  [ "$status" -eq 0 ]
  # apiserver egress에 ClusterIP 10.43.0.1/32 미사용(있으면 select 매치=exit0 → 회귀)
  # ⚠️ 여긴 grep이 아니라 `yq -e`라 `-eq 1` 전환 대상이 아니다 — yq는 값이 false여도 1이라 rc로
  #    키 부재를 못 가른다(레포 함정). 대상 부재는 setup의 `[ -s "$RENDERED" ]`가 앞서 red로 만든다.
  run yq -e "$N | .spec.egress[].to[].ipBlock.cidr | select(. == \"10.43.0.1/32\")" "$RENDERED"
  [ "$status" -ne 0 ]
}

@test "the NetworkPolicy set and its ipBlock set are exact (upper bound, F5)" {
  # test_homepage_netpol.bats:30-33의 리터럴 부재 단언(0.0.0.0/0)은 표기 하나만 막는다 —
  # 같은 뜻의 `egress: - {}`나 새 파일+kustomization 등록은 전건 통과한다(실측 2026-09-03).
  # 소스가 아니라 렌더($RENDERED)를 좌변으로 써서 표기·새 파일 경로를 한 번에 닫는다.
  [ "$(yq ea '[select(.kind=="NetworkPolicy")|.metadata.name]|sort|join(",")' "$RENDERED")" = \
    "allow-dns-egress,allow-egress-to-apiserver,allow-egress-to-glances,allow-egress-to-vmsingle,allow-ingress-from-gateway,allow-ingress-kubelet-probes,default-deny-all" ]
  [ "$(yq ea '[select(.kind=="NetworkPolicy")|..|select(has("ipBlock"))|.ipBlock.cidr]|sort|join(",")' "$RENDERED")" = "10.42.0.1/32,192.168.117.0/24" ]
}
