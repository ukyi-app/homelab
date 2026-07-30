#!/usr/bin/env bash
# 자격증명 만료 원장(policy/credential-expiry.json) 검사 — 값(토큰) 없음, {name, expires(YYYY-MM-DD), note}만.
#   --days N          : N일 이내 만료 항목이 있으면 목록 출력 + exit 1 (주간 워크플로가 telegram 경고로 중계)
#   --lint            : 스키마 + 열거 바닥값만 검증 후 exit 0/2
#   --min-entries N   : 항목 수 바닥값(기본 2). 픽스처는 자기 크기에 맞춰 낮춰 쓴다.
# exit: 0=윈도 내 만료 없음/lint OK, 1=만료 임박, 2=인자/원장 형식 오류·열거 붕괴(fail-loud)
#
# ⚠️ **바닥값이 왜 필요한가**: 예전엔 "빈 배열은 vacuous true 허용"을 자기 주석에 선언했다. 그래서 원장이
#    비거나 항목이 조용히 사라져도 "만료 임박 없음"을 출력하고 exit 0이었다 — 이 레포의 다른 모든 가드가
#    가진 열거 붕괴 바닥값이 여기만 없었다(fail-open). 주간 워크플로는 그 초록을 "감시가 돌았고 깨끗하다"로
#    읽는다. 그게 이 가드가 없애려던 바로 그 거짓말이다.
#
# ⚠️ **바닥값 위반은 exit 1이 아니라 2다.** 워크플로(credential-expiry.yaml)는 rc=1을 "만료 임박"으로
#    해석해 「자격증명 만료 임박」 제목의 telegram을 보내고 job은 성공시킨다. 열거 붕괴를 rc=1로 내면
#    **거짓 제목**으로 알림이 나가고 job이 초록으로 남는다. rc≥2만 job을 hard-fail시킨다 — 전제 붕괴는
#    그쪽이 맞다.
#
# ⚠️ **현재 바닥은 무만료(2099 sentinel) 항목이 채운다**(owner 결정 2026-07-30). 즉 이 바닥값이 강제하는
#    것은 "원장이 통째로 사라지지 않았다"이지 "실만료 자격이 빠짐없이 추적된다"가 **아니다**. 후자는
#    실만료 자격의 커밋 가능한 인덱스가 선행돼야 한다(현 SSOT `docs/runbooks/token-inventory.md`는
#    gitignored라 양방향 타이가 불가능하다) — 별건이다. 2099 항목도 "이 자격이 존재한다"는 인벤토리
#    기록이라 소실 자체가 회귀이므로, 그 축만 먼저 닫는다.
#
# bash 3.2 호환: [[ ]]·mapfile 금지(중간 단언은 [ ]/if-블록). jq 필수(CI ubuntu·로컬 brew 존재 — python fallback 금지).
set -euo pipefail
# shellcheck source=scripts/lib/scan-floor.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/scan-floor.sh"
# 기본 원장은 **스크립트 기준**으로 잡는다 — 상대경로면 호출자의 cwd에 의존한다(무인자 실행을
# 레포 밖에서 하면 조용히 "원장 파일 없음"이 된다). `--file`은 호출자 상대 그대로 둔다.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/policy/credential-expiry.json"; DAYS=14; LINT=0; MIN_ENTRIES=2
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --min-entries) MIN_ENTRIES="$2"; shift 2 ;;
    --lint) LINT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq 필요(이 게이트는 jq 전용 — python fallback 금지)" >&2; exit 2; }
[ -f "$FILE" ] || { echo "ERROR: 원장 파일 없음: $FILE" >&2; exit 2; }
# 스키마: 배열 + 각 항목 name(문자열)·expires(YYYY-MM-DD). 위반 시 fail-loud.
jq -e 'type=="array" and all(.[]; (.name|type=="string") and (.expires|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))' \
  "$FILE" >/dev/null 2>&1 || { echo "ERROR: credential-expiry.json 형식 위반(name 문자열·expires YYYY-MM-DD 필수)" >&2; exit 2; }
# 열거 붕괴 바닥값 — 스키마 통과 **뒤**, lint 조기반환 **앞**. `--lint`도 이 판정을 받아야
# "원장이 비었는데 lint OK"가 다시 생기지 않는다.
n="$(jq 'length' "$FILE")"
scan_floor credential-expiry "$n" "$MIN_ENTRIES" || exit 2
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
