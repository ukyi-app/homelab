#!/usr/bin/env bash
# 추적 *.enc.yaml 무결성 검사 — 암호화됨 + age recipient 정확히 2개(cluster+recovery) +
# (age 키 있으면) 복호 가능. 시크릿 값은 절대 출력하지 않는다(메타/키 이름만).
# age 키 없으면 복호 단계만 스킵 → CI(키 없음)에서도 구조 검사는 수행한다(평문 누출/recipient 드리프트 차단).
# 인자가 있으면 그 파일들만, 없으면 추적 *.enc.yaml 전수 검사.
set -euo pipefail

age_key="${SOPS_AGE_KEY_FILE:-}"
can_decrypt=0
if [ -n "$age_key" ] && [ -f "$age_key" ]; then can_decrypt=1; fi

fail=0

check_one() {
  local f="$1" n
  if [ ! -f "$f" ]; then echo "FAIL $f: 파일 없음"; return 1; fi
  if ! yq -e '.sops != null' "$f" >/dev/null 2>&1; then
    echo "FAIL $f: SOPS 암호화 아님(.sops 메타 없음 — 평문 누출 의심)"; return 1
  fi
  n="$(yq '.sops.age | length' "$f" 2>/dev/null || echo 0)"
  if [ "$n" != "2" ]; then
    echo "FAIL $f: age recipient=$n (cluster+recovery=2 기대 — recipient 드리프트)"; return 1
  fi
  if [ "$can_decrypt" = "1" ]; then
    if ! sops -d "$f" >/dev/null 2>&1; then
      echo "FAIL $f: 복호 실패(키 불일치/recipient 드리프트)"; return 1
    fi
    echo "OK   $f (암호화 · recipient 2 · 복호가능)"
  else
    echo "OK   $f (암호화 · recipient 2 · 복호검사 스킵: SOPS_AGE_KEY_FILE 없음)"
  fi
  return 0
}

if [ "$#" -gt 0 ]; then
  for f in "$@"; do check_one "$f" || fail=1; done
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    check_one "$f" || fail=1
  done < <(git ls-files '*.enc.yaml')
fi

if [ "$fail" -ne 0 ]; then echo "verify-secrets: 무결성 검사 실패" >&2; exit 1; fi
echo "verify-secrets: 모든 *.enc.yaml 무결성 OK"
