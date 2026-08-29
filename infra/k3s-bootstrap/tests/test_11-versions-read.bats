#!/usr/bin/env bats
# versions.env 단일 값 리더(`versions-read.sh`)의 계약 + versions.env 전 줄 정본 형태 정적 가드.
#
# ⚠️ 이 파일의 두 축은 **하나의 불변식**을 지킨다: **"텍스트 파서 == source"**.
#    리더는 versions.env를 source하지 않고 텍스트로 읽는다(파괴 직전 셸이 남의 export를 안 들인다).
#    그 결정이 안전하려면 두 관측이 **모든 허용 어휘에서 같은 값**을 내야 한다. 어휘를 좁히지 않으면
#    같지 않다 — 대표적으로 백슬래시(실측은 아래 계약 @test 주석에 있다).
#    ⇒ ① 계약 @test가 "같다"를 어휘 전 형태에서 실측하고,
#       ② `--lint` 정적 가드가 versions.env 전 줄을 그 어휘 안에 가둔다.
#      한쪽만 있으면 불변식은 우연이다.
#
# ⚠️ @test 이름은 영어만 — CJK면 bats 디렉토리 실행에서 조용히 스킵된다(check-skeleton.sh 가드).
load test_helper

setup() {
  ROOT="$(cd "$BOOTSTRAP_DIR/../.." && pwd)"
  R="$BOOTSTRAP_DIR/versions-read.sh"
  # 허용 어휘의 **전 형태**. 새 형태를 versions.env에 쓰려면 여기 먼저 넣어라 —
  # 그러면 계약 @test가 그 형태에서도 "텍스트 == source"인지 실측한다.
  ALLOWED="$BATS_TEST_TMPDIR/allowed.env"
  { printf '# 주석 줄은 판정 밖이다\n'
    printf '\n'
    printf 'export A_EMPTY=""\n'
    printf 'export B_PLAIN="v1.36.3+k3s1"\n'
    printf 'export C_SPACES="1.1.1.1 9.9.9.9"\n'
    printf 'export D_PATH="/var/lib/rancher/k3s-storage/internal"\n'
    printf 'export E_DIGEST="busybox:1.38@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616"\n'
    printf 'export F_TZ="Asia/Seoul"\n'
    printf 'export G_PUNCT="a-b_c.d,e;f:g|h!i?j*k&l(m)n[o]p{q}r<s>t=u+v~w%%x^y#z"\n'
    printf "export H_SQUOTE=\"it's fine\"\n"
    printf 'export I_TAB="\tlead tab and trail space "\n'
  } > "$ALLOWED"
  ALLOWED_KEYS="A_EMPTY B_PLAIN C_SPACES D_PATH E_DIGEST F_TZ G_PUNCT H_SQUOTE I_TAB"
}

_read() {                    # $1 = 피연산자 파일 · $2 = 키.  stdout=값 · rc=리더 rc
  run env VERSIONS_ENV_FILE="$1" "$R" "$2"
}
_one_line() {                # 한 줄짜리 픽스처 파일을 만들고 경로를 echo한다
  f="$BATS_TEST_TMPDIR/one$RANDOM.env"
  printf '%s\n' "$1" > "$f"
  echo "$f"
}

# ── 배치 계약 ──────────────────────────────────────────────────────────────────────────────
@test "the reader is executable with git mode 100755 and passes shellcheck" {
  # ⚠️ 실행 비트는 장식이 아니다 — 소비자가 `bash <경로>`가 아니라 **직접 실행**한다.
  #    형제 bulk-gate-probe.sh가 644라 "같은 트리에 두면 자동으로 755"는 거짓이다.
  [ -x "$R" ]
  run git -C "$ROOT" ls-files -s infra/k3s-bootstrap/versions-read.sh
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '^100755 '
  run shellcheck "$R"
  [ "$status" -eq 0 ]
}

# ── 계약: 텍스트 파서 == source ────────────────────────────────────────────────────────────
@test "reader output equals the sourced value for every allowed vocabulary shape" {
  # ⚠️ 이것이 티켓 07의 핵심 단언이다. 두 관측이 갈리면 두 소비자가 서로 다른 값을 본다.
  #    (`apply-storage.sh`·`k3s-install.sh` 등 6파일은 여전히 source한다 — 갈리면 그쪽이 다른 값을 쓴다.)
  # shellcheck disable=SC1090
  . "$ALLOWED"
  n=0
  for k in $ALLOWED_KEYS; do
    _read "$ALLOWED" "$k"
    [ "$status" -eq 0 ]
    want="${!k}"
    [ "$output" = "$want" ]
    n=$((n + 1))
  done
  # 바닥값 — 목록이 비면 이 @test는 아무것도 대조하지 않은 채 초록이다(열거 붕괴).
  # ⚠️ 건수는 적지 않는다(손 관리 수치는 반드시 드리프트한다 — scripts/lib/scan-floor.sh 규약).
  [ "$n" -gt 0 ]
}

@test "a DECLARED empty value is rc 0 with empty stdout (not folded into 'undecidable')" {
  # 옛 sed 파생이 지우던 구별이 정확히 이것이다 — 선언된 빈 값과 판정 불가.
  _read "$ALLOWED" A_EMPTY
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ── 판정 불가 4종: 파일 부재 · 키 부재 · 형태 · 중복 ───────────────────────────────────────
@test "a missing file is rc 1 with FILE_MISSING (absence is not an empty value)" {
  _read "$BATS_TEST_TMPDIR/nope.env" A_EMPTY
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'versions-read: FILE_MISSING:'
}

@test "a missing key is rc 1 with KEY_MISSING" {
  _read "$ALLOWED" NO_SUCH_KEY
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'versions-read: KEY_MISSING:'
}

@test "a duplicated declaration is rc 1 with DUPLICATE (which one is canonical is undecidable)" {
  f="$BATS_TEST_TMPDIR/dup.env"
  { printf 'export K="a"\n'; printf 'export K="b"\n'; } > "$f"
  _read "$f" K
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'versions-read: DUPLICATE:'
}

@test "every out-of-vocabulary line shape is rc 1 with MALFORMED" {
  # ⚠️ 백슬래시 두 형태가 이 목록의 존재 이유다(설계 게이트 r1 · F2). 실측(bash 5.3):
  #      export K="a\\b"  → source: a\b   · 텍스트: a\\b        (값이 갈린다)
  #      export K="a\"    → source: 구문 오류(`bash -n` rc 2, K·이후 선언 전부 미설정)
  #                        · 텍스트: a\    (옛 sed 정규식은 이것을 **통과**시켰다)
  #    즉 백슬래시를 허용하면 "텍스트 파서 == source"가 거짓이다. 어휘에서 배제하는 쪽을 택했다 —
  #    bash 이스케이프를 정확히 재현하는 대안은 이 리더를 파서로 만든다.
  n=0
  while IFS= read -r bad; do
    f="$(_one_line "$bad")"
    _read "$f" K
    [ "$status" -eq 1 ]
    printf '%s' "$output" | grep -qF 'versions-read: MALFORMED:'
    n=$((n + 1))
  done <<'CASES'
export K="a\"
export K="a\\b"
export K="$HOME"
export K="`date`"
export K=plain
export K='x'
export K="x" # 주석
  export K="x"
K="x"
CASES
  # 바닥값 — 케이스 목록이 비면 이 @test는 검출기 없이 초록이다(열거 붕괴).
  [ "$n" -gt 0 ]
  # 양성 대조 — **같은 루프 모양**이 정본 줄에서는 rc 0을 낸다(리더가 '전부 거부'로 퇴화하면 red).
  f="$(_one_line 'export K="x"')"
  _read "$f" K
  [ "$status" -eq 0 ]
  [ "$output" = "x" ]
}

@test "usage errors are rc 1 too (there is no rc-0 path that skips the judgment)" {
  # ⚠️ 인자 하나로 판정을 건너뛰는 off-switch가 없어야 한다 — 형제 가드가 실제로 밟은 자리다
  #    (check-bats-accounting.sh 헤더: 임의 토큰 하나가 회계를 통째로 껐다).
  run env VERSIONS_ENV_FILE="$ALLOWED" "$R"
  [ "$status" -eq 1 ]
  run env VERSIONS_ENV_FILE="$ALLOWED" "$R" --bogus
  [ "$status" -eq 1 ]
  run env VERSIONS_ENV_FILE="$ALLOWED" "$R" 'not a key'
  [ "$status" -eq 1 ]
  run env VERSIONS_ENV_FILE="$ALLOWED" "$R" A_EMPTY B_PLAIN
  [ "$status" -eq 1 ]
}

# ── 정적 가드: versions.env 전 줄이 정본 형태다 ────────────────────────────────────────────
@test "the real versions.env is entirely in the canonical vocabulary" {
  # ⚠️ 이 @test가 "텍스트 파서 == source"를 **우연이 아니라 강제**로 만든다. 위 계약 @test는
  #    어휘 안에서만 등식을 증명하므로, 어휘 밖 줄이 파일에 들어오면 등식이 조용히 깨진다.
  run env VERSIONS_ENV_FILE="$BOOTSTRAP_DIR/versions.env" "$R" --lint
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'lint OK'
}

@test "the lint rejects a single out-of-vocabulary line appended to a copy of the real file" {
  # 뮤테이션 증인 — 위 @test가 검출기 없이 초록이 되는 것을 막는다.
  f="$BATS_TEST_TMPDIR/mutated.env"
  cp "$BOOTSTRAP_DIR/versions.env" "$f"
  printf 'export MUTANT="a\\b"\n' >> "$f"
  run env VERSIONS_ENV_FILE="$f" "$R" --lint
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'versions-read: MALFORMED:'
  printf '%s' "$output" | grep -qF 'MUTANT'
}

@test "the lint refuses a file with zero declarations (0 findings is enumeration collapse, not cleanliness)" {
  f="$BATS_TEST_TMPDIR/comments-only.env"
  { printf '# 주석뿐\n'; printf '\n'; } > "$f"
  run env VERSIONS_ENV_FILE="$f" "$R" --lint
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'versions-read: EMPTY:'
}

# ── 도달: 옛 sed 파생이 레포에 남아 있지 않다 ──────────────────────────────────────────────
@test "every versions.env single-value derivation goes through the reader (no sed one-liner survives)" {
  cd "$ROOT" || return 1
  # 양성 대조를 **먼저** 건다 — 아래 부재 단언이 pathspec/도메인 붕괴로 공허해지는 것을 막는다.
  # ⚠️ git grep rc는 0=매치 / 1=무매치 / **128**=치명적(비-레포·pathspec 오타)이다. grep의 rc 2와
  #    값이 다르니 grep 규약을 그대로 옮겨 적지 말 것(docs/traps-detail.md ③-a/b).
  # ⚠️ 도메인은 **코드**다(`*.sh`·`*.bats`) — 산문은 옛 관용구를 리터럴로 인용해야 한다
  #    (README와 이 파일이 그 이유를 적으려면 그 글자를 담을 수밖에 없다). 선례: test_dr-drill.bats의
  #    "no OrbStack binding remains in the DR destruction path (code, not prose)".
  git grep -q 'versions-read.sh' -- '*.sh' '*.bats'
  # 소비자 4곳이 **각각** 리더를 지난다(개수가 아니라 파일 이름으로 잠근다 — 손 관리 수치 금지).
  grep -qE '^[^#]*"\$VERSIONS_READ" BULK_MIGRATION_WINDOW_UNTIL' scripts/destroy-node.sh
  grep -qE '^[^#]*"\$VERSIONS_READ" BULK_STORAGE_PATH' scripts/destroy-node.sh
  grep -qE '^[^#]*"\$VERSIONS_READ" BULK_MIGRATION_WINDOW_UNTIL' scripts/dr-drill.sh
  grep -qE '^[^#]*versions-read\.sh" BULK_MIGRATION_WINDOW_UNTIL' tests/gates/test_files-backup-phase-a.bats
  # 옛 관용구가 어디서든 되살아나면 red. `^[^#]*` — 세 파일의 **주석이 옛 관용구를 리터럴로
  # 담고 있어서**(fail-open의 근거를 적은 자리) 전체 줄 검색은 주석에 걸려 거짓 red를 낸다.
  run git grep -nE "^[^#]*sed -n 's/\^export " -- '*.sh' '*.bats'
  [ "$status" -eq 1 ]
}
