#!/usr/bin/env bash
# 전 bats 도메인 accounting 가드 (F6 클래스 차단 — 테스트가 어느 harness에도 안 묶여 조용히 죽음).
# 모든 추적 test_*.bats는 **정확히 한 도메인**에 배정돼야 한다:
#   ① gate        — scripts/run-bats.sh --list 에 포함(required gate가 수집·실행)
#   ② chart-test  — platform/charts/app/tests/ 하위(make chart-test 별도 harness)
#   ③ .ci-exclude — not-CI-safe 레지스트리(주석이 실행처 iac/manual/age/docker 명시)
# 매치 수 ≠ 1 → 실패(0=고아, 2+=이중소유). + .ci-exclude 유효성: (a) git-tracked 실재, (b) gate 미포함(모순).
# bash 3.2 호환: mapfile·[[ ]]·`cmd && n++`(set -e 함정) 금지 — if-블록·case·카운터로.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# gate 도메인 = run-bats --list (공백구분 문자열로 멤버십 검사)
GATE=" $(./scripts/run-bats.sh --list | tr '\n' ' ') "
in_gate() { case "$GATE" in *" $1 "*) return 0;; *) return 1;; esac; }

# .ci-exclude 도메인 (공백구분)
EXCL=" "
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  EXCL="$EXCL$line "
done < tests/.ci-exclude
in_excl() { case "$EXCL" in *" $1 "*) return 0;; *) return 1;; esac; }

rc=0
# (1) 모든 추적 test_*.bats가 정확히 한 도메인
while IFS= read -r f; do
  n=0
  if in_gate "$f"; then n=$((n + 1)); fi
  case "$f" in platform/charts/app/tests/*) n=$((n + 1));; esac
  if in_excl "$f"; then n=$((n + 1)); fi
  if [ "$n" -ne 1 ]; then
    echo "FAIL: $f 가 정확히 한 도메인에 없음 (매치=$n; 0=고아, 2+=이중소유)"
    rc=1
  fi
done < <(git ls-files '*test_*.bats')

# (2) .ci-exclude 유효성: 실재 추적 파일 & gate 미포함(제외인데 gate면 모순)
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  if ! git ls-files --error-unmatch "$line" >/dev/null 2>&1; then
    echo "FAIL: .ci-exclude 항목이 추적 파일 아님: $line"; rc=1
  fi
  if in_gate "$line"; then
    echo "FAIL: .ci-exclude 항목이 gate에도 포함(모순): $line"; rc=1
  fi
done < tests/.ci-exclude

if [ "$rc" -eq 0 ]; then echo "check-bats-accounting: 전 bats가 정확히 한 도메인(gate/chart-test/.ci-exclude) OK"; fi
exit $rc
