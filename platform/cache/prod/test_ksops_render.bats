#!/usr/bin/env bats
# cache 전체 KSOPS 렌더 검증 — cache-r2-creds.enc.yaml 복호에 실 age 키가 필요하다(SOPS_AGE_KEY_FILE).
# 그래서 .ci-exclude(gate엔 age 키 없음) — owner-local `make verify-ksops`가 실행(age 키 있으면; cnpg KSOPS bats 선례).
# CI-safe 정적 단언은 test_render.bats.

DIR="${BATS_TEST_DIRNAME}"
build() { kustomize build --enable-alpha-plugins --enable-exec "$DIR"; }

@test "kustomize build (ksops) renders the cache component entirely in namespace cache" {
  run build
  [ "$status" -eq 0 ]
  [ "$(build | yq '.metadata.namespace' | grep -v '^---' | LC_ALL=C sort -u)" = "cache" ]
}

@test "manifests are kubeconform-valid (strict)" {
  # 🔴 형제 자리(platform/network-policies/prod/test_netpol.bats)와 **같은 결함**이었다: pipefail이
  #    없어 kustomize build 실패가 파이프 rc에 가려지고, 판정 셋이 전부 0건 입력에서 참이다.
  #    이 자리는 뮤테이션 없이 이미 공허 초록이었다 — ksops 미설치 호스트에서 build가
  #    `executable file not found`로 죽는데도 이 레인만 ok였다(실측 2026-09-03: 1 ok / 2 not ok).
  #    ksops 부재는 형제 두 레인이 red로 드러내는 편이 정직하다(skip 금지 — `make verify-ksops`가
  #    age 키 부재는 이미 exit 4 SKIP으로 낸다). 근거·선례는 test_netpol.bats의 같은 레인 주석.
  run bash -c "set -o pipefail; kustomize build --enable-alpha-plugins --enable-exec \"$DIR\" | kubeconform -strict -ignore-missing-schemas -summary"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Valid: [1-9][0-9]*, Invalid: 0'
  echo "$output" | grep -qF -- "Errors: 0"
}

@test "cache-r2-creds Secret renders with the rclone R2 key schema (KSOPS decrypt)" {
  s="$(build | yq 'select(.kind=="Secret" and .metadata.name=="cache-r2-creds")')"
  echo "$s" | grep -q "namespace: cache"
  # KSOPS 복호 후 rclone이 읽는 정본 키(값은 검증하지 않음)
  echo "$s" | grep -q "RCLONE_CONFIG_R2_ACCESS_KEY_ID"
  echo "$s" | grep -q "RCLONE_CONFIG_R2_ENDPOINT"
}
