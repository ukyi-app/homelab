#!/usr/bin/env bats
# 툴체인 핀 게이트 — 무핀 get-helm-3(latest 설치)는 helm major가 chart-test를 깨면 유일 required
# check(gate)를 코드 무변경으로 막는 시한폭탄. helm을 고정 버전 tarball로 핀했는지 회귀 차단.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "no workflow installs helm via the unpinned get-helm-3 script" {
  # 설치 invocation(raw.githubusercontent 스크립트)만 차단 — 설명 주석의 단어 언급은 무해
  run grep -rl 'githubusercontent.com/helm/helm/main/scripts/get-helm-3' .github/workflows/
  [ "$status" -ne 0 ]
}

@test "helm is pinned wherever installed (inline dispatch + pinned composite)" {
  local wf
  # dispatch 워크플로(onboard/_create-app)는 helm을 인라인 핀 tarball로 설치
  for wf in onboard.yaml _create-app.yaml; do
    run grep -E 'get\.helm\.sh/helm-v[0-9]+\.[0-9]+\.[0-9]+' ".github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
  # ci/verify는 setup-toolchain composite로 설치 — composite가 helm을 핀한다
  run grep -E 'get\.helm\.sh/helm-v[0-9]+\.[0-9]+\.[0-9]+' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
}
