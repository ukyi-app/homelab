#!/usr/bin/env bash
# 가드 skip 신호 규약의 정적 가드 — `CONTRIBUTING.md` '가드 skip 신호' 절 + `tools/lib/cli.ts` 주석이 SSOT.
#
# 축(lib-convergence 11): 검사는 "마커와 skip 종료코드(4)가 같은 줄"이 아니라 **헬퍼를 경유했는가**다.
# 같은-줄 원자성은 이제 구현 두 곳이 소유한다 — 셸 `guard_skip`(scripts/lib/guard.sh) ·
# TS `skip()`(tools/lib/cli.ts). 그러므로 콜사이트의 직접 방출(skip 종료코드든 SKIP 마커 emission이든)은
# 짝이 맞아도 위반이다: 손조립이 하나라도 살아 있으면 원자성 주장이 그 콜사이트에서 두 번째 진실을 얻는다.
# Makefile만 함수를 쓸 수 없어 옛 같은-줄 짝 검사로 잔존한다(## 도움말 꼬리 절단 포함).
#
# 대상 = 추적 셸/TS/Makefile. 열거는 git — 하드코딩 글롭이 리네임에 조용히 0매치되는 것을 피한다.
# 인자를 주면 그 파일만 검사한다(픽스처/ad-hoc 모드). `*.bats`는 대상 밖(단언문이 토큰을 정상 포함).
#
# ⚠️ 주석 줄은 대상 밖 — 규약을 설명하는 산문이 곳곳에 있다.
# ⚠️ self-exclusion은 없다 — 이 파일의 검사 패턴은 전부 **조립식**이라 소스에 위반 모양의 연속
#    리터럴이 존재하지 않는다(옛 판은 awk 패턴 리터럴이 위반과 같은 모양이라 자신을 제외해야 했고,
#    그 제외가 곧 아무도 대조하지 않는 주장이었다).
# ⚠️ 이 가드도 같은 병에 걸릴 수 있다: 열거가 무너져 0건을 스캔해도 '위반 0'과 똑같이 빈 출력이다.
#   그래서 기본 모드엔 스캔 바닥값을 둔다(`check-image-pins.sh`·`check-alert-rules.ts` 선례).
# ⚠️ **탐지기는 프록시다**(check-scan-producers 동형) — 드리프트를 잡는 것이지 적대 우회를 막는
#    것이 아니다. 보지 않는 것: 변수 경유 종료코드(`rc=4; exit "$rc"` · `return 4` — 실 트리에
#    sealing-key-dr-gate.sh 등 rc-변수 관용구가 정당하게 존재한다 — homelab CLI의 skip variant도
#    이 클래스: 종료코드가 envelope.exitCode **데이터**로 흘러 어떤 리터럴 패턴에도 안 잡히고,
#    그래도 되는 이유는 값이 손조립이 아니라 exitFor(variant) 계약 파생이기 때문이다), `exit 04` 표기.
# (해소) 옛 판이 '알려진 구멍'으로 등재하던 TS exitCode(process 필드)에 4를 직접 대입하는 경로는 skip variant
#    구현(kernel-followups 06)과 함께 전용 레인으로 닫았다 — CLI 마커(SKIP: homelab <verb>:)의
#    방출도 헬퍼(cli.ts skipMarker) 소유이고 P_EMIT이 콜사이트 직접 방출을 거부한다(stderr 동사 포함).
# bash 3.2 호환(mapfile 금지). shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-skip-signalling
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-skip-signalling" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
cd "$ROOT"

# ⚠️ 현재 건수를 여기 적지 않는다 — 손 관리 수치는 드리프트한다(check-scan-producers 규율).
#    현재값은 SCAN 마커를 읽어라. 오버라이드는 --floor(위 take_floors)뿐이다.
MIN_SCAN="$(floor_of check-skip-signalling 100)"

# 유일 구현체(방출 정당 보유처) — 헬퍼 자신은 원자 방출 줄 하나를 가진다(정확 1은 게이트 bats가 잰다).
HELPER_SH="scripts/lib/guard.sh"
HELPER_TS="tools/lib/cli.ts"

# 검사 토큰은 전부 조립식(위 self-exclusion 소멸 주석 참고).
# ⚠️ 이식성: \xHH는 PCRE/ugrep 확장이지 POSIX ERE가 아니다 — GNU grep은 리터럴 'x'로 읽어
#    그 레인이 영구 무매치가 된다(리뷰 실측 — traps의 `grep -P` 항목과 같은 클래스). 괄호는 \(로.
# ⚠️ 브래킷 안에 \n 이스케이프는 없다 — [^\n]은 '역슬래시·n 제외'라 printf "%s\n"의 n에 걸려
#    지배적 관용구가 우회 통로였다(리뷰 실측). grep은 행 단위라 .*가 정확하다.
T_EXIT="exit"
P_SH_EXIT="${T_EXIT} 4([^0-9]|\$)"             # 셸 skip 종료코드 직접 방출
P_TS_EXIT="process\\.${T_EXIT}\\(4\\)"         # TS skip 종료코드 직접 방출
# TS 종료코드 손조립의 두 번째 얼굴 — exitCode에 4를 **직접 대입**하면 exit(4) 패턴 밖이다
# (variant 파생값·변수 경유 대입은 리터럴 4가 아니라서 이 레인 밖 — 정당).
P_TS_EXITCODE="process\.${T_EXIT}Code[[:space:]]*=[[:space:]]*4([^0-9]|\$)"
T_MARK="SKIP"
# 동사 목록에 console.error·process.std{out,err}.write 포함 — homelab CLI 계약이 stderr 마커를
# 규정하므로 stdout 동사만 보면 그 레인이 통째로 밖이다(리뷰 실측 — 채널이 아니라 방출이 선이다).
# 따옴표 클래스는 3종 전부 — 백틱이 빠지면 템플릿 리터럴 방출이 통째로 밖이고, CLI 계약 마커
# (SKIP: homelab <verb>:)는 보간이 필수인 모양이라 정확히 그 구멍을 부른다(06 리뷰 실측 —
# console.warn도 같은 스윕에서 편입).
T_Q_CLS='"'"'"'`'   # dquote·squote·backtick — 작은따옴표 연결 조립(백틱을 큰따옴표에 두면 커맨드 치환)
P_EMIT="(echo|printf|console\\.(log|error|warn)|process\\.(stdout|stderr)\\.write).*[${T_Q_CLS}][^${T_Q_CLS}]*${T_MARK}:"   # 따옴표 리터럴 안 마커의 emission

SCOPE_NARROWED=0
FILES=()
if [ "$#" -gt 0 ]; then
  SCOPE_NARROWED=1
  for f in "$@"; do FILES+=("$f"); done
else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.sh' '*.ts' '*.mts')
  FILES+=("Makefile")
fi

# Makefile 잔존 레인 — 옛 같은-줄 짝 검사(패턴은 -v로 주입해 이 파일에 리터럴을 남기지 않는다).
scan_makefile() {
  awk -v F="$1" -v pexit="${T_EXIT} 4([^0-9]|$)" -v pmark="${T_MARK}:" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/##.*$/, "", line)   # 도움말 꼬리(`## …`)는 주석이다 — 자르지 않으면 도움말 언급이 오탐
      hasExit = (line ~ pexit)
      hasMark = 0
      mi = index(line, pmark)
      if (mi > 0 && line ~ /(echo|printf)/) {
        pre = substr(line, 1, mi - 1)
        if (index(pre, "\042") > 0 || index(pre, "\047") > 0) hasMark = 1
      }
      if (hasExit && !hasMark) print F":"FNR": skip 종료코드인데 SKIP 마커 없음(Makefile 짝 레인): "$0
      if (hasMark && !hasExit) print F":"FNR": SKIP 마커인데 skip 종료코드 아님(Makefile 짝 레인): "$0
    }
  ' "$1"
}

# 레인 grep 하나의 fail-closed 실행 — rc 0/1(매치/무매치)만 정상, rc>=2는 검출기 사망이다.
# `|| true`는 그 둘을 구별하지 못해 사망이 '위반 0'으로 읽힌다(detect_run과 같은 처방 — 여기 검출은
# 파일당 개별 grep이라 READFILES 축은 부적용이고, rc 포착이 그 자리를 진다).
lane_grep() {   # $1=패턴 $2=입력 — 매치 줄을 stdout으로, 사망은 fail-loud return 1
  _lg_rc=0
  _lg_out="$(grep -nE "$1" <<<"$2")" || _lg_rc=$?
  if [ "$_lg_rc" -ge 2 ]; then
    echo "FAIL: check-skip-signalling: 검출기가 실패했다(grep rc=${_lg_rc}) — 판정 불가는 '통과'가 아니다." >&2
    return 1
  fi
  if [ -n "$_lg_out" ]; then printf '%s\n' "$_lg_out"; fi
  return 0
}

# 셸/TS 레인 — 직접 방출 자체가 위반이다(헬퍼 경유 강제). 행두 주석만 걷는다(옛 판과 동일 도메인).
scan_one() {
  # basename 판별 — 경로 어딘가에 Makefile이 든 .sh/.ts가 약한 짝 레인으로 새지 않게 한다.
  case "${1##*/}" in
    Makefile|Makefile.*) scan_makefile "$1"; return ;;   # 픽스처(Makefile.ok 등)도 이 레인 — 실 트리는 Makefile 하나다.
                                                         # bare return: awk 사망 rc가 그대로 전파된다(fail-loud).
  esac
  ists=0
  case "$1" in *.ts|*.mts) ists=1 ;; esac
  if [ "$ists" -eq 1 ]; then
    stripped="$(sed -E 's|^[[:space:]]*//.*||' "$1")"
    pexit="$P_TS_EXIT"
    helper="skip()"
  else
    stripped="$(sed -E 's|^[[:space:]]*#.*||' "$1")"
    pexit="$P_SH_EXIT"
    helper="guard_skip"
  fi
  hits="$(lane_grep "$pexit" "$stripped")" || return 1
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$1:|; s|\$| — skip 종료코드(4) 직접 방출: ${helper}를 경유하라(원자성은 헬퍼 구현이 소유한다)|"
  fi
  hits="$(lane_grep "$P_EMIT" "$stripped")" || return 1
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$1:|; s|\$| — SKIP 마커 직접 방출: ${helper}를 경유하라(원자성은 헬퍼 구현이 소유한다)|"
  fi
  if [ "$ists" -eq 1 ]; then
    hits="$(lane_grep "$P_TS_EXITCODE" "$stripped")" || return 1
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits" | sed "s|^|$1:|; s|\$| — skip 종료코드(4) 직접 대입: 종료코드는 variant 축(exitFor 파생)이 소유한다 — 가드는 skip(), CLI는 skip variant 경로|"
    fi
  fi
  return 0
}

scanned=0
viol=""
for f in "${FILES[@]}"; do
  # 부재 파일은 red다 — continue로 건너뛰면 게이트 픽스처의 경로 오타가 '0건 스캔 초록'이 된다
  # (기본 모드에서도 tracked인데 워킹 트리에 없으면 검사하지 않은 파일이다 — fail-closed).
  [ -f "$f" ] || { echo "FAIL: check-skip-signalling: 읽을 수 없는 대상 — $f" >&2; exit 1; }
  case "$f" in
    "$HELPER_SH"|"$HELPER_TS") scanned=$((scanned + 1)); continue ;;   # 구현체 — 방출의 정당 보유처(정확 1은 게이트 bats가 잰다)
  esac
  scanned=$((scanned + 1))
  out="$(scan_one "$f")"
  if [ -n "$out" ]; then viol="${viol}${out}"$'\n'; fi
done

# 신호는 검출 뒤에 낸다(check-scan-producers와 같은 순서) — 검출이 죽은 실행이 "N건"을 내면
# 소비자가 정반대로 읽는다. 바닥값·마커는 손조립하지 않고 커널(scan-floor.sh)을 태운다.
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-skip-signalling; then
  scan_floor check-skip-signalling "$scanned" "$MIN_SCAN" || exit 1
else
  scan_signal check-skip-signalling "$scanned"
fi

rc=0
if [ -n "$viol" ]; then
  echo "FAIL: 가드 skip 신호 규약 위반 — 방출은 헬퍼(guard_skip / skip()) 경유만, Makefile은 같은-줄 짝:" >&2
  printf '%s' "$viol" >&2
  rc=1
fi
# scanned는 **열거** 수다 — 구현체 2건은 세되 스캔하지 않으므로 문구도 그렇게 말한다.
if [ "$rc" -eq 0 ]; then echo "check-skip-signalling: skip 신호 헬퍼-경유 OK (열거 ${scanned}건 · 구현체 2건 제외 스캔)"; fi
exit "$rc"
