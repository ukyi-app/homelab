#!/usr/bin/env bash
# versions.env **단일 값 리더** — 선언 하나를 텍스트로 읽어 stdout에 돌려준다. `source`하지 않는다.
#
# ⚠️ **왜 source가 아닌가.** 첫 소비자가 파괴 경계다(`scripts/destroy-node.sh` · `scripts/dr-drill.sh`).
#    그 자리에서 `source`하면 파괴 직전 셸이 남의 파일에 있는 export **전부**를 자기 환경으로 들인다 —
#    destroy-node.sh 헤더가 못박은 결정이고 여기서 그대로 승계한다.
#
# ⚠️ **왜 sed 한 줄이 아닌가.** 옛 관용구
#      sed -n 's/^export KEY="\(.*\)"$/\1/p' versions.env 2>/dev/null || true
#    는 파일 부재 · 키 부재 · 줄 포맷 변경을 **전부 빈 문자열로 접는다.** 소비자는 그 빈 문자열을
#    "선언된 빈 값"과 구별할 수 없다. `BULK_MIGRATION_WINDOW_UNTIL`에서는 셋이 모두
#    "국면 B — 파괴해도 좋다"로 읽혔고, 같은 파일의 `BULK_STORAGE_PATH`는 반대로 fail-closed였다.
#    한 파일 안의 그 비대칭이 이 리더의 존재 이유다.
#
# 종료코드는 **2분기**다 — 3-way를 쓰는 콜사이트가 0곳이라 유지 근거가 없다:
#   rc 0 = 정본 선언 1회. stdout = 그 값(**선언된 빈 값 포함**). stderr 없음.
#   rc 1 = 판정 불가(파일 부재 · 키 부재 · 형태 위반 · 중복 · 사용법). stderr에 사유 한 줄.
#
# 사용:
#   infra/k3s-bootstrap/versions-read.sh <KEY>    선언 1건을 읽는다
#   infra/k3s-bootstrap/versions-read.sh --lint   파일 전 줄이 정본 형태인지 검사한다(정적 가드)
# 시임: VERSIONS_ENV_FILE (기본 = 이 스크립트와 같은 디렉토리의 versions.env)
#
# ⚠️ 실행 비트가 계약이다(git 모드 100755). 소비자는 `bash <경로>`가 아니라 **직접 실행**하므로
#    644로 떨어지면 즉시 fail-loud다 — 형제 `bulk-gate-probe.sh`가 644라 "복사하면 된다"가 참이 아니다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV_FILE="${VERSIONS_ENV_FILE:-$SCRIPT_DIR/versions.env}"

_reason() { printf 'versions-read: %s\n' "$*" >&2; }

# ── 정본 문법 (SSOT) ───────────────────────────────────────────────────────────────────────
#   ^export <KEY>="<값>"$      <값>에 `"` · `$` · 백틱 · **백슬래시** 금지.
#
# ⚠️ **백슬래시 배제가 "텍스트 파서 == source" 불변식의 전제다.** 백슬래시를 허용하면 그 불변식이
#    거짓이 된다: bash 큰따옴표는 이스케이프를 해석하는데(`"a\\b"` → `a\b`) 이 리더는 원시 바이트를
#    돌려준다(`a\\b`). 더 나쁘게 후행 `\"`는 정규식을 만족하면서 셸 선언을 **미종료**로 남긴다 —
#    같은 파일을 텍스트로 읽는 쪽과 source하는 쪽이 서로 다른 값을 관측한다.
#    (bash 이스케이프를 정확히 재현하는 대안은 이 리더를 파서로 만든다. 어휘를 좁히는 쪽을 택했다.)
#
# ⚠️ 아래 술어는 **리더와 `--lint`가 함께 쓴다.** 한쪽만 고치는 드리프트가 원리적으로 불가능해야
#    "전 줄이 정본"이라는 정적 가드가 리더의 계약과 같은 것을 말한다.
# ⚠️ 백슬래시는 `index()`로 따로 본다 — 브래킷 표현식 안의 백슬래시는 awk 구현마다 해석이 갈린다.
#    실측 2026-08-29: 이 술어는 gawk 5.3.2 · mawk · busybox awk **셋이 같은 판정**을 낸다
#    (같은 versions.env에 lint rc 0 · 같은 값 · `export K="a\b"`에 MALFORMED rc 1).
GRAMMAR=''
IFS='' read -r -d '' GRAMMAR <<'AWK' || true
function is_skippable(line) {
  return (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/)
}
function is_canon(line) {
  if (index(line, "\\") != 0) return 0
  return (line ~ /^export [A-Za-z_][A-Za-z0-9_]*="[^"$`]*"$/)
}
function decl_key(line,   t, eq) {
  t = line
  sub(/^[ \t]+/, "", t)
  sub(/^export[ \t]+/, "", t)
  eq = index(t, "=")
  if (eq == 0) return ""
  return substr(t, 1, eq - 1)
}
function canon_value(line,   p) {
  p = index(line, "=\"")
  return substr(line, p + 2, length(line) - p - 2)
}
AWK

_lint() {
  local out bad total tag a b
  out="$(awk "$GRAMMAR"'
    is_skippable($0) { next }
    { total++; if (!is_canon($0)) printf "BAD\t%d\t%s\n", FNR, $0 }
    END { printf "TOTAL\t%d\n", total + 0 }
  ' "$VERSIONS_ENV_FILE")"
  bad=0
  total=0
  while IFS="$(printf '\t')" read -r tag a b; do
    case "$tag" in
      BAD)   bad=$((bad + 1)); _reason "MALFORMED: ${VERSIONS_ENV_FILE}:${a} 정본 형태가 아니다(어휘: ^export KEY=\"값\"$ · 값에 \" \$ 백틱 백슬래시 금지) → ${b}" ;;
      TOTAL) total="$a" ;;
    esac
  done < <(printf '%s\n' "$out")
  # ⚠️ 선언 0건은 "위반 0"이 아니라 **열거 붕괴**다 — 파일이 비거나 전부 주석이 되면 이 가드가
  #    아무것도 검사하지 않은 채 초록이 된다(docs/traps-detail.md 「열거 붕괴 → vacuous green」).
  if [ "$total" -lt 1 ]; then
    _reason "EMPTY: ${VERSIONS_ENV_FILE}에 선언이 0건이다 — '위반 0'이 아니라 열거 붕괴다."
    return 1
  fi
  [ "$bad" -eq 0 ] || return 1
  printf 'versions-read: lint OK — %s 선언 %d건 전부 정본 형태\n' "$VERSIONS_ENV_FILE" "$total"
}

_read_one() {
  local want="$1" out tab tok rest errtok detail
  out="$(awk -v want="$want" "$GRAMMAR"'
    is_skippable($0) { next }
    decl_key($0) == want {
      cand++
      lastno = FNR
      if (is_canon($0)) { canon++; val = canon_value($0) }
    }
    END {
      if (cand + 0 == 0)  { printf "ERR\tKEY_MISSING\t0\n";        exit 0 }
      if (cand + 0 > 1)   { printf "ERR\tDUPLICATE\t%d\n", cand;   exit 0 }
      if (canon + 0 != 1) { printf "ERR\tMALFORMED\t%d\n", lastno; exit 0 }
      printf "OK\t%s\n", val
    }
  ' "$VERSIONS_ENV_FILE")"
  tab="$(printf '\t')"
  tok="${out%%"$tab"*}"
  rest="${out#*"$tab"}"
  case "$tok" in
    OK)
      # ⚠️ 여기가 rc 0의 **유일한** 출구다. 값이 빈 문자열이어도 통과한다 —
      #    "선언된 빈 값"과 "판정 불가"를 가르는 것이 이 리더의 목적 그 자체다.
      printf '%s\n' "$rest"
      return 0 ;;
    ERR)
      errtok="${rest%%"$tab"*}"
      detail="${rest#*"$tab"}"
      case "$errtok" in
        KEY_MISSING) _reason "KEY_MISSING: ${VERSIONS_ENV_FILE}에 ${want} 선언이 없다 — 빈 값이 아니라 판정 불가다." ;;
        DUPLICATE)   _reason "DUPLICATE: ${VERSIONS_ENV_FILE}에 ${want} 선언이 ${detail}건이다 — 어느 것이 정본인지 판정할 수 없다." ;;
        MALFORMED)   _reason "MALFORMED: ${VERSIONS_ENV_FILE}:${detail} ${want} 선언이 정본 형태가 아니다(^export KEY=\"값\"\$ · 값에 \" \$ 백틱 백슬래시 금지)." ;;
        *)           _reason "UNKNOWN: ${VERSIONS_ENV_FILE}의 ${want} 판정이 알 수 없는 상태다(${errtok})." ;;
      esac
      return 1 ;;
    *)
      _reason "UNKNOWN: ${VERSIONS_ENV_FILE}의 ${want}를 읽는 awk가 규약 밖 출력을 냈다 — 판정 불가다."
      return 1 ;;
  esac
}

case "${1:-}" in
  '')
    _reason "USAGE: 읽을 키가 없다 — 사용법: $0 <KEY> | $0 --lint"
    exit 1 ;;
  --lint)
    [ "$#" -eq 1 ] || { _reason "USAGE: --lint는 인자를 받지 않는다."; exit 1; }
    [ -f "$VERSIONS_ENV_FILE" ] || { _reason "FILE_MISSING: ${VERSIONS_ENV_FILE}가 없다 — 검사할 도메인이 없는 것은 '위반 0'이 아니다."; exit 1; }
    _lint || exit 1
    exit 0 ;;
  -*)
    _reason "USAGE: 알 수 없는 옵션 '$1' — 사용법: $0 <KEY> | $0 --lint"
    exit 1 ;;
esac

[ "$#" -eq 1 ] || { _reason "USAGE: 키는 정확히 하나다(받은 인자 $#건) — 사용법: $0 <KEY> | $0 --lint"; exit 1; }
case "$1" in
  *[!A-Za-z0-9_]*|[0-9]*) _reason "USAGE: '$1'은 셸 변수명이 아니다 — 판정할 대상이 없다."; exit 1 ;;
esac
[ -f "$VERSIONS_ENV_FILE" ] || { _reason "FILE_MISSING: ${VERSIONS_ENV_FILE}가 없다 — 파일 부재는 '빈 값'이 아니라 판정 불가다."; exit 1; }
[ -r "$VERSIONS_ENV_FILE" ] || { _reason "FILE_UNREADABLE: ${VERSIONS_ENV_FILE}를 읽을 수 없다 — 판정 불가다."; exit 1; }

_read_one "$1"
