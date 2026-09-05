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

# ── c71-3: 분모 ② 확장(파일/명령 writer) — 검출기 자기-뮤테이션 증인 ─────────────────────────────
# 2026-09-05 실증: 옛 분모(printf/echo만)는 `sed … "$f" | grep -qE 'guard_init'`(scripts/netpol-
# rehearsal.sh·tests/gates/vmalert-meta-firing-e2e.sh의 kubectl/grep -oE 실측 형태와 동형)에 rc 0을
# 냈다(레인 D — PR #641 gate red 원인). 아래는 넓힌 분모가 그 클래스를 잡고, 주석/grep -c(소비-완료)/
# herestring 재작성 형태는 그대로 살리는지를 함께 증언한다.

@test "flags a sed file-writer piped into grep -q (c71-3 denominator expansion)" {
  seed "sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

@test "flags the same sed writer when indented (c71-3)" {
  seed "  sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

@test "flags a kubectl multiline writer piped into grep -q (c71-3 denominator expansion)" {
  # scripts/netpol-rehearsal.sh 실측 형태(2026-09-05, 이 티켓이 herestring으로 전환) 재현.
  seed "kubectl -n prod get netpol x -o yaml | grep -q \"\$NEEDLE\"\n"
  run bash "$GUARD"
  unseed
  [ "$status" -ne 0 ]
}

# ⚠️ reg-a1-bats-guards-2 — 다단 파이프(예: `kubectl … | sort | grep -q NEEDLE`)는 이 레인의 사각이다.
#    키워드-바로-다음-파이프 인접만 보는 정규식이라 목록 밖 중간 명령(sort·tr·uniq·column 등)이 하나만
#    끼어도 무증인이다. 의도적으로 미대상 — 코드를 넓히면 무관 파이프가 오탐으로 뒤집힌다(check-sigpipe-writers.sh
#    헤더 ②(b) 참고). 전수 열거 라이브 위반 0건이라 확장 대상이 아니며, 새 사례가 나오면 개별 케이스로 추가한다.

@test "does not flag a whole-line comment that documents the command-writer idiom (c71-3)" {
  seed "# sed 's/x//' \"\$f\" | grep -qE 'guard_init'\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "does not flag a command writer consumed by grep -c instead of -q (safe consume-to-completion form, c71-3)" {
  seed "sed 's/x//' \"\$f\" | grep -c 'guard_init'\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}

@test "does not flag the prescribed herestring rewrite of a command writer (c71-3)" {
  seed "v=\"\$(sed 's/x//' \"\$f\")\"\ngrep -qE 'guard_init' <<<\"\$v\"\n"
  run bash "$GUARD"
  unseed
  [ "$status" -eq 0 ]
}
