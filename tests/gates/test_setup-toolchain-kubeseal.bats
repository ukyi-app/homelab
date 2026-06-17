#!/usr/bin/env bats
# setup-toolchain composite의 kubeseal input — 봉인 워크플로의 kubeseal 버전 SSOT.
# 컨트롤러 appVersion(helmrelease.yaml app v0.37.0)과 동일 버전으로 수렴(seal/unseal 호환).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; }

@test "setup-toolchain declares a kubeseal input" {
  run grep -E '^[[:space:]]*kubeseal:' "$A"
  [ "$status" -eq 0 ]
}

@test "setup-toolchain pins kubeseal to v0.37.0 (controller appVersion)" {
  run grep -E 'sealed-secrets/releases/download/v0\.37\.0/kubeseal-0\.37\.0-linux-arm64\.tar\.gz' "$A"
  [ "$status" -eq 0 ]
  # 옛 v0.27.3 핀이 composite에 남지 않았는지
  run grep -E 'kubeseal-0\.27\.3' "$A"
  [ "$status" -ne 0 ]
}

@test "kubeseal step is gated on the kubeseal input" {
  # input이 'true'일 때만 설치 — 다른 잡엔 영향 0
  run grep -E "inputs\.kubeseal == 'true'" "$A"
  [ "$status" -eq 0 ]
}
