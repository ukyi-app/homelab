#!/usr/bin/env bats
# 열거 붕괴 커널(scripts/lib/scan-floor.sh)의 gate 테스트.
#
# 병: `done < <(enumerator)` **프로세스 치환은 열거자 실패를 `set -euo pipefail`로 전파하지 않는다.**
# 워커가 죽으면 소비자가 0건을 검사하고 성공 메시지를 낸다 — 라이브 재현됨(실패하는 bun 셰임으로
# check-app-netpol·check-app-deploy가 "OK … 위반 0" + rc=0).
#
# 이건 **skip이 아니다**: 도메인이 없는 게 아니라 열거를 못 한 것이다. 01의 exit 4/`SKIP:` 마커를
# 쓰면 "정당하게 대상이 없음"으로 읽혀 정반대 뜻이 된다 — 여기선 검증 실패(비-0)다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/scripts/lib/scan-floor.sh"
}

@test "scan_enumerate returns the enumerator output when it succeeds" {
  run bash -c '. "$1"; scan_enumerate demo printf "a\nb\nc\n"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "a
b
c" ]
}

# 핵심 — 프로세스 치환이 삼키던 바로 그 실패를 잡는다.
@test "scan_enumerate fails loudly when the enumerator dies (the substitution swallowed this)" {
  run bash -c '. "$1"; scan_enumerate demo sh -c "exit 3"' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 실패"
}

@test "scan_enumerate does not treat a legitimately empty enumeration as failure" {
  # 0건 자체는 커널이 판정하지 않는다 — 그건 도메인 지식이라 소비자(scan_floor)가 정한다.
  run bash -c '. "$1"; scan_enumerate demo true; echo "rc=$?"' _ "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "rc=0"
}

@test "scan_floor passes at or above the floor" {
  run bash -c '. "$1"; scan_floor demo 10 10' _ "$LIB"
  [ "$status" -eq 0 ]
}

@test "scan_floor fails below the floor and names both numbers" {
  run bash -c '. "$1"; scan_floor demo 0 10' _ "$LIB"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "0건"
  echo "$output" | grep -q "10"
  echo "$output" | grep -q "열거 붕괴"
}

# 이 커널은 skip 규약과 **다른 채널**이다. 마커를 내면 01의 정적 가드가 짝(exit 4)을 요구하고,
# 더 나쁘게는 사람이 "정당하게 대상이 없음"으로 읽는다.
@test "the collapse signal is not the skip convention (no SKIP marker, not exit 4)" {
  run bash -c '. "$1"; scan_floor demo 0 10' _ "$LIB"
  [ "$status" -ne 0 ]
  [ "$status" -ne 4 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}
