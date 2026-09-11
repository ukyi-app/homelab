#!/usr/bin/env bash
# 메모리 원장 예산 게이트 SSOT — ledger 마크다운을 JSON으로 변환해 conftest 정책으로 검사.
# 변환은 bun(tools/ledger-to-json.ts, 행 파서 SSOT=lib/ledger-totals.ts).
# package.json(verify:ledger)·justfile(verify)·just ci·ci.yaml gate가 모두 이 스크립트를 호출한다.
# (ledger 게이트는 required gate 한 곳 — ci.yaml의 `bun run verify:ledger`가 이 스크립트를 부른다.)
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다 —
# 이 파일의 `$(dirname "$0")` 기반 ROOT가 형제들과 갈리던 비대칭의 소멸 지점이다.
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init verify-ledger
# 산출물은 실행 단위 임시 디렉토리에 둔다 — 고정 `/tmp/ledger.json`은 이 게이트를 동시에 부르는 프로세스
# (bats 병렬 레인의 test_ledger·test_ledger-gate·verify-ledger-ssot)끼리 서로의 파일을 덮어 쓴다.
# 파일명은 ledger.json을 유지한다(conftest가 확장자로 파서를 고른다).
out="$(mktemp -d "${TMPDIR:-/tmp}/verify-ledger.XXXXXX")"
trap 'rm -rf "$out"' EXIT
bun "$ROOT/tools/ledger-to-json.ts" "$ROOT/docs/memory-ledger.md" > "$out/ledger.json"
conftest test "$out/ledger.json" --policy "$ROOT/policy/ledger.rego"
