#!/usr/bin/env bash
# 추적 *.enc.yaml 무결성 검사 — 암호화됨 + age recipient 신원이 canonical(cluster+recovery)과 정확 일치 +
# (age 키 있으면) 복호 가능. 시크릿 값은 절대 출력하지 않는다(메타/키 이름만).
# age 키 없으면 복호 단계만 스킵 → CI(키 없음)에서도 구조 검사는 수행한다(평문 누출/recipient 신원 드리프트 차단).
# 인자가 있으면 그 파일들만, 없으면 추적 *.enc.yaml 전수 검사.
set -euo pipefail

age_key="${SOPS_AGE_KEY_FILE:-}"
can_decrypt=0
if [ -n "$age_key" ] && [ -f "$age_key" ]; then can_decrypt=1; fi

# canonical age recipient(공개키) — .sops.yaml _recipients 앵커. 개수가 아니라 신원을 강제해
# recovery 키 스왑/드롭(개수는 2 유지)이 통과하는 갭을 닫는다(DR 복호 불능 방지). 정렬 집합 비교.
# shellcheck source=scripts/lib/sops-recipients.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sops-recipients.sh"
CANON="$(sops_canonical_recipients)"

fail=0

check_one() {
  local f="$1" got
  if [ ! -f "$f" ]; then echo "FAIL $f: 파일 없음"; return 1; fi
  if ! yq -e '.sops != null' "$f" >/dev/null 2>&1; then
    echo "FAIL $f: SOPS 암호화 아님(.sops 메타 없음 — 평문 누출 의심)"; return 1
  fi
  if [ -z "$CANON" ]; then
    echo "FAIL $f: .sops.yaml canonical recipient를 읽지 못함"; return 1
  fi
  got="$(sops_file_recipients "$f")"
  if [ "$got" != "$CANON" ]; then
    echo "FAIL $f: recipient 신원이 canonical(cluster+recovery)과 불일치 — 스왑/recovery 드롭"; return 1
  fi
  if [ "$can_decrypt" = "1" ]; then
    if ! sops -d "$f" >/dev/null 2>&1; then
      echo "FAIL $f: 복호 실패(키 불일치/recipient 드리프트)"; return 1
    fi
    echo "OK   $f (암호화 · recipient canonical · 복호가능)"
  else
    echo "OK   $f (암호화 · recipient canonical · 복호검사 스킵: SOPS_AGE_KEY_FILE 없음)"
  fi
  return 0
}

if [ "$#" -gt 0 ]; then
  for f in "$@"; do check_one "$f" || fail=1; done
else
  # ⚠️ 전수 모드는 (a) `git ls-files`가 **cwd 상대**라 ROOT로 내려가야 하고(서브디렉토리에서 실행하면
  # 0건이었다), (b) 열거 실패를 rc로 잡아야 한다(프로세스 치환이 삼켰다). 둘 다 라이브 재현됨 —
  # `cd docs && bash ../scripts/verify-secrets.sh` → "모든 *.enc.yaml 무결성 OK" rc=0.
  # 0건이면 recipient canonical 검사까지 함께 무발화된다(이중 vacuity). 현재 추적 9건 — 래칫 아님.
  # shellcheck source=scripts/lib/scan-floor.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/scan-floor.sh"
  cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
  tracked="$(scan_enumerate verify-secrets git ls-files '*.enc.yaml')" || exit 1
  scanned="$(scan_count "$tracked")"
  scan_floor verify-secrets "$scanned" "${VERIFY_SECRETS_MIN_SCAN:-6}" || exit 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    check_one "$f" || fail=1
  done <<< "$tracked"
fi

if [ "$fail" -ne 0 ]; then echo "verify-secrets: 무결성 검사 실패" >&2; exit 1; fi
echo "verify-secrets: 모든 *.enc.yaml 무결성 OK${scanned:+ (${scanned}건 스캔)}"
