#!/usr/bin/env bash
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 산출물(values.yaml·.bindings.json·source-repo·kustomization.yaml)을 강제.
# 필수 파일 목록은 tools/app-deploy-schema.json(.required)에서 읽는다(SSOT — 하드코딩 금지).
# source-repo 누락/공백이면 poll-ghcr가 그 앱을 update-image 폴링에서 영영 빠뜨린다 → fail-closed로 차단.
#
# ── 봉인 배선 all-or-none 불변식(sealed-wiring #01, design-r1 R-1 · design-r3 R-3) ──
# 네 사실이 전부 있거나 전부 없어야 한다(그 사이 부분 상태는 배포를 깨뜨린다):
#   S = <app>-secrets.sealed.yaml 존재 · E = values.yaml envFrom에 <app>-secrets secretRef ·
#   K = kustomization.yaml resources에 봉인본 등재 · C_present = values.yaml checksum/secrets annotation 존재
#   ① 상태 동치: (S∧E∧K∧C_present) ∨ (¬S∧¬E∧¬K∧¬C_present) — 혼합 14상태 거부
#   ② 값 정합:  S → C_match(annotation 값 == sha256(봉인본 원본 바이트) 앞16 — #277 재발 방지)
# 부분 상태의 실 파손: 봉인본만 지우고 envFrom 잔존 → ArgoCD가 Secret prune → 파드가 낡은 값으로 생존하다
# 재시작 사망 / 없는 파일 가리키는 resources 항목 → kustomize 렌더 파손.
#
# ── strict scope + 파일명 규약(sealed-wiring #02, design-r1 R-2) ──
# 봉인본에 scope 확대 어노테이션(namespace-wide/cluster-wide=true)이 있으면 거부 — 이름/네임스페이스 격리
# 붕괴(암호문 재사용). patch 어노테이션은 scope 아니라 통과. 또 앱 배포 디렉토리 봉인본은
# <app>-secrets.sealed.yaml 하나만 허용(규약 외 *.sealed.yaml 거부).
#
# 인자로 deploy/prod 디렉토리들을 받으면 그것만, 없으면 apps/*/deploy/prod 전체를 검사(인레포 앱 0개면 vacuous).
# bash 3.2 호환: `cmd && x`(set -e 함정)·mapfile·[[ ]] 금지 — if-블록·for로. yq는 버전차 함정이라 값 추출은 sed/grep으로.
# 현재 인레포 앱(page·trip-mate-api)은 각 봉인본 1개 — 앱당 <app>-secrets.sealed.yaml 단일 규약.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/tools/app-deploy-schema.json"
required="$(jq -r '.required[]' "$SCHEMA")"   # 개행구분 → for 워드분할

# 로컬(macOS shasum) ↔ CI(리눅스 sha256sum) 양립. yq는 버전차 함정이라 값 추출은 sed로.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

yn() { if [ "$1" -eq 1 ]; then echo "유"; else echo "무"; fi; }

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

  # 봉인 배선 불변식 — 앱 이름은 deploy/prod의 조부모 디렉토리명(apps/<app>/deploy/prod).
  app="$(basename "$(dirname "$(dirname "$d")")")"
  sealed="$d/$app-secrets.sealed.yaml"
  values="$d/values.yaml"
  kust="$d/kustomization.yaml"

  # S — 봉인본 존재
  s=0; if [ -f "$sealed" ]; then s=1; fi
  # E — envFrom에 <app>-secrets secretRef(name 줄이 <app>-secrets로 끝, 접미 conn 시크릿 db-*-conn과 구별).
  # 이 게이트는 손편집 표면을 정찰하므로 정당한 YAML 변형(선택적 따옴표)을 관용한다 — 무관용 시 정상 배선이
  # false-FAIL. app 이름은 DNS-label(소문자·하이픈)이라 정규식 메타문자 없음(APP_RE 강제).
  e=0
  if [ -f "$values" ] && grep -qE '^[[:space:]]+name:[[:space:]]*["'"'"']?'"$app"'-secrets["'"'"']?[[:space:]]*(#.*)?$' "$values" 2>/dev/null; then e=1; fi
  # K — kustomization.resources에 봉인본 등재
  k=0
  if [ -f "$kust" ] && grep -qE '^[[:space:]]*-[[:space:]]*["'"'"']?'"$app"'-secrets\.sealed\.yaml["'"'"']?[[:space:]]*(#.*)?$' "$kust" 2>/dev/null; then k=1; fi
  # C_present — checksum/secrets annotation 존재(값은 ②에서 정합 검사; sed로 16진값 추출, yq 함정 회피)
  want=""
  if [ -f "$values" ]; then
    want="$(sed -n -E 's/^[[:space:]]*checksum\/secrets:[[:space:]]*([0-9a-fA-F]+).*/\1/p' "$values")"
  fi
  cpresent=0; if [ -n "$want" ]; then cpresent=1; fi

  # ① 상태 동치 — 넷의 합이 0 또는 4가 아니면(=전부 같지 않으면) 부분 상태
  sum=$(( s + e + k + cpresent ))
  if [ "$sum" -ne 0 ] && [ "$sum" -ne 4 ]; then
    echo "FAIL: $d 봉인 배선 부분 상태 — S=$(yn "$s") E=$(yn "$e") K=$(yn "$k") C=$(yn "$cpresent") (all-or-none: 봉인본⇔envFrom<app>-secrets⇔kustomization등재⇔checksum/secrets 전부 있거나 전부 없어야 함)"; rc=1
  fi

  # ② 값 정합 — 봉인본과 checksum이 함께 있을 때만 재산출 대조(#277 회귀)
  if [ "$s" -eq 1 ] && [ "$cpresent" -eq 1 ]; then
    got="$(sha256 "$sealed" | awk '{print $1}' | cut -c1-16)"
    if [ "$want" != "$got" ]; then
      echo "FAIL: $d checksum/secrets 불일치 — values.yaml=$want vs sha256($app-secrets.sealed.yaml)앞16=$got (재봉인 후 update-secrets 재실행 필요)"; rc=1
    fi
  fi

  # ── strict scope 강제(sealed-wiring #02, design-r1 R-2) — 봉인 계약의 6번째 조항 ──
  # kubeseal은 namespace-wide/cluster-wide 어노테이션으로 복호화 범위를 넓힌다. 기대 name·namespace를
  # 그대로 두고 scope만 넓힌 봉인본은 배선 불변식을 전부 통과하면서 실제로는 아무 이름·아무 NS에서
  # 복호화된다(암호문 재사용 → 이름/네임스페이스 격리 붕괴). value가 truthy일 때만 실 위험(=strict 위반)이라
  # false/미설정은 통과. patch(sealedsecrets.bitnami.com/patch)는 scope 아님 — 키가 달라 애초에 미매치.
  if [ "$s" -eq 1 ] && grep -qiE 'sealedsecrets\.bitnami\.com/(namespace-wide|cluster-wide):[[:space:]]*["'"'"']?true["'"'"']?[[:space:]]*(#.*)?$' "$sealed" 2>/dev/null; then
    echo "FAIL: $d $app-secrets.sealed.yaml scope 확대 어노테이션(namespace-wide/cluster-wide=true) — strict scope 위반: 이름/네임스페이스 격리가 붕괴돼 암호문이 다른 Secret으로 재사용될 수 있다. kubeseal 기본(strict)로 재봉인 필요"; rc=1
  fi

  # ── 파일명 규약(sealed-wiring #02) — 앱 배포 디렉토리 봉인본은 <app>-secrets.sealed.yaml 하나뿐 ──
  # 규약 외 *.sealed.yaml은 kustomize 렌더가 죽기(resources 미참조 파일 방치·오참조) 전에 CI에서 차단.
  # (conn 봉인본은 platform/data-conn·platform/cnpg에 살아 여기 없다 — 오탐 없음.)
  for sf in "$d"/*.sealed.yaml; do
    [ -e "$sf" ] || continue   # glob 미매치 시 리터럴 → [ -e ]로 가드
    bn="$(basename "$sf")"
    if [ "$bn" != "$app-secrets.sealed.yaml" ]; then
      echo "FAIL: $d 에 규약 외 봉인본 '$bn' — 앱 배포 디렉토리 봉인본은 <app>-secrets.sealed.yaml 하나만 허용"; rc=1
    fi
  done
}

if [ "$#" -gt 0 ]; then
  for d in "$@"; do check_one "$d"; done
else
  cd "$ROOT"
  # 열거는 공유 워커의 `apps` 유닛 스코프가 소유한다. ⚠️ 그 스코프는 **필수 산출물로 거르지 않는다** —
  # 이 게이트가 잡아야 할 게 정확히 그 부재이기 때문이다(design-r1 R-1). deploy/prod 미존재는
  # 기존 `[ -d ]` 스킵과 동일하게 여기서 처리한다(행위 보존).
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ -d "$u/deploy/prod" ] || continue
    check_one "$u/deploy/prod"
  done < <(bun "$(dirname "$0")/../tools/lib/repo-walk.ts" --units apps --root "$ROOT")
fi

if [ "$rc" -eq 0 ]; then echo "check-app-deploy: 배포 계약(필수 산출물 + 봉인 배선 all-or-none + checksum 정합 + strict scope + 파일명 규약) OK"; fi
exit $rc
