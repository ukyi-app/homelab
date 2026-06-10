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

@test "standard is the default StorageClass, Retain, Immediate" {
  run yq -e '.metadata.annotations["storageclass.kubernetes.io/is-default-class"]' "$STD"
  [ "$output" = "true" ]
  run yq -e '.reclaimPolicy' "$STD"; [ "$output" = "Retain" ]
  run yq -e '.volumeBindingMode' "$STD"; [ "$output" = "Immediate" ]
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
  # The bulk path is templated (${BULK_STORAGE_PATH}) so apply-storage.sh can point it at the
  # external-SSD mount (or the VM-disk dev fallback); the rendered-output check lives in 07.
  run grep -F '${BULK_STORAGE_PATH}' "$PROV"; [ "$status" -eq 0 ]
  run grep -F "$BULK_STORAGE_PATH" "$PROV"; [ "$status" -ne 0 ]  # literal external path must NOT be baked in
}

@test "helper pod image is wired to the LOCAL_PATH_HELPER_IMAGE placeholder" {
  # The source manifest carries the literal placeholder; apply-storage.sh (Task 1.8)
  # substitutes the arm64-pinned digest from versions.env at render time, and that
  # rendered-output check lives in 07-apply-storage.bats.
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$PROV"; [ "$status" -eq 0 ]
}

@test "each provisioner passes --configmap-name matching its mounted configmap" {
  # v0.0.30 REQUIRES --configmap-name (default 'local-path-config'); it names the configmap the
  # provisioner reads AND mounts (setup/teardown/helperPod) into every helper pod. With our renamed
  # configmaps, a missing/mismatched flag makes the daemon fatal and helper pods FailedMount
  # (caught only at LIVE provisioning, never by offline render) — this guards that regression.
  for pair in "local-path-provisioner-internal:local-path-config-internal" \
              "local-path-provisioner-bulk:local-path-config-bulk"; do
    dep="${pair%%:*}"; cm="${pair##*:}"
    args="$(yq "select(.kind==\"Deployment\" and .metadata.name==\"$dep\") | .spec.template.spec.containers[0].args" "$PROV")"
    [[ "$args" == *"--configmap-name=$cm"* ]]
    [[ "$args" == *"--helper-pod-file=/etc/config/helperPod.yaml"* ]]
    vol="$(yq "select(.kind==\"Deployment\" and .metadata.name==\"$dep\") | .spec.template.spec.volumes[] | select(.name==\"config-volume\") | .configMap.name" "$PROV")"
    [ "$vol" = "$cm" ]   # the flag MUST match the actually-mounted configmap
  done
}
