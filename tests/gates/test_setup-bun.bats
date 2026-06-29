#!/usr/bin/env bats
# setup-bun composite — bun-version 핀 + frozen 설치 SSOT. (7 워크플로 채택)
# 9개 워크플로에 복붙된 setup/frozen-install 블록을 흡수한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-bun/action.yml"; }

@test "setup-bun composite exists and pins bun + frozen install" {
  [ -f "$A" ]
  run grep -E "oven-sh/setup-bun@[0-9a-f]{40}" "$A"; [ "$status" -eq 0 ]
  run grep -E "bun-version: ['\"]1\.3\.14['\"]" "$A"; [ "$status" -eq 0 ]
  run grep -E 'bun install --frozen-lockfile' "$A"; [ "$status" -eq 0 ]
}

@test "all 12 workflows adopt the setup-bun composite" {
  local wf
  for wf in ci.yaml bump.yaml bump-poll.yaml _create-app.yaml _create-database.yaml _create-cache.yaml audit.yaml \
            create-app.yaml create-cache.yaml create-database.yaml update-secrets.yaml dns-drift.yaml; do
    run grep -F 'uses: ./.github/actions/setup-bun' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
}

@test "setup-bun composite exposes an install input (default true)" {
  run grep -Eq '^[[:space:]]+install:' "$A"   # inputs.install 키
  [ "$status" -eq 0 ]
}

@test "dispatchers + dns-drift use the composite with install:false (no inline oven-sh, deps unneeded)" {
  for wf in create-app create-cache create-database update-secrets dns-drift; do
    run grep -Fq 'oven-sh/setup-bun' "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -ne 0 ]                                   # 인라인 잔존 0
    run grep -Fq './.github/actions/setup-bun' "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # 컴포지트 사용
    run grep -Eq "install:[[:space:]]*'?false'?" "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # install:false(동작보존)
  done
}

@test "no workflow keeps node-setup or corepack pnpm, except the app-shared smoke (A.5 F2)" {
  run grep -rE 'corepack prepare pnpm' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
  # setup-node는 ci.yaml(app-shared node 스모크) 1파일에서만 — 그 외 0
  run bash -c "grep -rlE 'actions/setup-node' '$ROOT/.github/workflows/' | grep -vE '/ci\.yaml$' || true"
  [ -z "$output" ]
  # 그 예외는 SHA핀 + node 24.14.0 (.mts 계약 하한은 22.18 — AGENTS.md, CI는 LTS 24)
  run grep -E "actions/setup-node@[0-9a-f]{40}" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
  run grep -E "node-version: ['\"]24\.14" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
}
