#!/usr/bin/env bash
# 가드 skip 신호 규약의 정적 가드 — `CONTRIBUTING.md` '가드 skip 신호' 절 + `tools/lib/cli.ts` 주석이 SSOT.
#
# 규약: 도메인 부재로 불변식을 평가하지 못하면 `SKIP: <가드>: <이유>` 마커와 skip 종료코드(4)를
# **같은 줄**에서 낸다. 같은 줄 강제는 짝을 여기서 정적으로 검증할 수 있게 하려는 제약이다.
# 잡는 것: (a) skip 종료코드인데 마커가 없다(사람·CI가 이유를 못 읽는다),
#          (b) 마커인데 skip 종료코드가 아니다(호출자에겐 여전히 성공으로 보인다 — 이 티켓의 원래 병).
#
# 대상 = 추적 셸/Makefile(`exit 4`) + 추적 TS(`process.exit(4)`). 열거는 git — 하드코딩 글롭이
# 리네임에 조용히 0매치되는 것을 피한다. 인자를 주면 그 파일만 검사한다(픽스처/ad-hoc 모드).
# `*.bats`는 대상 밖: 단언문이 이 토큰들을 정상적으로 포함한다(`[ "$status" -eq 4 ]` 등).
#
# ⚠️ 주석 줄은 대상 밖 — 규약을 설명하는 산문이 곳곳에 있다. Makefile의 `## 도움말` 꼬리도 주석이라 잘라낸다
#   (자르지 않으면 도움말에 `SKIP:`를 쓰는 순간 오탐 — 눈에 안 보이는 함정이 된다).
# ⚠️ 자기 자신은 대상 밖 — 아래 awk의 패턴 리터럴이 규약 위반과 똑같은 모양이다. 로직의 생존은
#   `tests/gates/test_guard-skip-signalling.bats`의 양방향 mutation 테스트가 실측한다.
# ⚠️ 이 가드도 같은 병에 걸릴 수 있다: 열거가 무너져 0건을 스캔해도 '위반 0'과 똑같이 빈 출력이다.
#   그래서 기본 모드엔 스캔 바닥값을 둔다(`check-image-pins.sh`·`check-alert-rules.ts` 선례).
# bash 3.2 호환(mapfile 금지). shellcheck clean.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SELF="scripts/check-skip-signalling.sh"
MIN_SCAN="${SKIP_SIGNAL_MIN_SCAN:-70}"   # 현재 대상 ~89건(추적 .sh 51 + .ts 36 + .mts 2 + Makefile − self).

FIXTURE=0
FILES=()
if [ "$#" -gt 0 ]; then
  FIXTURE=1
  for f in "$@"; do FILES+=("$f"); done
else
  while IFS= read -r f; do
    case "$f" in "$SELF") continue ;; esac
    FILES+=("$f")
  done < <(git ls-files '*.sh' '*.ts' '*.mts')
  FILES+=("Makefile")
fi

# 한 파일의 짝 위반을 stdout으로. 언어별로 주석 접두와 skip 종료코드 표기가 다르다.
scan_one() {
  ists=0; ismk=0
  case "$1" in *.ts|*.mts) ists=1 ;; esac
  case "$1" in */Makefile|Makefile) ismk=1 ;; esac
  awk -v F="$1" -v ISTS="$ists" -v ISMK="$ismk" '
    ISTS  && /^[[:space:]]*\/\// { next }
    !ISTS && /^[[:space:]]*#/    { next }
    {
      line = $0
      # ⚠️ `##` 절단은 **Makefile 도움말 꼬리 전용**이다. 셸에서 `##`는 파라미터 확장(`${f##*/}`)·
      # sed 구분자로 정상 쓰이므로, 무차별 적용하면 그런 줄의 skip 종료코드가 통째로 잘려
      # **위반이 조용히 통과**한다(이 가드가 막으려는 바로 그 병 — 리뷰가 실측으로 잡았다).
      if (ISMK) sub(/##.*$/, "", line)
      if (ISTS) hasExit = (line ~ /process\.exit\(4\)/)
      else      hasExit = (line ~ /exit 4([^0-9]|$)/)
      # 마커 쪽은 **낼 때**만 짝을 요구한다 — 출력 동사가 있어야 emission이다. 없으면 그건 마커를
      # 다루는 코드(정규식·패턴 상수)이지 skip 신호가 아니다. 이 구분이 없으면 규약을 구현하는
      # 파일마다 자기 자신을 제외 목록에 넣어야 하고, 그 목록이 곧 아무도 대조하지 않는 주장이 된다.
      hasMark = (line ~ /SKIP:/ && line ~ /(echo|printf|console\.log)/)
      if (hasExit && !hasMark) print F":"FNR": skip 종료코드인데 SKIP 마커 없음: "$0
      if (hasMark && !hasExit) print F":"FNR": SKIP 마커인데 skip 종료코드 아님: "$0
    }
  ' "$1"
}

scanned=0
viol=""
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  out="$(scan_one "$f")"
  if [ -n "$out" ]; then viol="${viol}${out}"$'\n'; fi
done

rc=0
if [ -n "$viol" ]; then
  echo "FAIL: 가드 skip 신호 규약 위반 — 마커와 종료코드는 같은 줄에서 짝을 이뤄야 한다:" >&2
  printf '%s' "$viol" >&2
  rc=1
fi
if [ "$FIXTURE" -eq 0 ] && [ "$scanned" -lt "$MIN_SCAN" ]; then
  echo "FAIL: 스캔 대상 ${scanned}건 < ${MIN_SCAN} — 열거 붕괴(이 가드가 vacuous해진다)" >&2
  rc=1
fi
if [ "$rc" -eq 0 ]; then echo "check-skip-signalling: skip 마커↔종료코드 짝 OK (${scanned}건 스캔)"; fi
exit "$rc"
