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
#   · `bats` 다음 argv를 훑어 **첫 경로꼴 토큰**(`/` 포함 · `.bats` 포함 · `$`로 시작)을 찾되, 그 앞은
#     플래그·플래그값만 허용한다 — `bats -t <path>`·`bats --print-output-on-failure <path>` 같은
#     플래그-선행 호출도 잡는다(2026-09-03: 러너 자신의 표기 `run-bats.sh:67 bats
#     --print-output-on-failure "${SELECTED[@]}"`가 옛 "바로 다음 토큰만" 판정에서 SITES 계상 밖이었다).
#     "bats accounting"·"bats 픽스처가 아니라" 같은 산문은 첫 토큰부터 경로꼴이 아니라 호출이 아니다.
#   · 면제는 파일 목록이 아니라 **그 파일이 `exec 0</dev/null`을 하는가**로 판정한다 — 러너를
#     옮기거나 새 러너를 만들어도 같은 규칙이 성립한다.
# 인자로 파일을 주면 그 파일만 스캔한다(픽스처 모드 — 바닥값 면제, 신호는 낸다).
# bash 3.2 호환(mapfile 금지). shellcheck 클린. ⚠️ 탐지 자신은 `LC_ALL=C`(#514).
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-bats-fd0
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-bats-fd0" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
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
  # ⚠️ 주석뿐 아니라 **코드 줄의 문자열 리터럴**(Makefile echo·워크플로 run 블록의 인용문)도 같은
  #    자리에서 self를 세운다 — `code()`가 못 벗기는 문자열 값이라 위치 무감 판정은 그대로 뚫린다.
  #    그래서 행두 앵커다: 실 면제처(`scripts/run-bats.sh:34`)는 코드 줄 0열에서 시작하고, `code()`가
  #    선행 공백·`@`·행간 주석을 이미 벗기므로 Makefile recipe·워크플로 `run:` 들여쓰기도 그대로 산다.
  if (c ~ /^exec[ \t]+0<[ \t]*\/dev\/null/) self = 1
  if (match(c, /(^|[ \t;&|(){}])bats[ \t]+/)) {
    # 첫 경로꼴 토큰을 찾는다 — 그 앞은 플래그(`-x`/`--x`)와 그 값만 통과시킨다. 플래그도 경로꼴도
    # 아닌 토큰(=산문 단어)을 만나면 그 자리에서 멈춘다(오탐 방지: "bats accounting은 …에 있다").
    n2 = split(substr(c, RSTART + RLENGTH), a2, /[ \t]+/); tok = ""; pf = 0
    for (j = 1; j <= n2; j++) {
      if (a2[j] == "--version") { tok = ""; break }
      if (a2[j] ~ /\// || a2[j] ~ /\.bats/ || a2[j] ~ /^["']?\$/) { tok = a2[j]; break }
      if (a2[j] ~ /^-/) { pf = 1; continue }
      if (pf) { pf = 0; continue }
      break
    }
    if (tok == "") next
    sites++
    if (self) next
    if (c !~ /<[ \t]*\/dev\/null/) {
      printf "%s:%d: [FD0] bats 호출에 `</dev/null`이 없다: %s\n", FILENAME, FNR, $0
    }
  }
}
END { printf "SITES=%d\n", sites > "/dev/stderr" }
AWK

# detect_run-exempt: 바닥값 피연산자가 **파일 수가 아니라 호출면 수(SITES)**다. detect_run은
#   READFILES(=읽은 파일 수)만 보고하고 `READFILES == $#`를 강제하므로, 이 가드가 바닥값에 넣어야
#   하는 수를 커널에서 꺼낼 길이 없다. 파일 수로 바닥을 걸면 정규식이 깨져 호출면을 0개 찾아도
#   그 바닥을 통과한다(무측정 초록) — 그래서 검출기 셸을 손으로 연다.
#   ⚠️ 이 선언은 부채의 **면제**가 아니라 **계상**이다. 커널이 카운터 이름을 인자로 받게 되면
#   (또는 SITES 계약을 흡수하면) 이 사본은 사라져야 한다. 형제 check-scan-producers는 커널과 같은
#   일을 하고 있었을 뿐이라 2026-08-27에 detect_run으로 되돌렸다.
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
if [ "$#" -eq 0 ] || floor_set check-bats-fd0; then
  scan_floor check-bats-fd0 "$sites" "$(floor_of check-bats-fd0 5)" || exit 1
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
