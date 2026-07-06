#!/usr/bin/env bash
# 자격증명 만료 원장(policy/credential-expiry.json) 검사 — 값(토큰) 없음, {name, expires(YYYY-MM-DD), note}만.
#   --days N  : N일 이내 만료 항목이 있으면 목록 출력 + exit 1 (주간 워크플로가 telegram 경고로 중계)
#   --lint    : 스키마(name 문자열·expires 날짜형식)만 검증 후 exit 0/2
# exit: 0=윈도 내 만료 없음/lint OK, 1=만료 임박, 2=인자/원장 형식 오류(fail-loud)
# bash 3.2 호환: [[ ]]·mapfile 금지(중간 단언은 [ ]/if-블록). jq 필수(CI ubuntu·로컬 brew 존재 — python fallback 금지).
set -euo pipefail
FILE="policy/credential-expiry.json"; DAYS=14; LINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --lint) LINT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq 필요(이 게이트는 jq 전용 — python fallback 금지)" >&2; exit 2; }
[ -f "$FILE" ] || { echo "ERROR: 원장 파일 없음: $FILE" >&2; exit 2; }
# 스키마: 배열 + 각 항목 name(문자열)·expires(YYYY-MM-DD). 위반 시 fail-loud(빈 배열은 vacuous true 허용).
jq -e 'type=="array" and all(.[]; (.name|type=="string") and (.expires|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))' \
  "$FILE" >/dev/null 2>&1 || { echo "ERROR: credential-expiry.json 형식 위반(name 문자열·expires YYYY-MM-DD 필수)" >&2; exit 2; }
if [ "$LINT" -eq 1 ]; then echo "lint OK"; exit 0; fi
now="$(date +%s)"
limit=$(( now + DAYS * 86400 ))
# expires 자정(UTC)의 epoch ≤ limit인 항목만 나열(jq fromdateiso8601은 UTC ISO8601 요구).
expiring="$(jq -r --argjson lim "$limit" '
  .[] | select((.expires + "T00:00:00Z" | fromdateiso8601) <= $lim) | "\(.name) — \(.expires)"' "$FILE")"
if [ -n "$expiring" ]; then
  echo "만료 임박(${DAYS}일 이내) 자격증명:"
  echo "$expiring"
  exit 1
fi
echo "만료 임박 없음(${DAYS}일 윈도)"
