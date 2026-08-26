#!/usr/bin/env bash
# 바닥값 어휘 거부 가드 — 구 어휘의 **재유입**을 정적 red로 만든다(kernel-followups 04).
#
# 병: 01~03·05가 셸 env 15종·--min-* 플래그를 `--floor <도메인>=<n>` 하나로 접었지만, 재유입을
# 막는 것은 관례뿐이었다. env 바닥값이 되살아나도 라벨 집합은 불변이라 로스터 등식·선언⊆방출
# 대조 모두 침묵한다(03 리뷰 실측 — "04가 유일한 문"). 인식 제거는 "안 본다"이고, 필요한 것은
# "있으면 red"다(check-scan-producers와 같은 규율).
#
# 거부 2레인(코드 줄만 — 행두 주석은 스트립):
#   [F] --min-* 플래그 표면(파싱 case·typedFlags value 등록·문자열 리터럴)
#   [E] env 바닥값 읽기 — 셸은 `${…MIN…:-…}` 폴백 동반 확장(상수 정의 MIN_X=n·지역 읽기 "$MIN_X"는
#       비대상 — 03 실측이 그은 선), TS는 process.env.…MIN… 읽기.
# 대상 밖: `*.bats`(폐지 어휘 거부 증인이 픽스처로 그 어휘를 쓴다 — 05 인계) · 주석 산문.
# 검사 패턴·진단문은 전부 **조립식** — 이 파일 소스에 위반 모양의 연속 리터럴이 없다
# (self-exclusion 소멸, check-skip-signalling 동형). 게이트 bats가 자기-스캔 green을 실증한다.
# ⚠️ **탐지기는 프록시다**(check-scan-producers 동형) — 드리프트 거부가 목적이지 적대 우회 차단이
#    아니다. 보지 않는 것: 변수 조립 플래그명(F="--min"; "$F-scan") · MIN이 이름에 없는 새 env
#    손잡이(어휘 기반 검출의 정의상 한계 — 신설 손잡이는 리뷰가 잡는다) · 맨 읽기 "$MIN_X"
#    (지역 변수와 구별 불가) · env **주입** 쪽(FOO=0 bash … — 읽기 경로 소멸이 곧 주입 무력화다) ·
#    워크플로 run: 블록(열거 밖 — 실측 0건, 스텝 셸은 .sh 이관 규율이 흡수한다).
# ⚠️ [F]는 폐지 6종이 아니라 **min- 플래그 모양 전부**를 금지한다(의도) — 이름 로스터는 아무도
#    대조하지 않는 목록이 되고, 과다검출은 fail-loud라 조용히 썩지 않는다. 제3자 CLI의 --min-age
#    (rclone)류가 .sh로 들어오면 그 시점에 이 선을 재평가하라.
# ⚠️ 05 유보 ①의 판단: 마커 없는 두 라벨(audit-orphans:registry 등)의 정적 대조를 이 가드가
#    흡수하지 **않는다** — 이 가드의 축은 "구 어휘 재유입"이지 "라벨 정합"이 아니다(라벨 축은
#    콜사이트 라벨 상수 + --floor 증인 bats가 진다 — 05 Comments).
# bash 3.2 호환(mapfile 금지). shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-floor-vocab
# 바닥값 오버라이드는 공용 어휘 --floor뿐이다 — 이 가드 자신부터(dogfood).
take_floors "check-floor-vocab" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"

FILES=()
if [ "$#" -gt 0 ]; then
  FIXTURE=1
  for f in "$@"; do FILES+=("$f"); done
else
  FIXTURE=0
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.sh' '*.ts' '*.mts' 'Makefile')
fi

# 조립 토큰 — \x2d 류 이스케이프는 쓰지 않는다(GNU grep ERE에서 리터럴 x — 11 실측 함정).
D2='--'
P_FLAG="${D2}min-[a-z]"                          # [F] 두 언어 공통(플래그 이름은 코드 리터럴로만 정당하지 않다)
# MIN은 `_` 경계 토큰이다 — 부분문자열 매치는 ADMIN·MINIO·TERMINATION을 오탐한다(리뷰 실측).
# 폴백은 3형(`:-`·`-`·`:=`) 전부 — 병의 근거는 "미설정일 수 있다 = 환경에서 온다"이지 `:-`라는
# 글자가 아니다(맨 읽기 `"$MIN_X"`는 지역 변수와 구별 불가라 비대상 — 프록시 한계 절 참고).
# 특수문자는 문자 클래스([$]·[{]·[.])로 리터럴화한다 — 백슬래시는 셸→heredoc→awk 문자열→동적
# 정규식의 4층을 지나며 층마다 한 겹씩 벗겨져 이스케이프 계산이 반드시 드리프트한다(구현 실측).
P_SH_ENV='[$][{]([A-Z0-9]+_)*MIN(_[A-Z0-9]+)*(:-|:=|-)'   # [E] 셸 — 폴백 동반 확장 읽기
P_TS_ENV='process[.]env[.]([A-Z0-9]+_)*MIN(_[A-Z0-9]+)*([^A-Z0-9_]|$)'   # [E] TS — env 읽기(끝 경계)

# 검출기 — 주석 스트립 후 두 레인. READFILES로 detect_run(guard.sh)이 열거수 대조를 진다.
DETECT=""
IFS='' read -r -d '' DETECT <<AWK || true
FNR==1 { nfiles++; inblock=0 }
{
  # 주석 표면(scan-producers 규율 승계): 행두 # · // — 그리고 TS 블록 주석은 행두 /*만 상태 진입
  # (줄 중간 /*는 글롭 문자열에 흔해 파일 잔부를 통째로 삼킨다 — 형제 헤더의 실측),
  # 꼬리 주석은 매치 위치가 주석 시작보다 뒤면 제외한다.
  if (inblock) { if (index(\$0, "*/") > 0) inblock = 0; next }
  if (\$0 ~ /^[ \\t]*\\/\\*/) { if (index(\$0, "*/") == 0) inblock = 1; next }
}
/^[ \\t]*#/ { next }
/^[ \\t]*\\/\\// { next }
{
  ists = (FILENAME ~ /\\.(ts|mts)\$/)
  if (match(\$0, /${P_FLAG}/)) {
    cm = ists ? index(\$0, "//") : index(\$0, "#")
    if (cm == 0 || cm > RSTART) { printf "%s:%d: [F] 구 min- 플래그 어휘 재유입 — 바닥값 오버라이드는 --floor <도메인>=<n> 하나다: %s\\n", FILENAME, FNR, \$0; next }
  }
  ep = ists ? "${P_TS_ENV}" : "${P_SH_ENV}"
  if (match(\$0, ep)) {
    cm = ists ? index(\$0, "//") : index(\$0, "#")
    if (cm == 0 || cm > RSTART) printf "%s:%d: [E] env 바닥값 읽기 재유입 — env는 호출부에 보이지 않는 채로 바닥값을 끈다: %s\\n", FILENAME, FNR, \$0
  }
}
END { printf "READFILES=%d\\n", nfiles > "/dev/stderr" }
AWK

findings="$(detect_run check-floor-vocab "$DETECT" "${FILES[@]}")"
n="$(scan_count "$findings")"

# 신호는 검출 뒤에 낸다(검출이 죽은 실행이 건수를 내면 정반대로 읽힌다 — 형제 규율).
if [ "$FIXTURE" -eq 0 ] || floor_set check-floor-vocab; then
  scan_floor check-floor-vocab "${#FILES[@]}" "$(floor_of check-floor-vocab 100)" || exit 1
else
  scan_signal check-floor-vocab "${#FILES[@]}"
fi

if [ "$n" -gt 0 ]; then
  echo "FAIL: 바닥값 어휘 재유입 ${n}곳 — 오버라이드는 --floor 하나, env·${D2}min 플래그는 폐지됐다(kernel-followups 01~05):" >&2
  printf '%s\n' "$findings" >&2
  exit 1
fi
echo "check-floor-vocab: 구 바닥값 어휘 재유입 0곳 OK"
