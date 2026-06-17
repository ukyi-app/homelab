#!/usr/bin/env bats
# ci.yaml의 audit-orphans 게이트 주석이 실제 BLOCKING 셋과 표류하지 않게 강제한다.
# ⚠️ 중간 단언은 [ ]만 (bash 3.2 [[ ]] 침묵통과 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CI="$ROOT/.github/workflows/ci.yaml"
  SRC="$ROOT/tools/audit-orphans.mjs"
}

@test "ci.yaml audit gate comment does not claim stale-ledger-row is blocking" {
  # 코드의 BLOCKING 셋엔 stale-ledger-row가 없다 — 주석도 그것을 차단한다고 말하면 안 된다.
  run grep -nE '^\s*const BLOCKING = new Set\(' "$SRC"
  [ "$status" -eq 0 ]
  # restale2: 정확-set 하드코딩 대신 stale-ledger-row 부재를 단언(BLOCKING에 activation-exposure-drift 추가됨).
  run sh -c "grep -E 'const BLOCKING = new Set' '$SRC' | grep -c stale-ledger-row"
  [ "$output" = "0" ]
  # audit-orphans 게이트 스텝 주석(run 라인 직전 #...)에 stale-ledger-row가 등장하면 실패
  run bash -c "awk '/registry\\/binding 정합 게이트/{f=1} f&&/node tools\\/audit-orphans.mjs --ci/{exit} f' '$CI' | grep -c 'stale-ledger-row'"
  [ "$output" = "0" ]
}

@test "ci.yaml audit gate comment names both real blocking types" {
  run bash -c "awk '/registry\\/binding 정합 게이트/{f=1} f&&/node tools\\/audit-orphans.mjs --ci/{exit} f' '$CI'"
  echo "$output" | grep -q 'dangling-binding'
  echo "$output" | grep -q 'orphan-dns'
}
