#!/usr/bin/env bash
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 산출물(values.yaml·.bindings.json·source-repo)을 강제.
# 필수 파일 목록은 tools/app-deploy-schema.json(.required)에서 읽는다(SSOT — 하드코딩 금지).
# source-repo 누락/공백이면 poll-ghcr가 그 앱을 update-image 폴링에서 영영 빠뜨린다 → fail-closed로 차단.
# 인자로 deploy/prod 디렉토리들을 받으면 그것만, 없으면 apps/*/deploy/prod 전체를 검사(인레포 앱 0개면 vacuous).
# bash 3.2 호환: `cmd && x`(set -e 함정)·mapfile·[[ ]] 금지 — if-블록·for로.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/tools/app-deploy-schema.json"
required="$(jq -r '.required[]' "$SCHEMA")"   # 개행구분 → for 워드분할

rc=0
check_one() {
  d="$1"
  for f in $required; do
    if [ ! -f "$d/$f" ]; then echo "FAIL: $d 에 필수 산출물 '$f' 없음(배포 계약 위반)"; rc=1; fi
  done
  # source-repo는 비어있으면 안 된다(poll-ghcr 발견 경로 — 공백이면 폴링 밖)
  if [ -f "$d/source-repo" ] && [ ! -s "$d/source-repo" ]; then
    echo "FAIL: $d/source-repo 가 비어있음(poll-ghcr가 발견 못 함)"; rc=1
  fi
}

if [ "$#" -gt 0 ]; then
  for d in "$@"; do check_one "$d"; done
else
  cd "$ROOT"
  for d in apps/*/deploy/prod; do
    [ -d "$d" ] || continue   # 인레포 배포앱 0개면 글롭 미매치 → vacuous PASS
    check_one "$d"
  done
fi

if [ "$rc" -eq 0 ]; then echo "check-app-deploy: 배포 계약(values.yaml·.bindings.json·source-repo) OK"; fi
exit $rc
