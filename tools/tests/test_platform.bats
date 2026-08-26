#!/usr/bin/env bats
# lib/platform.ts — 플랫폼 좌표 SSOT의 파생 계약. 아키타입 어휘(ARCHETYPES)는 여기 한 곳에만 리터럴로
# 존재하고, 나머지 표면(MCP inputSchema·결과 계약 생성기·CLI 사용법·doctor 검사 대상)은 전부 파생이다.
#   - COMPILED_ARCHETYPES = ARCHETYPES − ARCH_NEUTRAL_ARCHETYPES: 신규 아키타입은 기본으로 컴파일(doctor
#     TARGETARCH 검사 대상)이고, arch 중립은 명시 opt-out이다(fail-closed).
#   - 어휘 리터럴 전역 가드: tools/*.ts·tools/lib/*.ts(platform.ts 제외)에 감시 토큰 "fullstack"이 없다.
#     범위 결정: bun 전용 CLI 표면만이다 — `.mts` 2개는 app-shared(템플릿 측 node 양립 파일, 아키타입 주석은
#     스캐폴드 설명)라 제외, tools/tests/helpers는 픽스처(아키타입 이름이 데이터)라 제외. 생성물 JSON은 파생이다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# platform.ts(또는 그 사본)를 import해 세 배열을 한 줄로 찍는다: "<ARCHETYPES>|<NEUTRAL>|<COMPILED>".
platform_triplet() {
  run bun -e '
    const m = await import(process.argv[1]);
    console.log([m.ARCHETYPES.join(","), m.ARCH_NEUTRAL_ARCHETYPES.join(","), m.COMPILED_ARCHETYPES.join(",")].join("|"));
  ' "$1"
}

@test "COMPILED_ARCHETYPES is ARCHETYPES minus the explicit arch-neutral list (hand-pinned anchor)" {
  platform_triplet "$ROOT/tools/lib/platform.ts"
  [ "$status" -eq 0 ]
  # 손 앵커 — 세 배열 모두 리터럴로 핀한다(SSOT 축소·중립 목록 오염을 vacuous 없이 검출).
  [ "$output" = "api,fullstack,site,worker|site|api,fullstack,worker" ]
}

@test "a new archetype is compiled (doctor-checked) by default; arch-neutral is an explicit opt-out" {
  T="$BATS_TEST_TMPDIR/p"; mkdir -p "$T"
  # (1) ARCHETYPES에만 hexagon 추가 → COMPILED에 자동 편입(기본 = 검사 대상).
  sed 's|^\(export const ARCHETYPES = \[.*\)\] as const;|\1, "hexagon"] as const;|' tools/lib/platform.ts > "$T/added.ts"
  grep -q '^export const ARCHETYPES = .*"hexagon"\] as const;' "$T/added.ts"
  platform_triplet "$T/added.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "api,fullstack,site,worker,hexagon|site|api,fullstack,worker,hexagon" ]
  # (2) 중립 목록에도 hexagon 추가 → COMPILED에서 제외(명시 opt-out).
  sed 's|^\(export const ARCH_NEUTRAL_ARCHETYPES = \[.*\)\] as const|\1, "hexagon"] as const|' "$T/added.ts" > "$T/neutral.ts"
  grep -q '^export const ARCH_NEUTRAL_ARCHETYPES = .*"hexagon"\] as const' "$T/neutral.ts"
  platform_triplet "$T/neutral.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "api,fullstack,site,worker,hexagon|site,hexagon|api,fullstack,worker" ]
}

@test "the archetype vocabulary literal lives only in platform.ts (sentinel token guard, fail-closed)" {
  # 감시 토큰 = "fullstack"(다른 이름은 일반어라 오탐). 양성 대조: 같은 grep이 SSOT에서는 rc 0으로 매치한다.
  grep -q "fullstack" tools/lib/platform.ts
  # 열거는 glob(공백 안전) — 바닥값으로 열거 붕괴를 막고, 파일마다 [ -r ]로 검출기가 못 읽는 파일이 없음을
  # 사전 검증한다(traps: 읽기 불가 파일은 grep rc 2 → 아래 rc 포착이 red).
  scan=()
  for f in tools/*.ts tools/lib/*.ts; do
    [ "$f" = "tools/lib/platform.ts" ] && continue
    [ -r "$f" ]
    scan+=("$f")
  done
  [ "${#scan[@]}" -ge 40 ]
  # 부정 카운트 본체 — `|| true`로 rc를 삼키면 검출기 사망(rc 2)이 매치 0건으로 위장된다(traps
  # 「findings=$(awk … || true)」). rc를 포착해 1(무매치)만 통과시킨다: 0=누출(hits 출력), 2=검출기 오류.
  rc=0; hits="$(grep -n "fullstack" "${scan[@]}")" || rc=$?
  echo "rc=$rc"; echo "$hits"
  [ "$rc" -eq 1 ]
  [ -z "$hits" ]
}
