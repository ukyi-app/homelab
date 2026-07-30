#!/usr/bin/env bash
# 메모리 원장 예산 게이트 SSOT — ledger 마크다운을 JSON으로 변환해 conftest 정책으로 검사.
# 변환은 bun(tools/ledger-to-json.ts, 행 파서 SSOT=lib/ledger-totals.ts).
# package.json(verify:ledger)·Makefile(verify)·make ci·ci.yaml gate가 모두 이 스크립트를 호출한다.
# (ledger 게이트는 required gate 한 곳 — ci.yaml의 `bun run verify:ledger`가 이 스크립트를 부른다.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bun "$ROOT/tools/ledger-to-json.ts" "$ROOT/docs/memory-ledger.md" > /tmp/ledger.json
conftest test /tmp/ledger.json --policy "$ROOT/policy/ledger.rego"
