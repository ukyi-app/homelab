#!/usr/bin/env bats
# setup-toolchain composite의 kubeseal input — 봉인 워크플로의 kubeseal 버전 SSOT.
# 컨트롤러 appVersion(helmrelease.yaml app v0.38.4)과 동일 버전으로 수렴(seal/unseal 호환).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 부재 단언은 `-eq 1`이다 — grep은 대상 부재/읽기불가에 rc 2를 내는데 `-ne 0`은 그것을 무매치와
#    구별하지 않아 대상이 리네임/삭제돼도 조용히 통과한다. 디렉토리 피연산자는 `-eq 1`로도 안
#    닫히므로 setup의 실재 단언 + 각 @test의 양성 대조(같은 피연산자 — 트리가 비면 그쪽이 먼저
#    red다)가 한 쌍으로 닫는다. 아무도 대조하지 않는 손 관리 건수 바닥값은 두지 않는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-toolchain/action.yml"
  WF="$ROOT/.github/workflows"
  [ -d "$WF" ]
}

@test "setup-toolchain declares a kubeseal input" {
  run grep -E '^[[:space:]]*kubeseal:' "$A"
  [ "$status" -eq 0 ]
}

@test "setup-toolchain pins kubeseal to v0.38.4 (controller appVersion)" {
  run grep -E 'sealed-secrets/releases/download/v0\.38\.4/kubeseal-0\.38\.4-linux-arm64\.tar\.gz' "$A"
  [ "$status" -eq 0 ]
  # 옛 v0.27.3 핀이 composite에 남지 않았는지 — rc 2(파일 부재)를 통과로 읽지 않는다.
  # 위의 양성 단언이 같은 파일 "$A"의 실재를 함께 증언한다.
  run grep -E 'kubeseal-0\.27\.3' "$A"
  [ "$status" -eq 1 ]
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
    # 인라인 kubeseal 다운로드가 워크플로에 남지 않았는지 — rc 2(파일 부재)는 통과가 아니다.
    # 바로 위 양성 단언이 같은 파일의 실재를 증언한다.
    run grep -E 'sealed-secrets/releases/download/.*kubeseal' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 1 ]
  done
  # 옛 v0.27.3 핀이 어디에도 안 남았는지(레포 전역)
  # 양성 대조 — 열거 대상이 실제 워크플로 트리인지(`on:` 키는 이 디렉토리에서 사라질 리 없다)
  run grep -rlE '^on:' "$WF"
  [ "$status" -eq 0 ]
  # rc 2(디렉토리 부재)를 통과로 읽지 않는다 — 위 양성 대조가 같은 트리의 비공허성을 증언한다
  run grep -rE 'kubeseal-0\.27\.3' "$WF"
  [ "$status" -eq 1 ]
}

@test "_create-app uses the composite (no inline helm/kubeconform/conftest curl)" {
  local wf
  for wf in _create-app.yaml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
    # 아래 두 부재 단언의 양성 대조는 바로 위 줄이다 — 파일이 사라지면 그쪽이 먼저 red다.
    run grep -E 'get\.helm\.sh/helm-v' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 1 ]
    run grep -E 'conftest_0\.56\.0' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 1 ]
  done
}
