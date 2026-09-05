#!/usr/bin/env bats
# check-sigpipe-writers.sh 의 판정 증인. @test 이름은 영어.
#
# ⚠️ 이 파일이 존재하는 이유(2026-09-01): 가드는 #565/#574로 21곳을 고치고 세워졌는데 **증인이
#    0건이었다.** 그 사이 정규식에 접두 `^[[:space:]]*[^#].*`가 있어 `[^#]`가 컬럼 0 줄의 첫
#    글자를 소비했고, 같은 취약 코드가 **들여쓰면 red · 컬럼 0이면 초록**이었다. 즉 가드가
#    고친 21곳 중 컬럼 0으로 회귀하는 것은 아무도 못 봤다. 뮤테이션을 밟는 증인이 없으면
#    가드의 판정 조건은 무증인으로 남는다(traps 「테스트 이름은 인터페이스가 아니다」).
#
# ⚠️ 중간 단언은 `[ ]`만 쓴다(bash 3.2에서 중간 `[[ ]]`는 침묵 통과한다).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$ROOT/scripts/check-sigpipe-writers.sh"
  # 픽스처: pipefail을 켠 임시 .sh. 가드는 git ls-files로 열거하므로 레포 안이어야 한다.
  FIX="$ROOT/scripts/.sigpipe-fixture.tmp.sh"
}

teardown() {
  rm -f "$FIX"
}

# 가드는 tracked 파일만 보므로, 픽스처를 인덱스에 넣었다가 되돌린다.
# (traps 「tracked 열거 게이트는 untracked 파일을 아예 안 본다」 — 그래서 add가 필수다.)
seed() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%b' "$1" > "$FIX"
  git -C "$ROOT" add -f -- "$FIX"
}

unseed() {
  git -C "$ROOT" rm -q --cached --force -- "$FIX" 2>/dev/null || true
  rm -f "$FIX"
}

@test "guard exists, is executable and is registered in the local ledger" {
  [ -x "$GUARD" ]
  run grep -q 'check-sigpipe-writers.sh' "$ROOT/policy/ci-parity.json"
  [ "$status" -eq 0 ]
}

@test "flags a vulnerable multiline writer at column 0" {
  seed "printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

@test "flags the same writer when indented" {
  seed "  printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

@test "flags an echo writer at column 0" {
  seed "echo \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

@test "does not flag a whole-line comment that documents the idiom" {
  seed "# printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "does not flag an indented whole-line comment either" {
  # 이 레그는 옛 정규식에서도 통과했다(거짓양성 재현 안 됨 — ERE는 leftmost-longest라
  # `[^#]`가 공백을 먹는 백트래킹이 기대만큼 열리지 않는다). 회귀 방지로 남긴다.
  seed "  # echo \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "does not flag the prescribed herestring form" {
  seed "grep -q x <<<\"\$list\"\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "ignores a file that does not enable pipefail (scope rule 1)" {
  printf '#!/usr/bin/env bash\nset -eu\nprintf %s\\\\n "$list" | grep -q x\n' > "$FIX"
  git -C "$ROOT" add -f -- "$FIX"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "flags a source-only lib with no pipefail literal in its own text (lib scope rule)" {
  # pipefail은 호출자 셸의 런타임 옵션이지 파일의 텍스트 속성이 아니다 — source 전용 lib
  # (scripts/lib/*.sh, 자기 원문에 pipefail 리터럴이 없다)이 pipefail 아래에서 source되는 형태는
  # scripts/lib/sops-recipients.sh(sops-guard.sh:24·verify-secrets.sh:22가 pipefail 아래서 source)가
  # 실제로 그 모양이다. 픽스처는 lib 표기(닷 접두 — check-doc-index.sh의 scripts/*.sh 글롭 밖) 아래
  # pipefail 원문 없이 다중행 writer를 파이프한다.
  LIBFIX="$ROOT/scripts/lib/.sigpipe-fixture.tmp.sh"
  cat > "$LIBFIX" <<'FIXEOF'
v="$(printf 'a\nb\n')"
printf '%s\n' "$v" | grep -q y
FIXEOF
  git -C "$ROOT" add -f -- "$LIBFIX"
  run bash "$GUARD"
  git -C "$ROOT" rm -q --cached --force -- "$LIBFIX" 2>/dev/null || true
  rm -f "$LIBFIX"
  [ "$status" -ne 0 ]
}

@test "the guard prescribes herestring in its failure output" {
  seed "printf '%s\\\\n' \"\$list\" | grep -q x\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '<<<'
}
