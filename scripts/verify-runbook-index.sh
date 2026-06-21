#!/usr/bin/env bash
# 런북 인덱스 드리프트 로컬 가드 — docs/runbooks/(gitignored)에 .md가 있으면 AGENTS.md 런북 인덱스와 일치.
# 런북은 비공개 로컬이라 CI/repo엔 부재 → skip(required gate 아님). cf. verify-runbooks=DR bats 러너(별도, 불변).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RB="$ROOT/docs/runbooks"
shopt -s nullglob
files=("$RB"/*.md)
if [ ${#files[@]} -eq 0 ]; then echo "verify-runbook-index: 런북 부재(gitignored 로컬) — skip"; exit 0; fi
fail=0
for f in "${files[@]}"; do
  b="$(basename "$f")"
  case "$b" in test_*) continue;; esac
  grep -Fq "$b" "$ROOT/AGENTS.md" || { echo "FAIL: AGENTS 런북 인덱스에 누락: $b"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "verify-runbook-index: 런북 인덱스 정합 OK"
exit "$fail"
