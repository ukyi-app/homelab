#!/usr/bin/env bats
# cache 전체 KSOPS 렌더 검증 — cache-r2-creds.enc.yaml 복호에 실 age 키가 필요하다(SOPS_AGE_KEY_FILE).
# 그래서 .ci-exclude(gate엔 age 키 없음) — 로컬 `make ci`/owner가 실행(cnpg test_kustomize_build.bats 선례).
# CI-safe 정적 단언은 test_render.bats.

DIR="${BATS_TEST_DIRNAME}"
build() { kustomize build --enable-alpha-plugins --enable-exec "$DIR"; }

@test "kustomize build (ksops) renders the cache component entirely in namespace cache" {
  run build
  [ "$status" -eq 0 ]
  [ "$(build | yq '.metadata.namespace' | grep -v '^---' | sort -u)" = "cache" ]
}

@test "manifests are kubeconform-valid (strict)" {
  run bash -c "kustomize build --enable-alpha-plugins --enable-exec \"$DIR\" | kubeconform -strict -ignore-missing-schemas -summary"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "Invalid: 0"
  echo "$output" | grep -qF "Errors: 0"
}

@test "cache-r2-creds Secret renders with the rclone R2 key schema (KSOPS decrypt)" {
  s="$(build | yq 'select(.kind=="Secret" and .metadata.name=="cache-r2-creds")')"
  echo "$s" | grep -q "namespace: cache"
  # KSOPS 복호 후 rclone이 읽는 정본 키(값은 검증하지 않음)
  echo "$s" | grep -q "RCLONE_CONFIG_R2_ACCESS_KEY_ID"
  echo "$s" | grep -q "RCLONE_CONFIG_R2_ENDPOINT"
}
