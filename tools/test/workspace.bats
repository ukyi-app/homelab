#!/usr/bin/env bats

@test "pnpm workspace globs the canonical members" {
  run yq '.packages' pnpm-workspace.yaml
  [[ "$output" == *"apps/*/src"* ]]
  [[ "$output" == *"platform/charts/*"* ]]
  [[ "$output" == *"tools"* ]]
}

@test "package.json pins pnpm@10 and exposes the DX scripts" {
  run jq -r '.packageManager' package.json
  [[ "$output" == pnpm@10* ]]
  run jq -r '.scripts | keys | join(",")' package.json
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"gen:app"* ]]
  [[ "$output" == *"verify:app"* ]]
  [[ "$output" == *"gen:env"* ]]
}
