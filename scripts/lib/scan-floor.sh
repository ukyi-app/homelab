#!/usr/bin/env bash
# 열거 붕괴 → vacuous green 차단 커널. 가드들이 공유하는 **기계**만 여기 둔다.
#
# 병(라이브 재현): `done < <(enumerator)` **프로세스 치환은 열거자 실패를 `set -euo pipefail`로
# 전파하지 않는다.** 워커가 죽으면 소비자가 0건을 검사하고 성공 메시지를 낸다 —
# 실패하는 `bun` 셰임으로 `check-app-netpol`이 `OK (0 app-owned NetworkPolicy 검사, 위반 0)` + rc=0.
# `check-image-pins`만 바닥값이 있어 이 경로에서 죽었다. 비대칭이 곧 갭이었다.
#
#   scan_enumerate <라벨> <명령...>   열거를 **변수로** 받아 rc를 캡처한다(치환이 삼키던 자리).
#                                     성공: stdout에 결과 · 실패: 진단 + 비-0.
#   scan_floor <라벨> <실제> <하한>    건수 바닥값. 미만이면 진단 + 비-0.
#
# ⚠️ 바닥값 **수치는 소비자가 소유한다.** 열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을 구별할
#    도메인 지식이 없다(`tools/lib/repo-walk.ts`가 scan-floor를 두지 않기로 한 결정과 같은 이유).
#    이 커널은 그 결정을 뒤집지 않는다 — 판정 기계만 공유하고 임계값은 콜사이트에 남긴다.
# ⚠️ **skip 규약(01)과 다른 채널이다.** 저긴 "검사할 도메인이 정당하게 없음"(exit 4 + `SKIP:` 마커)이고,
#    여긴 "열거를 못 했다"는 검증 실패(비-0)다. 마커를 내면 사람이 정반대 뜻으로 읽는다.
# ⚠️ 바닥값은 **래칫이 아니다** — 도메인이 줄지 않는 한 손댈 일이 없다(cf. check-bats-style의 BB_BASELINE은
#    0으로 수렴해야 하는 부채라 성격이 다르다).
# bash 3.2 호환(mapfile 금지 — 콜사이트는 `<<<` 히어스트링으로 순회). shellcheck clean.

# shellcheck shell=bash

scan_enumerate() {
  label="$1"; shift
  _scan_out=""; _scan_rc=0
  _scan_out="$("$@")" || _scan_rc=$?
  if [ "$_scan_rc" -ne 0 ]; then
    echo "FAIL: ${label}: 열거 실패(rc=${_scan_rc}) — 검사 불가. 프로세스 치환이었다면 여기서 조용히 0건이 됐다." >&2
    return 1
  fi
  printf '%s' "$_scan_out"
}

scan_floor() {
  label="$1"; got="$2"; min="$3"
  if [ "$got" -lt "$min" ]; then
    echo "FAIL: ${label}: 스캔 ${got}건 < ${min} — 열거 붕괴 의심(0건 검사 후 초록이 되는 자리)." >&2
    return 1
  fi
  return 0
}

# 줄 수를 센다(빈 문자열=0). `grep -c .`는 0건일 때 rc=1이라 set -e 콜사이트에서 함정이 된다.
scan_count() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c . || true; fi
}
