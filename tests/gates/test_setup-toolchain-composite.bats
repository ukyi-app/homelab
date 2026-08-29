#!/usr/bin/env bats
# setup-toolchain composite — 핀된 툴체인 설치를 한 곳(.github/actions/setup-toolchain)으로 SSOT화.
# ci/verify가 composite를 쓰고, conftest 핀이 인라인 복붙이 아니라 composite에만 있는지 검사.
# (모든 install 스텝은 ci+verify의 실제 gate/verify run이 검증한다.)
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 부재 단언은 `-eq 1`이다 — grep은 대상 부재에 rc 2를 내고 `-ne 0`은 그것을 무매치와 구별하지 않는다.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "setup-toolchain composite action exists and pins conftest" {
  [ -f .github/actions/setup-toolchain/action.yml ]
  run grep -E 'conftest_0\.68\.2' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
}

@test "ci uses the composite (no inline conftest install)" {
  run grep -F 'uses: ./.github/actions/setup-toolchain' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
  # rc 2(파일 부재)를 통과로 읽지 않는다 — 위 양성 단언이 같은 파일 ci.yaml의 실재를 증언한다
  run grep -E 'conftest_0\.68\.2' .github/workflows/ci.yaml
  [ "$status" -eq 1 ]
}
