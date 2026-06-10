#!/usr/bin/env bats

teardown() { rm -rf apps/foo; git checkout -- .github/workflows/build.yaml 2>/dev/null || true; }

@test "gen:app scaffolds a renderable app and a CI matrix entry" {
  run node tools/gen-app.mjs foo --kind api
  [ "$status" -eq 0 ]
  [ -f apps/foo/deploy/prod/values.yaml ]
  [ -f apps/foo/Dockerfile ]
  run helm template foo platform/charts/app -f apps/foo/deploy/prod/values.yaml
  [ "$status" -eq 0 ]
  run yq '.jobs.build.strategy.matrix.app[]' .github/workflows/build.yaml
  [[ "$output" == *"foo"* ]]
}

@test "verify:app reports per-link status and names the red link" {
  run node tools/verify-app.mjs api --dry-run
  [[ "$output" == *"build"* ]]
  [[ "$output" == *"push"* ]]
  [[ "$output" == *"tag"* ]]
  [[ "$output" == *"sync"* ]]
  [[ "$output" == *"probe"* ]]
  [[ "$output" == *"route"* ]]
  [[ "$output" == *"secret"* ]]
}
