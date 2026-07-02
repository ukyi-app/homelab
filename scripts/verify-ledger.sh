#!/usr/bin/env bash
# 메모리 원장 예산 게이트 SSOT — ledger 마크다운을 JSON으로 변환해 conftest 정책으로 검사.
# 변환은 bun(tools/ledger-to-json.ts, 행 파서 SSOT=lib/ledger-totals.ts).
# package.json(verify:ledger)·Makefile(verify)·make ci·ci.yaml gate가 모두 이 스크립트를 호출한다.
# (verify.yaml의 ledger는 #53 W7로 required gate에 일원화 — 직접 호출 안 함.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bun "$ROOT/tools/ledger-to-json.ts" "$ROOT/docs/memory-ledger.md" > /tmp/ledger.json
conftest test /tmp/ledger.json --policy "$ROOT/policy/ledger.rego"
