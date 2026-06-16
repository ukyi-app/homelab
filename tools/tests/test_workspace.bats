#!/usr/bin/env bats

@test "pnpm workspace globs the canonical members (no in-repo apps)" {
  run yq '.packages' pnpm-workspace.yaml
  [[ "$output" != *"apps/"* ]] # 인-레포 앱 없음 — 앱은 외부 레포
  [[ "$output" == *"platform/charts/*"* ]]
  [[ "$output" == *"tools"* ]]
}

@test "package.json pins pnpm@11 and exposes the platform gates" {
  run jq -r '.packageManager' package.json
  [[ "$output" == pnpm@11* ]]
  run jq -r '.scripts | keys | join(",")' package.json
  [[ "$output" == *"verify:ledger"* ]]
  [[ "$output" == *"verify:skeleton"* ]]
  # 인-레포 앱 DX(gen:app/verify:app/gen:env)는 외부 레포 체제로 전환하며 제거됨
  [[ "$output" != *"gen:app"* ]]
}
