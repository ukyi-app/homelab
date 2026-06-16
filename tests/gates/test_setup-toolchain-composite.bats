#!/usr/bin/env bats
# setup-toolchain composite — 핀된 툴체인 설치를 한 곳(.github/actions/setup-toolchain)으로 SSOT화.
# ci/verify가 composite를 쓰고, conftest 핀이 인라인 복붙이 아니라 composite에만 있는지 검사.
# (모든 install 스텝은 ci+verify의 실제 gate/verify run이 검증한다.)
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "setup-toolchain composite action exists and pins conftest" {
  [ -f .github/actions/setup-toolchain/action.yml ]
  run grep -E 'conftest_0\.56\.0' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
}

@test "ci and verify use the composite (no inline conftest install)" {
  run grep -F 'uses: ./.github/actions/setup-toolchain' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/setup-toolchain' .github/workflows/verify.yaml
  [ "$status" -eq 0 ]
  run grep -E 'conftest_0\.56\.0' .github/workflows/ci.yaml
  [ "$status" -ne 0 ]
  run grep -E 'conftest_0\.56\.0' .github/workflows/verify.yaml
  [ "$status" -ne 0 ]
}
