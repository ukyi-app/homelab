#!/usr/bin/env bats
# setup-bun composite — bun-version 핀 + frozen 설치 SSOT. (7 워크플로 채택)
# 9개 워크플로에 복붙된 setup/frozen-install 블록을 흡수한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-bun/action.yml"; }

@test "setup-bun composite exists and pins bun + frozen install" {
  [ -f "$A" ]
  run grep -E "oven-sh/setup-bun@[0-9a-f]{40}" "$A"; [ "$status" -eq 0 ]
  run grep -E "bun-version: ['\"]1\.3\.10['\"]" "$A"; [ "$status" -eq 0 ]
  run grep -E 'bun install --frozen-lockfile' "$A"; [ "$status" -eq 0 ]
}

@test "all 7 install workflows adopt the setup-bun composite" {
  local wf
  for wf in ci.yaml bump.yaml bump-poll.yaml _create-app.yaml _create-database.yaml _create-cache.yaml audit.yaml; do
    run grep -F 'uses: ./.github/actions/setup-bun' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
}

@test "no workflow keeps node-setup or corepack pnpm, except the app-shared smoke (A.5 F2)" {
  run grep -rE 'corepack prepare pnpm' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
  # setup-node는 ci.yaml(app-shared node 스모크) 1파일에서만 — 그 외 0
  run bash -c "grep -rlE 'actions/setup-node' '$ROOT/.github/workflows/' | grep -vE '/ci\.yaml$' || true"
  [ -z "$output" ]
  # 그 예외는 SHA핀 + node 22.18
  run grep -E "actions/setup-node@[0-9a-f]{40}" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
  run grep -E "node-version: ['\"]22\.18" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
}
