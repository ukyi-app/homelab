#!/usr/bin/env bash
# 로케일 콜레이션 가드 — 게이트가 오너의 셸 로케일에 따라 **다른 술어를 평가하는** 자리를 잡는다.
#
# 병(라이브 재현 2026-08-20): glibc `en_US.UTF-8`은 구두점·공백을 1차 가중에서 무시한다. 그래서
# `sort -u`가 `-1`과 `1`을, `_create-app.yaml`과 `create-app.yaml`을 **같다고 보고 하나를 버린다.**
#   · `printf -- '-1\n1\n-2\n2\n-9\n9\n' | sort -u` → en_US 3줄 / C 6줄
#   · `git ls-files .github/workflows | sort -u`    → en_US 19 / C 24
#     (삼켜지는 5건이 정확히 `create-app`·`create-cache`·`create-database`·`teardown-app`·
#      `update-secrets` — 이 레포의 `_*.yaml`↔`*.yaml` 네이밍 규약이 곧 붕괴의 모양이다.)
# 그 결과는 거짓 red가 아니라 **fail-open**이었다: `test_sync_wave_ledger.bats`가 원장의 `-1` 행
# 삭제(=실제 드리프트)를 en_US에서 초록으로 통과시켰다. 매니페스트 쪽 `sort -u`가 `-1`을 삼켜
# 그 wave가 루프에 아예 안 들어갔기 때문이다.
#
# ⚠️ **런너 로케일 고정은 이 가드의 대체가 아니다.** 고정하면 개별 결함의 뮤테이션 감도가 죽는다
#    (실측: `Makefile`의 `LC_ALL=C sort`를 되돌려도 C.UTF-8에서는 초록). 고정은 두 venue가 같은
#    술어를 평가하게 만들 뿐이고, "다음 파일에서 또 난다"를 막는 것은 이 정적 스캐너다 —
#    bash 3.2 `$VAR한글` 함정이 쓴 것과 같은 처방(러너가 원리적으로 재현 못 하는 환경 의존은
#    정적 가드로 잡는다). cf. `docs/traps-detail.md` 「로케일 콜레이션이 게이트를 뒤집는다 …」
#
# 규칙(전부 **hard-zero** — waiver 목록 없음. 도입 시점 총 57곳이라 1회 패스로 0에 도달한다):
#   A `sort -u`  : `LC_ALL=C` 접두 또는 숫자 플래그(-n/-g/-h/-V/-R)가 없으면 위반.
#   B 명령 위치 bare `sort` : 동일 규칙.
#   C TS/JS 로케일 API(`localeCompare`·`toLocale*`·`Intl.Collator`) : 결정성이 환경/ICU에 달린다.
# ⚠️ **탐지 자신은 전부 `LC_ALL=C`다** — 가드가 로케일 의존이면 자기 모순이다.
# 인자로 파일을 주면 그 파일만 스캔한다(픽스처/ad-hoc 탐지 모드 — 바닥값 면제, 신호는 낸다).
# bash 3.2 호환: mapfile 금지(while read). shellcheck 클린.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib/scan-floor.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/scan-floor.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES=()
if [ "$#" -gt 0 ]; then FILES=("$@"); else
  while IFS= read -r f; do FILES+=("$f"); done < <(
    git ls-files '*.sh' '*.bats' 'Makefile' '*.ts' '*.mts' '.github/workflows/*.yaml' '.github/actions/*/*.yml'
  )
fi
# ⚠️ 기본 모드의 도메인은 **정당하게 0이 될 수 없다** — 0건은 열거 붕괴다(형제 가드와 같은 규율).
if [ "$#" -eq 0 ]; then
  scan_floor check-locale-collation "${#FILES[@]}" "${LOCALE_MIN_SCAN:-200}" || exit 1
else
  scan_signal check-locale-collation "${#FILES[@]}"
fi

DETECT=""
IFS='' read -r -d '' DETECT <<'AWK' || true
# 단일따옴표 span을 지운다 — yq/jq 표현식 안의 `sort`가 셸 명령으로 오인되지 않게(실측 오탐원 1위).
function code(l){ gsub(/'[^']*'/,"Q",l); return l }
FNR==1 { inhere=0; delim=""; nfiles++ }
# heredoc 본문은 명령이 아니다(형제 check-bats-style.sh와 같은 관용구). 이 가드 자신의 awk 프로그램이
# `<<'AWK'` 본문에 패턴 **리터럴**로 들어 있어, 이게 없으면 검출기가 자기 자신을 위반으로 잡는다.
# ⚠️ 대가: heredoc으로 **스크립트를 생성**하는 자리는 여기서 안 보인다. 그 생성물이 추적 파일이면
#    자기 차례에 검사되고, 아니면 게이트 도메인 밖이라 애초에 이 가드의 관할이 아니다.
{
  if (inhere) { if ($0 ~ ("^[ \t]*"delim"[ \t]*$")) inhere=0; next }
  if (match($0, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
    d=substr($0,RSTART,RLENGTH); gsub(/.*<<-?[ \t]*['"]?/,"",d); delim=d; inhere=1; next
  }
}
/^[ \t]*#/ { next }
/^[ \t]*\/\// { next }
# bats `@test "이름" {` 헤더는 **이름**이지 명령이 아니다 — 이 가드의 테스트가 픽스처 형태를
# 제목에 적는 것이 정상이고, 그걸 위반으로 세면 가드가 자기 회귀 테스트를 금지하게 된다.
/^@test[ \t]/ { next }
{
  c = code($0)
  # yq/jq의 `sort | join(...)` 필터 — 셸 명령이 아니다.
  if (c ~ /sort[ \t]*\|[ \t]*join\(/) next
  # 숫자·버전 정렬은 콜레이션 무관하므로 면제한다.
  if (c ~ /sort[ \t]+-[A-Za-z]*[nghVR]/) next
  if (c ~ /LC_ALL=C[ \t]+sort/) next
  if (c ~ /sort[ \t]+-[A-Za-z]*u/) { printf "%s:%d: [A] %s\n", FILENAME, FNR, $0; next }
  # ⚠️ 후행 문자 클래스에 `)` `}` `|` `&` `;`가 **반드시** 들어간다 — 첫 판이 `sort([ \t]|$)`였고
  #    `| sort)` 형태 10건을 놓쳐 이 레인을 13으로 과소 계수했다(열거 명령 자신의 붕괴).
  if (c ~ /(^|[|(;&{]|\$\()[ \t]*sort([ \t;)}|&]|$)/) { printf "%s:%d: [B] %s\n", FILENAME, FNR, $0; next }
  if (c ~ /localeCompare|toLocale[A-Z]|Intl\.Collator/) printf "%s:%d: [C] %s\n", FILENAME, FNR, $0
}
# 검출기가 **실제로 읽은** 파일 수를 호출자에게 알린다 — 형제 check-host-ports.sh와 같은 계약.
# awk가 중간에 죽어도 SCAN 신호(열거 수)는 그대로 나가므로, 이 축이 없으면 "몇 건을 검사했는가"가 거짓이 된다.
END { printf "READFILES=%d\n", nfiles > "/dev/stderr" }
AWK

# ⚠️ **인자를 먼저 검증한다.** 읽을 수 없는 파일이 awk로 가면 gawk는 fatal로 즉시 죽는데, 예전 코드는
#    그 rc를 `|| true`로 버려 "0곳 OK" rc=0을 냈다 — 가드 본체가 fail-open이었다(형제
#    check-host-ports.sh가 같은 구멍을 닫은 것과 같은 클래스, 2026-08-24 뮤테이션으로 실증).
missing=""
for f in "${FILES[@]}"; do [ -r "$f" ] || missing="${missing} ${f}"; done
[ -z "$missing" ] || { echo "FAIL: check-locale-collation: 읽을 수 없는 대상 —${missing}" >&2; exit 1; }

errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
arc=0
findings="$(awk "$DETECT" "${FILES[@]}" 2>"$errlog")" || arc=$?
if [ "$arc" -ne 0 ]; then
  echo "FAIL: check-locale-collation: 검출기가 실패했다(awk rc=${arc}) — 판정 불가는 '통과'가 아니다." >&2
  cat "$errlog" >&2
  exit 1
fi
# 검출기가 실제로 읽은 파일 수를 열거 수와 대조한다 — SCAN 신호가 "열거한 파일 수"이기만 하면
# 검출이 중간에 무너져도 그 수가 그대로 나가 신호 계약이 깨진다(열거 붕괴 바닥값은 개수만 보므로 못 본다).
read_files="$(sed -n 's/^READFILES=//p' "$errlog" | head -1)"
case "$read_files" in
  '' | *[!0-9]*) echo "FAIL: check-locale-collation: 검출기가 읽은 파일 수를 보고하지 않았다(READFILES 부재) — 끝까지 돌지 않았다." >&2; exit 1 ;;
esac
[ "$read_files" -eq "${#FILES[@]}" ] || {
  echo "FAIL: check-locale-collation: 열거 ${#FILES[@]}파일 != 검출기가 읽은 ${read_files}파일 — 스캔이 중간에 무너졌다." >&2
  exit 1
}
n="$(scan_count "$findings")"
printf '%s\n' "$findings" | grep -E '\[(A|B|C)\]' || true   # gate bats가 레인 태그를 검증
if [ "$n" -gt 0 ]; then
  echo "FAIL: 로케일 콜레이션에 물리는 정렬/비교 ${n}곳 — 셸은 'LC_ALL=C sort'(또는 -n), TS/JS는 코드유닛 비교로." >&2
  exit 1
fi
echo "check-locale-collation: 콜레이션 의존 정렬/비교 0곳 OK"
