#!/usr/bin/env bats
# setup-bun composite — bun-version 핀 + frozen 설치 SSOT. (7 워크플로 채택)
# 9개 워크플로에 복붙된 setup/frozen-install 블록을 흡수한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 부재 단언은 `-eq 1`이다 — grep은 대상 부재/읽기불가에 rc 2를 내는데 `-ne 0`은 그것을 무매치와
#    구별하지 않아 대상이 리네임/삭제돼도 조용히 통과한다. 디렉토리 피연산자는 `-eq 1`로도 안
#    닫히므로 setup의 실재 단언 + 각 @test의 양성 대조(같은 피연산자 — 트리가 비면 그쪽이 먼저
#    red다)가 한 쌍으로 닫는다. 아무도 대조하지 않는 손 관리 건수 바닥값은 두지 않는다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-bun/action.yml"
  WF="$ROOT/.github/workflows"
  [ -d "$WF" ]
}

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
    # rc 2(파일 부재)를 통과로 읽지 않는다 — 아래 두 양성 단언이 같은 파일의 실재를 증언한다
    run grep -Fq 'oven-sh/setup-bun' "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -eq 1 ]                                   # 인라인 잔존 0
    run grep -Fq './.github/actions/setup-bun' "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # 컴포지트 사용
    run grep -Eq "install:[[:space:]]*'?false'?" "$ROOT/.github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]                                   # install:false(동작보존)
  done
}

@test "no workflow keeps node-setup or corepack pnpm, except the app-shared smoke (A.5 F2)" {
  # 양성 대조 — 열거 대상이 실제 워크플로 트리인지(`on:` 키는 이 디렉토리에서 사라질 리 없다)
  run grep -rlE '^on:' "$WF"
  [ "$status" -eq 0 ]
  # rc 2(디렉토리 부재)를 통과로 읽지 않는다 — 위 양성 대조가 같은 트리의 비공허성을 증언한다
  run grep -rE 'corepack prepare pnpm' "$WF"
  [ "$status" -eq 1 ]
  # setup-node는 ci.yaml(app-shared node 스모크) 1파일에서만 — 그 외 0
  run bash -c "grep -rlE 'actions/setup-node' '$WF' | grep -vE '/ci\.yaml$' || true"
  [ -z "$output" ]
  # 그 예외는 SHA핀 + node 24.14.0 (.mts 계약 하한은 22.18 — AGENTS.md, CI는 LTS 24)
  run grep -E "actions/setup-node@[0-9a-f]{40}" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
  run grep -E "node-version: ['\"]24\.14" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
}
