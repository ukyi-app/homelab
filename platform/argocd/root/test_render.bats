#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; F="$ROOT/platform/argocd/root/appset.yaml"; }

@test "appset.yaml is valid yaml" {
  run yq e 'true' "$F"
  [ "$status" -eq 0 ]
}
@test "appset.yaml has exactly two ApplicationSets" {
  run bash -c "grep -c '^kind: ApplicationSet' '$F'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
@test "appset source paths are unchanged after comment edit" {
  run grep -c "apps/\*/deploy/prod" "$F"
  [ "$status" -eq 0 ]
}
