#!/usr/bin/env bash
# 셸 가드 프롤로그/방출 커널 — 규약이 산문 + 정적 대조로만 존재해 가드마다 손 복사되던 것을
# 함수 interface 뒤로 접는다(lib-convergence d2). scan-floor.sh(열거 붕괴 커널)의 형제다.
#
#   guard_init <가드이름>            프롤로그: set -euo pipefail · export LC_ALL=C · ROOT 산출 ·
#                                    scan-floor.sh source. 가드마다 손 복사되던 프롤로그가 이 한
#                                    줄로 수렴한다(비대칭 실측 — `$0` 기반 ROOT·LC_ALL 부분 부착 —
#                                    을 구조로 소멸). 소비자는 세지 않고 파생하라:
#                                    `grep -l guard_init scripts/*.sh`
#   guard_skip <가드> <이유>         `SKIP: <가드>: <이유>` 마커와 exit 4를 **한 줄에서 원자**
#                                    방출한다 — 같은-줄 원자성은 이 구현 줄 하나가 소유하고(정확 1은
#                                    게이트 bats가 잰다), check-skip-signalling은 콜사이트의 직접
#                                    방출을 red로 강제한다(축 교체, 티켓 11). 콜사이트는 짝 규약을
#                                    알 필요가 없다. (TS 레인의 대응물은 tools/lib/cli.ts의 skip().)
#   detect_run <라벨> <awk> <파일…>  awk 검출기의 fail-closed 실행 — 인자 0건/읽기 불가 프리체크 ·
#                                    rc 포착(`|| true`가 fatal을 삼키던 fail-open 봉쇄) ·
#                                    READFILES 열거수 대조(#525가 클래스를 명명하고도 #532에서
#                                    손 복사로 재발한 처방의 lib 수렴). 콜사이트는 awk 프로그램
#                                    본문만 소유하고, 검출기는 END에서
#                                    `printf "READFILES=%d\n", nfiles > "/dev/stderr"`를 내야 한다.
#                                    ⚠️ 호출은 반드시 `var="$(detect_run …)"` **단순 대입**으로 —
#                                    set -e가 rc를 잡는 형태다. `if`/`|| true`로 감싸면 이 커널이
#                                    닫은 fail-open이 콜사이트에서 부활한다.
#
# ⚠️ 함수 안에서 trap EXIT를 걸지 않는다 — source된 lib의 trap은 호출자 트랩을 덮는다.
#    임시 파일은 각 반환 경로에서 명시적으로 지운다.
# bash 3.2 호환(mapfile 금지 · 중간 [[ ]] 금지). shellcheck clean.

# shellcheck shell=bash

guard_init() {
  # shellcheck disable=SC2034  # 소비자 0(2026-08-26 실측) — guard_skip/scan_floor가 라벨을 매번
  # 다시 받는 중복의 수렴 후보로 남긴다(시그니처 변경은 콜사이트 전면 개정이라 별도 티켓 감).
  GUARD_NAME="$1"
  set -euo pipefail
  # 로케일 콜레이션이 게이트를 뒤집는다(#514) — 파일별 export 부착의 비대칭을 전역 export가 소멸시킨다.
  # ⚠️ 콜사이트의 개별 `LC_ALL=C sort` 접두는 **떼지 않는다** — check-locale-collation의 정적
  #    레인은 런타임 export를 원리적으로 못 보므로 그 표기를 계속 강제한다(이중이 계약이다).
  export LC_ALL=C
  # shellcheck disable=SC2034  # 소비자(가드 본문)가 읽는 출력 변수다
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # shellcheck source=scripts/lib/scan-floor.sh
  . "$(dirname "${BASH_SOURCE[0]}")/scan-floor.sh"
}

guard_skip() {
  echo "SKIP: $1: $2"; exit 4
}

detect_run() {
  _dr_label="$1"; _dr_prog="$2"; shift 2
  # 인자 0건이면 awk가 **stdin을 읽는다** — red가 아니라 정지가 된다(bats 스텁 hang과 같은
  # 클래스). 열거가 비었다는 것은 검사한 것이 아니므로 fail-loud다.
  if [ "$#" -eq 0 ]; then
    echo "FAIL: ${_dr_label}: 검사 대상 0건 — 열거가 비었다(검출기를 돌리지 않는다, fail-closed)." >&2
    return 1
  fi
  # 읽을 수 없는 파일이 awk로 가면 gawk는 fatal로 즉시 죽는다 — 인자를 먼저 검증한다.
  _dr_missing=""
  for _dr_f in "$@"; do
    [ -r "$_dr_f" ] || _dr_missing="${_dr_missing} ${_dr_f}"
  done
  [ -z "$_dr_missing" ] || {
    echo "FAIL: ${_dr_label}: 읽을 수 없는 대상 —${_dr_missing}" >&2
    return 1
  }
  _dr_errlog="$(mktemp)"
  _dr_rc=0
  _dr_findings="$(awk "$_dr_prog" "$@" 2>"$_dr_errlog")" || _dr_rc=$?
  if [ "$_dr_rc" -ne 0 ]; then
    echo "FAIL: ${_dr_label}: 검출기가 실패했다(awk rc=${_dr_rc}) — 판정 불가는 '통과'가 아니다." >&2
    cat "$_dr_errlog" >&2
    rm -f "$_dr_errlog"
    return 1
  fi
  # 검출기가 **실제로 읽은** 파일 수를 열거 수와 대조한다 — SCAN 신호가 "열거한 파일 수"이기만
  # 하면 검출이 중간에 무너져도 그 수가 그대로 나가 신호 계약이 깨진다(바닥값은 개수만 본다).
  # 단일 sed(q로 첫 매치 후 종료) — `| head -1` 파이프는 head의 조기 닫힘이 pipefail에 걸려
  # 임시 파일 정리 전에 서브셸을 죽일 수 있는 자리다(trap 금지 규율과 양립하는 유일한 형태).
  _dr_read="$(sed -n '/^READFILES=/{s/^READFILES=//p;q;}' "$_dr_errlog")"
  case "$_dr_read" in
    '' | *[!0-9]*)
      echo "FAIL: ${_dr_label}: 검출기가 읽은 파일 수를 보고하지 않았다(READFILES 부재) — 끝까지 돌지 않았다." >&2
      cat "$_dr_errlog" >&2
      rm -f "$_dr_errlog"
      return 1 ;;
  esac
  if [ "$_dr_read" -ne "$#" ]; then
    echo "FAIL: ${_dr_label}: 열거 $#파일 != 검출기가 읽은 ${_dr_read}파일 — 스캔이 중간에 무너졌다." >&2
    rm -f "$_dr_errlog"
    return 1
  fi
  grep -v '^READFILES=' "$_dr_errlog" >&2 || true
  rm -f "$_dr_errlog"
  printf '%s' "$_dr_findings"
}
