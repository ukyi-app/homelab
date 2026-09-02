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

# canonical 핀 — 갱신 시 이 한 줄만 바꾸고 아래 세 사이트를 같은 값으로 옮긴다.
# (`test_app-token-sha-ssot.bats:22`의 CANON 관용구를 그대로 따른다.)
CANON="1.3.14"

# `action.yml:2`의 "버전 SSOT"는 **워크플로 축**의 주장이다(12개 워크플로가 각자 핀하지 않는다는 뜻 —
# 바로 아래 @test가 그 독해를 증언한다). 로컬 축의 핀은 `Makefile`의 m6-tools이고, `package.json`의
# `packageManager`가 세 번째 선언이다. 셋이 같은 값인지 묻는 게이트가 0건이었다 — 각 테스트가
# 자기 파일 리터럴만 봐서, `action.yml` + 그 두 테스트만 올리고 `Makefile`을 잊으면 로컬도 CI도
# 초록인 채 런타임이 갈린다. 이 레포가 "하드코딩 소비처 목록은 자기 자신에게만 정확하다"로 이름
# 붙여 둔 클래스다(tools/check-ci-parity.ts:8-9).
# ⚠️ Makefile:147을 `jq`에서 **파생하지 않는다** — recipe의 `$(jq …)`를 make가 자기 함수로 먼저
#    확장해 빈 값이 되고, `grep -qF ""`는 모든 버전에 매치한다(툴체인 핀 게이트의 조용한 fail-open).
# ⚠️ 트리 전체 `1\.3\.[0-9]+` 센서스도 금물이다 — `@types/bun`은 Renovate가 독립적으로 올리고,
#    `tools/ensure-bump-pr.ts`의 "bun 1.3.14 실측"은 핀이 아니라 측정 출처 기록이다.
@test "every bun pin site declares the canonical version" {
  # (1) CI 축 — composite의 bun-version
  run grep -oE 'bun-version: "[0-9.]+"' "$A"
  [ "$status" -eq 0 ]
  [ "$output" = "bun-version: \"$CANON\"" ]
  # (2) 선언 축 — package.json packageManager
  run jq -r .packageManager "$ROOT/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "bun@$CANON" ]
  # (3) 로컬 축 — Makefile m6-tools. ERE에서 `|`는 교대 연산자라 `[|]`로 리터럴화한다.
  run grep -oE "bun --version [|] grep -qF '[0-9.]+'" "$ROOT/Makefile"
  [ "$status" -eq 0 ]
  [ "$output" = "bun --version | grep -qF '$CANON'" ]
  # (4) 그 등식이 **어디서 강제되는지**를 composite 자신이 가리켜야 한다 — 위 산문("버전 SSOT"의 축
  #     범위 + 나머지 두 축)이 지워지면 다음 사람은 이 파일만 올리고 끝낸다. 정적 증인은 파일명 하나로
  #     충분하다(문구 전체를 대조하면 리워딩마다 깨져 아무도 안 고치는 테스트가 된다).
  run grep -qF 'test_setup-bun.bats' "$A"
  [ "$status" -eq 0 ]
}

@test "setup-bun composite exists and pins bun + frozen install" {
  [ -f "$A" ]
  run grep -E "oven-sh/setup-bun@[0-9a-f]{40}" "$A"; [ "$status" -eq 0 ]
  run grep -E "bun-version: ['\"][0-9.]+['\"]" "$A"; [ "$status" -eq 0 ]   # 값은 위 CANON 등식이 소유
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
