#!/usr/bin/env bash
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 산출물(values.yaml·.bindings.json·source-repo·kustomization.yaml)을 강제.
# 필수 파일 목록은 tools/app-deploy-schema.json(.required)에서 읽는다(SSOT — 하드코딩 금지).
# source-repo 누락/공백이면 poll-ghcr가 그 앱을 update-image 폴링에서 영영 빠뜨린다 → fail-closed로 차단.
# 또한 <app>-secrets.sealed.yaml이 있으면 sha256(원본 바이트) 앞 16자 == values.yaml checksum/secrets 정합을
# 강제한다(#277 재발 방지 — 재봉인 후 checksum 미갱신이면 envFrom secretRef 변경이 파드를 롤링 못 함).
# 인자로 deploy/prod 디렉토리들을 받으면 그것만, 없으면 apps/*/deploy/prod 전체를 검사(인레포 앱 0개면 vacuous).
# bash 3.2 호환: `cmd && x`(set -e 함정)·mapfile·[[ ]] 금지 — if-블록·for로.
# 현재 인레포 앱(page·trip-mate-api)은 각 봉인본 1개 — 앱당 <app>-secrets.sealed.yaml 단일 규약.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/tools/app-deploy-schema.json"
required="$(jq -r '.required[]' "$SCHEMA")"   # 개행구분 → for 워드분할

# 로컬(macOS shasum) ↔ CI(리눅스 sha256sum) 양립. yq는 버전차 함정이라 값 추출은 sed로.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

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
  # checksum/secrets ↔ 봉인본 정합: 앱 이름은 deploy/prod의 조부모 디렉토리명(apps/<app>/deploy/prod).
  app="$(basename "$(dirname "$(dirname "$d")")")"
  sealed="$d/$app-secrets.sealed.yaml"
  if [ -f "$sealed" ] && [ -f "$d/values.yaml" ]; then
    # values.yaml에서 checksum/secrets 16진값만 추출(단순 sed — grep -v '^---$' 류 yq 함정 회피).
    want="$(sed -n -E 's/^[[:space:]]*checksum\/secrets:[[:space:]]*([0-9a-fA-F]+).*/\1/p' "$d/values.yaml")"
    if [ -z "$want" ]; then
      echo "FAIL: $d 에 $app-secrets.sealed.yaml 있으나 values.yaml에 checksum/secrets 없음(시크릿 변경이 파드를 롤링 못 함)"; rc=1
    else
      got="$(sha256 "$sealed" | awk '{print $1}' | cut -c1-16)"
      if [ "$want" != "$got" ]; then
        echo "FAIL: $d checksum/secrets 불일치 — values.yaml=$want vs sha256($app-secrets.sealed.yaml)앞16=$got (재봉인 후 update-secrets 재실행 필요)"; rc=1
      fi
    fi
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

if [ "$rc" -eq 0 ]; then echo "check-app-deploy: 배포 계약(필수 산출물 + checksum/secrets↔봉인본 정합) OK"; fi
exit $rc
