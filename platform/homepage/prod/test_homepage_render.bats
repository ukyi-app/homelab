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
  run yq -e "$N | .spec.egress[] | select(.to[].ipBlock.cidr == \"192.168.139.0/24\") | select(.ports[] | (.port == 6443 and .protocol == \"TCP\")) | .ports" "$RENDERED"
  [ "$status" -eq 0 ]
  # apiserver egress에 ClusterIP 10.43.0.1/32 미사용(있으면 select 매치=exit0 → 회귀)
  run yq -e "$N | .spec.egress[].to[].ipBlock.cidr | select(. == \"10.43.0.1/32\")" "$RENDERED"
  [ "$status" -ne 0 ]
}
