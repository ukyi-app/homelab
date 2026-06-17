#!/usr/bin/env bats
# setup-node-pnpm composite — node-version + pnpm corepack 핀을 한 곳에 SSOT화.
# 9개 워크플로에 복붙된 setup-node/corepack/frozen-install 블록을 흡수한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-node-pnpm/action.yml"; }

@test "setup-node-pnpm composite exists and pins node + pnpm" {
  [ -f "$A" ]
  run grep -E "node-version: ['\"]22['\"]" "$A"
  [ "$status" -eq 0 ]
  run grep -E 'corepack prepare pnpm@11' "$A"
  [ "$status" -eq 0 ]
  run grep -E 'pnpm install --frozen-lockfile' "$A"
  [ "$status" -eq 0 ]
}

@test "all 9 node workflows adopt the composite" {
  local wf
  for wf in ci.yaml onboard.yaml bump.yaml bump-poll.yaml _create-app.yaml _create-database.yaml _create-cache.yaml _teardown.yaml _audit.yaml; do
    run grep -F 'uses: ./.github/actions/setup-node-pnpm' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
}

@test "no node workflow keeps the inline corepack pnpm@11 block" {
  # dispatch-mutation은 pnpm install을 안 쓰므로(검증 전용) 제외 대상 — 인라인 corepack 0
  run grep -rE 'corepack prepare pnpm@11' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
}
