#!/usr/bin/env bats
# 가드 skip 신호 규약의 gate 테스트 — CONTRIBUTING '가드 skip 신호' 절 + tools/lib/cli.ts 주석이 SSOT,
# 정적 탐지기는 scripts/check-skip-signalling.sh(선례: check-bats-style.sh ↔ test_bats-style.bats).
#
# 병: 도메인이 없어 아무것도 평가 못 한 가드가 "검사했고 통과함"과 **똑같이 exit 0**이었다. 호출자·CI·사람
# 누구도 구별할 수 없어, 가드가 실제 실행 경로를 잃어도 전 게이트가 초록이었다(실측: verify-runbook-index는
# CI에서 무조건 skip이고 그 래퍼는 `[ "$status" -eq 0 ]`만 단언했다 — skip이 그 단언을 만족했다).
#
# 규약: 미평가 = `SKIP: <가드>: <이유>` 마커 + **exit 4**(같은 줄). 평가됨 = 0(통과)/1(실패), 마커 없음.
# ⚠️ GNU make는 recipe 종료코드를 자기 Error 2로 뭉갠다 → make 계층 신호는 **마커 + 비-0**까지다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# 통과하는 최소 bats 하나를 만들어 경로를 돌려준다 — 가드의 '평가 갈래'에 주입할 도메인.
# 실 스위트(라이브 posture·KSOPS)는 게이트에서 못 돌린다(bogus kubeconfig로 verify-posture 실측 2분 55초).
fixture_suite() {   # $1: 하위 디렉토리명
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  {
    echo '#!/usr/bin/env bats'
    echo
    echo "@test \"fixture suite $1 actually ran\" {"
    echo '  [ 1 -eq 1 ]'
    echo '}'
  } > "$BATS_TEST_TMPDIR/$1/test_fixture.bats"
  echo "$BATS_TEST_TMPDIR/$1/test_fixture.bats"
}

# --- 정적: 마커와 종료코드가 짝을 이루는가 (규약 드리프트 차단) ---

@test "check-skip-signalling passes on the current tree and reaches its domain" {
  # 스캔 건수를 함께 단언한다 — 열거가 무너져 0건을 봐도 '위반 0'과 똑같이 빈 출력이기 때문.
  run bash "$ROOT/scripts/check-skip-signalling.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '\([0-9]{2,}건 스캔\)'
}

@test "the detector catches a marker without the skip exit code (not vacuous)" {
  printf '%s\n' 'echo "SKIP: fake: 도메인 없음"' 'exit 0' > "$BATS_TEST_TMPDIR/fake.sh"
  run bash "$ROOT/scripts/check-skip-signalling.sh" "$BATS_TEST_TMPDIR/fake.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "SKIP 마커인데 skip 종료코드 아님"
}

@test "the detector catches the reverse violation (skip exit code without a marker)" {
  printf '%s\n' 'echo "도메인 없음"' 'exit 4' > "$BATS_TEST_TMPDIR/fake2.sh"
  run bash "$ROOT/scripts/check-skip-signalling.sh" "$BATS_TEST_TMPDIR/fake2.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "skip 종료코드인데 SKIP 마커 없음"
}

@test "the detector understands the TypeScript spelling of the skip exit code" {
  printf '%s\n' 'console.log("SKIP: fake-ts: 도메인 없음");' 'process.exit(0);' > "$BATS_TEST_TMPDIR/fake.ts"
  run bash "$ROOT/scripts/check-skip-signalling.sh" "$BATS_TEST_TMPDIR/fake.ts"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "SKIP 마커인데 skip 종료코드 아님"
}

@test "the enumeration floor fires when the scan domain collapses" {
  run env SKIP_SIGNAL_MIN_SCAN=99999 bash "$ROOT/scripts/check-skip-signalling.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the exit-code SSOT records 4 as skip in cli.ts and CONTRIBUTING" {
  run grep -q '4=skip' tools/lib/cli.ts; [ "$status" -eq 0 ]
  run grep -q '4=skip' CONTRIBUTING.md; [ "$status" -eq 0 ]
}

# --- 행동: make 가드 진입점이 도메인 부재를 skip으로 신호하는가 ---
# 도메인 오버라이드가 시임이다. make 계층이라 종료코드는 2(GNU make)이고 마커가 권위 신호다.

@test "make verify-posture signals skip when the live kubeconfig is absent" {
  run make verify-posture KUBECONFIG_LIVE="$BATS_TEST_TMPDIR/absent-kubeconfig"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "^SKIP: verify-posture:"
}

@test "make verify-posture evaluates its suite when the kubeconfig is present" {
  suite="$(fixture_suite posture)"
  : > "$BATS_TEST_TMPDIR/present-kubeconfig"
  run make verify-posture KUBECONFIG_LIVE="$BATS_TEST_TMPDIR/present-kubeconfig" POSTURE_BATS="$suite"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "fixture suite posture actually ran"
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "make verify-ksops signals skip when the age key is absent" {
  run make verify-ksops SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/absent-age-key"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "^SKIP: verify-ksops:"
}

@test "make verify-ksops evaluates its suite when the age key is present" {
  suite="$(fixture_suite ksops)"
  : > "$BATS_TEST_TMPDIR/present-age-key"
  run make verify-ksops SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/present-age-key" KSOPS_BATS="$suite"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "fixture suite ksops actually ran"
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "make verify-runbooks signals skip when the runbook bats domain is empty" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run make verify-runbooks RUNBOOK_DIR="$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "^SKIP: verify-runbooks:"
}

# 대칭 갈래 — 도메인이 있으면 **실제 판정**을 낸다(skip 마커 없음). 이게 없으면 위 세 개는
# "무조건 skip"인 죽은 타깃과 구별되지 않는다.
@test "make verify-runbooks evaluates the domain when runbook bats exist" {
  mkdir -p "$BATS_TEST_TMPDIR/rb"
  {
    echo '#!/usr/bin/env bats'
    echo
    echo '@test "fixture runbook assertion runs" {'
    echo '  [ 1 -eq 1 ]'
    echo '}'
  } > "$BATS_TEST_TMPDIR/rb/test_fixture.bats"
  run make verify-runbooks RUNBOOK_DIR="$BATS_TEST_TMPDIR/rb"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "fixture runbook assertion runs"
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "make verify-runbooks reports failure (not skip) when a runbook regression fails" {
  mkdir -p "$BATS_TEST_TMPDIR/rbfail"
  {
    echo '#!/usr/bin/env bats'
    echo
    echo '@test "fixture runbook assertion fails" {'
    echo '  [ 1 -eq 2 ]'
    echo '}'
  } > "$BATS_TEST_TMPDIR/rbfail/test_fixture.bats"
  run make verify-runbooks RUNBOOK_DIR="$BATS_TEST_TMPDIR/rbfail"
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 도메인 시임은 **명령행 오버라이드 전용**이어야 한다. `?=`면 환경변수가 새어 들어와 이 스위트 자체가
# 환경 의존이 된다(실측: RUNBOOK_DIR=/tmp/zzz로 test_make-runbooks가 red).
@test "the RUNBOOK_DIR seam ignores the ambient environment" {
  run env RUNBOOK_DIR=/tmp/definitely-not-the-runbook-dir make -n verify-runbooks
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs/runbooks"
}
