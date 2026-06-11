#!/usr/bin/env bats
load test_helper

DIR="$BOOTSTRAP_DIR/storage"
STD="$DIR/storageclass-standard.yaml"
BULK="$DIR/storageclass-bulk-ssd.yaml"
PROV="$DIR/local-path-provisioner.yaml"

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all three storage manifests exist and are valid YAML" {
  for f in "$STD" "$BULK" "$PROV"; do
    [ -f "$f" ]
    run yq -e '.' "$f"; [ "$status" -eq 0 ]
  done
}

@test "standard is the default StorageClass, Retain, WaitForFirstConsumer" {
  run yq -e '.metadata.annotations["storageclass.kubernetes.io/is-default-class"]' "$STD"
  [ "$output" = "true" ]
  run yq -e '.reclaimPolicy' "$STD"; [ "$output" = "Retain" ]
  # local-path-provisioner는 WaitForFirstConsumer만 지원한다 (Immediate => "no node was specified").
  run yq -e '.volumeBindingMode' "$STD"; [ "$output" = "WaitForFirstConsumer" ]
  run yq -e '.provisioner' "$STD"; [ "$output" = "homelab.io/local-path-internal" ]
}

@test "bulk-ssd is NOT default, WaitForFirstConsumer, external path" {
  run yq -e '.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"' "$BULK"
  [ "$output" != "true" ]
  run yq -e '.volumeBindingMode' "$BULK"; [ "$output" = "WaitForFirstConsumer" ]
  run yq -e '.provisioner' "$BULK"; [ "$output" = "homelab.io/local-path-bulk" ]
}

@test "provisioner config maps each class to its node path" {
  run grep -F "$INTERNAL_STORAGE_PATH" "$PROV"; [ "$status" -eq 0 ]
  # bulk 경로는 템플릿(${BULK_STORAGE_PATH})이라 apply-storage.sh가 외장 SSD 마운트
  # (또는 VM 디스크 dev 폴백)를 가리키게 할 수 있다; 렌더 결과 검사는 07에 있다.
  run grep -F '${BULK_STORAGE_PATH}' "$PROV"; [ "$status" -eq 0 ]
  run grep -F "$BULK_STORAGE_PATH" "$PROV"; [ "$status" -ne 0 ]  # 외장 경로 리터럴이 박혀 있으면 안 된다
}

@test "helper pod image is wired to the LOCAL_PATH_HELPER_IMAGE placeholder" {
  # 소스 매니페스트는 플레이스홀더 리터럴을 담고 있다; apply-storage.sh(Task 1.8)가
  # 렌더 시점에 versions.env의 arm64 고정 digest로 치환하며, 그 렌더 결과 검사는
  # 07-apply-storage.bats에 있다.
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$PROV"; [ "$status" -eq 0 ]
}

@test "each provisioner passes --configmap-name matching its mounted configmap" {
  # v0.0.30은 --configmap-name(기본 'local-path-config')이 필수다; provisioner가 읽고 모든
  # helper pod에 마운트하는(setup/teardown/helperPod) configmap의 이름이다. 우리처럼 이름을
  # 바꾼 configmap에서는 플래그가 없거나 불일치하면 데몬이 fatal나고 helper pod가 FailedMount
  # 된다 (라이브 프로비저닝에서만 잡히고 오프라인 렌더로는 절대 안 잡힘) — 그 회귀를 막는다.
  for pair in "local-path-provisioner-internal:local-path-config-internal" \
              "local-path-provisioner-bulk:local-path-config-bulk"; do
    dep="${pair%%:*}"; cm="${pair##*:}"
    args="$(yq "select(.kind==\"Deployment\" and .metadata.name==\"$dep\") | .spec.template.spec.containers[0].args" "$PROV")"
    [[ "$args" == *"--configmap-name=$cm"* ]]
    [[ "$args" == *"--helper-pod-file=/etc/config/helperPod.yaml"* ]]
    vol="$(yq "select(.kind==\"Deployment\" and .metadata.name==\"$dep\") | .spec.template.spec.volumes[] | select(.name==\"config-volume\") | .configMap.name" "$PROV")"
    [ "$vol" = "$cm" ]   # 플래그는 실제로 마운트된 configmap과 일치해야 한다
  done
}
