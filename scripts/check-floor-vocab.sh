#!/usr/bin/env bash
# 바닥값 어휘 거부 가드 — 구 어휘의 **재유입**을 정적 red로 만든다(kernel-followups 04).
#
# 병: 01~03·05가 셸 env 15종·--min-* 플래그를 `--floor <도메인>=<n>` 하나로 접었지만, 재유입을
# 막는 것은 관례뿐이었다. env 바닥값이 되살아나도 라벨 집합은 불변이라 로스터 등식·선언⊆방출
# 대조 모두 침묵한다(03 리뷰 실측 — "04가 유일한 문"). 인식 제거는 "안 본다"이고, 필요한 것은
# "있으면 red"다(check-scan-producers와 같은 규율).
#
# 거부 3레인(코드 줄만 — 행두 주석은 스트립):
#   [F] --min-* 플래그 표면(파싱 case·typedFlags value 등록·문자열 리터럴)
#   [E] env 바닥값 읽기 — 셸은 `${…MIN…:-…}` 폴백 동반 확장(상수 정의 MIN_X=n·지역 읽기 "$MIN_X"는
#       비대상 — 03 실측이 그은 선), TS는 process.env.…MIN… 읽기.
#   [C] env **상한** 읽기(같은 두 표기의 MAX) — **가드 파일 안에서만**(아래 도메인 절). 05가 상수로
#       죽인 `BATS_EXCLUDE_MAX`류가 축이다: 가드가 자기 임계값을 호출부에 안 보이는 env로 끈다.
# 대상 밖: `*.bats`(폐지 어휘 거부 증인이 픽스처로 그 어휘를 쓴다 — 05 인계) · 주석 산문.
# 검사 패턴·진단문은 전부 **조립식** — 이 파일 소스에 위반 모양의 연속 리터럴이 없다
# (self-exclusion 소멸, check-skip-signalling 동형). 게이트 bats가 자기-스캔 green을 실증한다.
# ⚠️ **탐지기는 프록시다**(check-scan-producers 동형) — 드리프트 거부가 목적이지 적대 우회 차단이
#    아니다. 보지 않는 것: 변수 조립 플래그명(F="--min"; "$F-scan") · MIN·MAX가 이름에 없는 새 env
#    손잡이(어휘 기반 검출의 정의상 한계 — 신설 손잡이는 리뷰가 잡는다) · 맨 읽기 "$MIN_X"
#    (지역 변수와 구별 불가) · env **주입** 쪽(FOO=0 bash … — 읽기 경로 소멸이 곧 주입 무력화다) ·
#    워크플로 run: 블록(열거 밖 — 실측 0건, 스텝 셸은 .sh 이관 규율이 흡수한다).
# ⚠️ [F]는 폐지 6종이 아니라 **min- 플래그 모양 전부**를 금지한다(의도) — 이름 로스터는 아무도
#    대조하지 않는 목록이 되고, 과다검출은 fail-loud라 조용히 썩지 않는다. 제3자 CLI의 --min-age
#    (rclone)류가 .sh로 들어오면 그 시점에 이 선을 재평가하라.
# ⚠️ [C]가 **가드 파일 한정**인 이유는 실측이다(2026-09-02 tracked 트리, 13 착지 전): `${…MAX…}`
#    폴백 읽기 8곳이 전부 정당한 런타임 파라미터였다 — restore-drill·ensure-role-password의 폴링
#    상한 5곳, digest-exporter 진단문의 curl 상한 인용 1곳, tf-destroy-guard의 ALLOW_MAX 2곳
#    (composite 입력이라 **호출부 워크플로에 보인다**). 병은 "상한이 env에서 온다"가 아니라
#    "**가드가 자기 임계값을** 호출부에 안 보이는 env로 끈다"이므로 도메인을 가드 커널 소비자로
#    좁힌다(셸: guard_init·scan_floor·detect_run / TS: guardMain·takeFloors·scan-floor 임포트 —
#    코드 줄에 한정, 주석 언급은 자격이 아니다). 넓히면 그 8곳이 즉시 오탐이고, 오탐을 면제
#    목록으로 덮으면 목록 자체가 다시 부패 표면이 된다(형제 가드들이 같은 결론을 냈다).
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
  SCOPE_NARROWED=1
  for f in "$@"; do FILES+=("$f"); done
else
  SCOPE_NARROWED=0
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
# [C] 상한 — 표기는 [E]와 동형이고 토큰만 MAX다(경계 규칙도 같다: MAXIMUM·TXMAX는 비대상).
P_SH_CAP='[$][{]([A-Z0-9]+_)*MAX(_[A-Z0-9]+)*(:-|:=|-)'
P_TS_CAP='process[.]env[.]([A-Z0-9]+_)*MAX(_[A-Z0-9]+)*([^A-Z0-9_]|$)'
# 가드 커널 소비자 술어 — 이 토큰이 **코드 줄**에 있는 파일만 [C]의 도메인이다. 셸은 guard.sh의
# 3함수, TS는 scan-floor 커널의 진입점. `grep -l guard_init scripts/*.sh`의 파생 규율과 같은 축이다.
P_GUARD='(guard_init|scan_floor|detect_run|guardMain|takeFloors|scan-floor)'

# 검출기 — 주석 스트립 후 세 레인. READFILES로 detect_run(guard.sh)이 열거수 대조를 진다.
DETECT=""
IFS='' read -r -d '' DETECT <<AWK || true
FNR==1 { pflush(); pfile=FILENAME; plast=0; pn=0; delete qlab; delete slab; nfiles++; inblock=0; isguard=0; mn=0; delete ml; delete mt }
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
# 레인 P: 방출 콜사이트는 **마지막 detect_run보다 뒤**여야 한다. 마커는 "열거·바닥값을 통과했다"는
# 뜻인데 검출기가 죽은 실행은 아무것도 검사하지 못했으므로, 그 실행이 마커를 내면 정반대로 읽힌다.
# ⚠️ **모든** 방출 콜사이트를 본다 — 마지막 마커만 마지막 검출기와 비교하면 이른 방출 하나 뒤에
#    늦은 신호 하나가 있기만 해도 통과한다. 판정만 하는 scan_floor(quiet)는 방출이 아니라 제외한다.
if (\$0 ~ /detect_run[ \\t]/) plast = FNR
else if (\$0 ~ /scan_signal[ \\t]/ || (\$0 ~ /scan_floor[ \\t]/ && \$0 !~ /quiet/)) { pn++; pl[pn]=FNR; pt[pn]=\$0 }
# 레인 Q: quiet 판정은 마커를 내지 않는다 — 그 라벨의 마커는 **뒤에서 반드시** 나가야 한다.
#         짝이 없으면 결합되지 않은 2단계 프로토콜이 되어 그 도메인이 조용히 무증인이 된다.
if (\$0 ~ /scan_floor[ \\t]/ && \$0 ~ /quiet/) { split(\$0, qf, /[ \\t]+/); for (qi in qf) if (qf[qi] ~ /^check-/) { qlab[qf[qi]] = FNR; break } }
if (\$0 ~ /scan_signal[ \\t]/) { split(\$0, sf, /[ \\t]+/); for (si in sf) if (sf[si] ~ /^check-/) { slab[sf[si]] = 1; break } }
# 레인 C의 도메인 판정 — 이 파일이 가드 커널 소비자인가(코드 줄에서만 자격이 선다).
if (\$0 ~ /${P_GUARD}/) isguard = 1
}
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
  # [C]는 **버퍼링**한다 — 도메인(가드 여부)은 파일 전체를 읽어야 정해지므로 판정을 flush로 미룬다.
  cp = ists ? "${P_TS_CAP}" : "${P_SH_CAP}"
  if (match(\$0, cp)) {
    cm = ists ? index(\$0, "//") : index(\$0, "#")
    if (cm == 0 || cm > RSTART) { mn++; ml[mn]=FNR; mt[mn]=\$0 }
  }
}
END { pflush(); printf "READFILES=%d\\n", nfiles > "/dev/stderr" }
function pflush(  i, q) {
if (plast > 0) for (i = 1; i <= pn; i++) if (pl[i] < plast)
  printf "%s:%d: [P] 방출이 검출기보다 앞이다 — 검출기가 죽은 실행이 마커를 낸다(판정만 할 거면 quiet 인자를 주라): %s\\n", pfile, pl[i], pt[i]
if (plast > 0) for (q in qlab) if (!(q in slab))
  printf "%s:%d: [Q] quiet 판정의 짝 신호가 없다 — 이 도메인은 마커를 한 줄도 내지 않는다(라벨 %s): 검출 뒤에서 그 라벨의 신호를 내라 (%s)\\n", pfile, qlab[q], q, q
if (isguard) for (i = 1; i <= mn; i++)
  printf "%s:%d: [C] 가드 임계값의 env off-switch 재유입 — 상한은 상수여야 diff와 리뷰에 보인다(05가 BATS_EXCLUDE_MAX를 그렇게 죽였다): %s\\n", pfile, ml[i], mt[i]
}
AWK

findings="$(detect_run check-floor-vocab "$DETECT" "${FILES[@]}")"
n="$(scan_count "$findings")"

# 신호는 검출 뒤에 낸다(검출이 죽은 실행이 건수를 내면 정반대로 읽힌다 — 형제 규율).
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-floor-vocab; then
  scan_floor check-floor-vocab "${#FILES[@]}" "$(floor_of check-floor-vocab 100)" || exit 1
else
  scan_signal check-floor-vocab "${#FILES[@]}"
fi

if [ "$n" -gt 0 ]; then
  echo "FAIL: 바닥값/상한 어휘 재유입 ${n}곳 — 오버라이드는 --floor 하나, env 바닥값·${D2}min 플래그는 폐지됐고 가드 상한은 상수다(kernel-followups 01~05):" >&2
  printf '%s\n' "$findings" >&2
  exit 1
fi
echo "check-floor-vocab: 구 바닥값 어휘 재유입 0곳 OK"
