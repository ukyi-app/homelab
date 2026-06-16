#!/usr/bin/env bash
# docs/traps.md enforcement 원장 드리프트 가드 — 원장이 '강제됐다'며 가리키는 guard 파일
# (백틱으로 감싼, 가드 확장자로 끝나는 경로)이 실재하는지 검사. 가드 파일이 삭제/리네임됐는데
# 원장이 enforced로 남아있는 거짓 안심을 차단(KD-4). doc-only 함정(guard 경로 없음)은 대상 아님.
# 인자로 원장 경로를 덮어쓸 수 있다(테스트용). 순수 파일 존재 검사 — 라이브 무관.
set -euo pipefail

LEDGER="${1:-docs/traps.md}"
[ -f "$LEDGER" ] || { echo "verify-traps: $LEDGER 없음" >&2; exit 1; }

fail=0
# shellcheck disable=SC2016  # 백틱은 의도된 리터럴 매칭(명령 치환 아님)
paths="$(grep -oE '`[^`]+`' "$LEDGER" | tr -d '`' | grep -E '\.(bats|sh|rego|mjs|ya?ml|json)$' | sort -u)"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$p" ] || { echo "FAIL: 원장이 가리키는 가드 부재: $p"; fail=1; }
done <<< "$paths"

if [ "$fail" -ne 0 ]; then echo "verify-traps: 가드 드리프트 발견(enforced인데 파일 없음)" >&2; exit 1; fi
echo "verify-traps: 원장의 모든 guard 경로 실재 OK"
