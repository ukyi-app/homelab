#!/usr/bin/env bats
# 툴체인 핀 게이트 — 무핀 get-helm-3(latest 설치)는 helm major가 chart-test를 깨면 유일 required
# check(gate)를 코드 무변경으로 막는 시한폭탄. helm을 고정 버전 tarball로 핀했는지 회귀 차단.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 부재 단언은 `-eq 1`이다 — grep은 대상 부재/읽기불가에 rc 2를 내는데 `-ne 0`은 그것을 무매치와
#    구별하지 않아 대상이 리네임/삭제돼도 조용히 통과한다. 디렉토리 피연산자는 `-eq 1`로도 안
#    닫히므로 setup의 실재 단언 + 각 @test의 양성 대조(같은 피연산자 — 트리가 비면 그쪽이 먼저
#    red다)가 한 쌍으로 닫는다. 아무도 대조하지 않는 손 관리 건수 바닥값은 두지 않는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」
setup() {
  # 이 파일은 ROOT로 cd 하고 상대경로를 쓴다 — WF도 그 관례를 따른다
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; WF=".github/workflows"
  [ -d "$WF" ]
}

@test "no workflow installs helm via the unpinned get-helm-3 script" {
  # 설치 invocation(raw.githubusercontent 스크립트)만 차단 — 설명 주석의 단어 언급은 무해
  # 양성 대조 — 열거 대상이 실제 워크플로 트리인지(`on:` 키는 이 디렉토리에서 사라질 리 없다)
  run grep -rlE '^on:' "$WF"
  [ "$status" -eq 0 ]
  # rc 2(디렉토리 부재)를 통과로 읽지 않는다 — 위 양성 대조가 같은 트리의 비공허성을 증언한다
  run grep -rl 'githubusercontent.com/helm/helm/main/scripts/get-helm-3' "$WF"
  [ "$status" -eq 1 ]
}

@test "helm is pinned via setup-toolchain everywhere it is installed" {
  # ci/verify/_create-app 모두 composite로 helm 설치 — 인라인 get-helm-3 핀은 더 이상 없다.
  local wf
  for wf in ci.yaml _create-app.yaml; do
    run grep -F 'uses: ./.github/actions/setup-toolchain' ".github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
  # composite가 helm을 고정 버전 tarball로 핀한다
  run grep -E 'get\.helm\.sh/helm-v[0-9]+\.[0-9]+\.[0-9]+' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
}
