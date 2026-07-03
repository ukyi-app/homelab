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
# 역방향(AGENTS 인덱스 → 런북 파일): 인덱스에 나열된 각 *.md가 docs/runbooks/에 실재하는지.
# owner 머신(런북 실재)에서만 도달 — 위 skip 가드가 CI/fresh-checkout 배제. fail-closed(양방향).
# shellcheck disable=SC2016  # grep ERE 패턴은 의도적 리터럴(백틱·정규식) — 확장 아님
idx_md="$(sed -n '/## 런북/,$p' "$ROOT/AGENTS.md" | grep -oE '`[A-Za-z0-9./-]+\.md`' | tr -d '`' | sed 's#.*/##' | sort -u)"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -f "$RB/$m" ] || { echo "FAIL: AGENTS 인덱스에 있으나 런북 파일 부재: $m"; fail=1; }
done <<< "$idx_md"
[ "$fail" -eq 0 ] && echo "verify-runbook-index: 런북 인덱스 양방향 정합 OK"
exit "$fail"
