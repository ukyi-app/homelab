#!/usr/bin/env bash
# bats 호출면의 `</dev/null` 규약 가드 — 러너 밖에서 bats를 부르는 자리는 fd 0을 끊어야 한다.
#
# 병(실측, PR #520): bats는 stdin을 만지지 않고 @test에 그대로 물려준다. @test 안의 스텁이 피연산자
# 없이 fd 0을 읽으면(`cat`처럼) **호출자의 stdin에서 영원히 블록한다** — 실패도 출력도 없는 hang이다.
# 이전 세션이 그 형태로 **1시간 39분**을 태웠다.
# ⚠️ 더 나쁜 것은 venue가 갈린다는 점이다: `ci.yaml`은 러너를 `&`로 띄우는데 비대화형 bash의 async
#    명령은 fd 0이 `/dev/null`이라 **CI는 우연히 면역**이다. `make ci`는 포그라운드라 호출자 fd 0을
#    물려받는다. ⇒ **로컬만 밟고 CI는 영원히 초록**인 클래스라 사후에 드러나지 않는다.
#
# `scripts/run-bats.sh`는 스스로 `exec 0</dev/null`을 하므로 그 안의 호출은 면제다. 나머지 호출면
# (Makefile·워크플로·다른 스크립트)은 호출 줄에 `</dev/null`을 붙여야 한다. AGENTS.md와 run-bats.sh
# 헤더가 그 규약을 **선언**하지만 도입 전까지 강제하는 것은 아무것도 없었다 — 현재 호출면이 전부
# 준수하는 지금이 hard-zero로 못박을 자리다.
#
# 판별(오탐을 내면 아무도 이 가드를 안 켠다):
#   · 줄 머리 주석 · Makefile `##` 도움말 · 행간 주석 · YAML `name:` 줄은 명령이 아니다.
#   · `bats --version`은 테스트 실행이 아니다.
#   · `bats` 다음 토큰이 **경로꼴**(`/` 포함 · `.bats` 포함 · `$`로 시작)일 때만 호출로 본다.
#     "bats accounting"·"bats 픽스처가 아니라" 같은 산문은 호출이 아니다.
#   · 면제는 파일 목록이 아니라 **그 파일이 `exec 0</dev/null`을 하는가**로 판정한다 — 러너를
#     옮기거나 새 러너를 만들어도 같은 규칙이 성립한다.
# 인자로 파일을 주면 그 파일만 스캔한다(픽스처 모드 — 바닥값 면제, 신호는 낸다).
# bash 3.2 호환(mapfile 금지). shellcheck 클린. ⚠️ 탐지 자신은 `LC_ALL=C`(#514).
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib/scan-floor.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/scan-floor.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  enumerated="$(scan_enumerate check-bats-fd0 git ls-files 'Makefile' '.github/workflows/*.yaml' '*.sh')" || exit 1
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<EOF
$enumerated
EOF
fi
missing=""
for f in "${FILES[@]}"; do [ -r "$f" ] || missing="${missing} ${f}"; done
[ -z "$missing" ] || { echo "FAIL: check-bats-fd0: 읽을 수 없는 대상 —${missing}" >&2; exit 1; }

DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
function code(l) {
  sub(/^[ \t]*@?/, "", l)          # Makefile recipe의 `@` 접두
  sub(/##.*$/, "", l)              # Makefile 도움말
  sub(/[ \t]#[ \t].*$/, "", l)     # 셸/YAML 행간 주석
  return l
}
FNR==1 { nfiles++; self = 0 }
/^[ \t]*#/            { next }
/^[ \t]*-?[ \t]*name:/ { next }
{
  c = code($0)
  # 파일이 스스로 fd 0을 끊으면 그 안의 호출은 면제다(파일 목록이 아니라 사실로 판정한다).
  # ⚠️ **이 판정은 주석을 벗긴 뒤에 해야 한다.** 앞서는 이 규칙이 주석·`name:` 스킵보다 **위**에 있어서,
  #    `# 규약: exec 0</dev/null 을 한다` 같은 설명 한 줄·Makefile `##` 도움말·워크플로 스텝 이름만으로도
  #    self=1이 서서 **그 파일 전체가 면제**됐다(실측). 가드 자신도 자기 헤더가 그 규약을 설명하므로
  #    영구 면제 상태였다 — hard-zero 보증이 그대로 거짓이 된다.
  if (c ~ /exec[ \t]+0<[ \t]*\/dev\/null/) self = 1
  if (match(c, /(^|[ \t;&|(){}])bats[ \t]+[^ \t]+/)) {
    tok = substr(c, RSTART, RLENGTH)
    sub(/.*bats[ \t]+/, "", tok)
    if (tok == "--version") next
    if (tok !~ /\//  && tok !~ /\.bats/ && tok !~ /^["']?\$/) next
    sites++
    if (self) next
    if (c !~ /<[ \t]*\/dev\/null/) {
      printf "%s:%d: [FD0] bats 호출에 `</dev/null`이 없다: %s\n", FILENAME, FNR, $0
    }
  }
}
END { printf "SITES=%d\n", sites > "/dev/stderr" }
AWK

errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
arc=0
findings="$(awk "$DETECT" "${FILES[@]}" 2>"$errlog")" || arc=$?
if [ "$arc" -ne 0 ]; then
  echo "FAIL: check-bats-fd0: 검출기가 실패했다(awk rc=${arc}) — 판정 불가는 '통과'가 아니다." >&2
  cat "$errlog" >&2
  exit 1
fi
sites="$(sed -n 's/^SITES=//p' "$errlog" | head -1)"
case "$sites" in '' | *[!0-9]*) echo "FAIL: check-bats-fd0: 검출기가 호출면 수를 보고하지 않았다." >&2; exit 1 ;; esac

# ⚠️ 바닥값의 대상은 **파일 수가 아니라 호출면 수**다. 파일은 수백 개인데 bats 호출면은 한 자리라,
#    파일 수로 바닥을 걸면 정규식이 깨져 호출면을 0개 찾아도 그 바닥을 통과한다(무측정 초록).
if [ "$#" -eq 0 ]; then
  scan_floor check-bats-fd0 "$sites" "${BATSFD0_MIN_SITES:-5}" || exit 1
else
  scan_signal check-bats-fd0 "$sites"
fi

n="$(scan_count "$findings")"
printf '%s\n' "$findings" | grep -F '[FD0]' || true   # gate bats가 레인 태그를 검증
if [ "$n" -gt 0 ]; then
  echo "FAIL: fd 0을 끊지 않는 bats 호출 ${n}곳 — 호출 줄에 \`</dev/null\`을 붙여라(스텁이 호출자 stdin에서 영구 블록한다)." >&2
  exit 1
fi
echo "check-bats-fd0: 러너 밖 bats 호출면 ${sites}곳 전건 fd 0 격리 OK"
