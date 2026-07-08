#!/usr/bin/env bats
# setup-toolchain composite의 kubeseal input — 봉인 워크플로의 kubeseal 버전 SSOT.
# 컨트롤러 appVersion(helmrelease.yaml app v0.38.4)과 동일 버전으로 수렴(seal/unseal 호환).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"; }

@test "setup-toolchain declares a kubeseal input" {
  run grep -E '^[[:space:]]*kubeseal:' "$A"
  [ "$status" -eq 0 ]
}

@test "setup-toolchain pins kubeseal to v0.38.4 (controller appVersion)" {
  run grep -E 'sealed-secrets/releases/download/v0\.38\.4/kubeseal-0\.38\.4-linux-arm64\.tar\.gz' "$A"
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

@test "sealing workflows use the composite kubeseal (no inline kubeseal curl)" {
  local wf
  for wf in _create-cache.yaml _create-database.yaml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
    # 인라인 kubeseal 다운로드가 워크플로에 남지 않았는지
    run grep -E 'sealed-secrets/releases/download/.*kubeseal' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
  done
  # 옛 v0.27.3 핀이 어디에도 안 남았는지(레포 전역)
  run grep -rE 'kubeseal-0\.27\.3' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
}

@test "_create-app uses the composite (no inline helm/kubeconform/conftest curl)" {
  local wf
  for wf in _create-app.yaml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
    run grep -E 'get\.helm\.sh/helm-v' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
    run grep -E 'conftest_0\.56\.0' "$ROOT/.github/workflows/$wf"
    [ "$status" -ne 0 ]
  done
}
