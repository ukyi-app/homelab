#!/usr/bin/env bats
# ci.yaml의 audit-orphans 게이트 주석이 실제 BLOCKING 셋과 표류하지 않게 강제한다.
# ⚠️ 중간 단언은 [ ]만 (bash 3.2 [[ ]] 침묵통과 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CI="$ROOT/.github/workflows/ci.yaml"
  SRC="$ROOT/tools/audit-orphans.ts"
}

@test "ci.yaml audit gate comment does not claim stale-ledger-row is blocking" {
  # 코드의 BLOCKING 셋엔 stale-ledger-row가 없다 — 주석도 그것을 차단한다고 말하면 안 된다.
  run grep -nE '^\s*const BLOCKING = new Set\(' "$SRC"
  [ "$status" -eq 0 ]
  # restale2: 정확-set 하드코딩 대신 stale-ledger-row 부재를 단언(BLOCKING에 activation-exposure-drift 추가됨).
  run sh -c "grep -E 'const BLOCKING = new Set' '$SRC' | grep -c stale-ledger-row"
  [ "$output" = "0" ]
  # audit-orphans 게이트 스텝 주석(run 라인 직전 #...)에 stale-ledger-row가 등장하면 실패
  run bash -c "awk '/registry\\/binding 정합 게이트/{f=1} f&&/bun tools\\/audit-orphans.ts --ci/{exit} f' '$CI' | grep -c 'stale-ledger-row'"
  [ "$output" = "0" ]
}

@test "ci.yaml audit gate comment names every blocking type from the source set" {
  # ⚠️ 옛 판본은 두 리터럴(orphan-dns·activation-exposure-drift)을 **하드코딩**해서 강제가
  #    단방향이었다: 주석이 낡아도 코드 쪽 BLOCKING이 커지면 아무도 안 봤다. 실제로 갈렸다 —
  #    `missing-activation`은 #293(2026-07-06)에 BLOCKING에 들어갔는데 ci.yaml 주석은
  #    2026-06-25 판본 그대로였고 이 @test는 계속 초록이었다(2026-09-03 실측 재현).
  #    ⇒ 소유자를 소스 한 곳으로 옮긴다: BLOCKING 줄에서 토큰을 파생해 전건을 루프로 확인한다.
  cmt="$(awk '/registry\/binding 정합 게이트/{f=1} f&&/bun tools\/audit-orphans.ts --ci/{exit} f' "$CI")"
  [ -n "$cmt" ]                      # 주석 블록 열거 붕괴(스텝 이름이 바뀌면 여기서 red)
  toks="$(grep -E 'const BLOCKING = new Set' "$SRC" | grep -oE '"[a-z-]+"' | tr -d '"')"
  n=0
  for t in $toks; do
    grep -q -- "$t" <<<"$cmt" || fail "ci.yaml 게이트 주석에 BLOCKING 유형 '$t'가 없다 — 주석이 코드보다 낡았다"
    n=$((n + 1))
  done
  [ "$n" -ge 3 ]                     # 토큰 열거 붕괴 바닥값(현 셋 크기 = 3)
}
