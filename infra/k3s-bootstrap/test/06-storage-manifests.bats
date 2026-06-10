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
