#!/usr/bin/env bats
WF=".github/workflows/bump.yaml"

teardown() { git checkout -- apps/api/deploy/prod/values.yaml 2>/dev/null || true; }

@test "bump rewrites only image.tag in the app's values.yaml" {
  before=$(yq '.kind' apps/api/deploy/prod/values.yaml)
  node tools/bump-tag.mjs api sha-deadbee
  run yq '.image.tag' apps/api/deploy/prod/values.yaml
  [[ "$output" == "sha-deadbee" ]]
  after=$(yq '.kind' apps/api/deploy/prod/values.yaml)
  [ "$before" == "$after" ] # 그 외에는 아무것도 안 바뀜
}

@test "bump is idempotent (second run is a no-op)" {
  node tools/bump-tag.mjs api sha-deadbee
  run node tools/bump-tag.mjs api sha-deadbee
  [[ "$output" == *"no-op"* || "$output" == *"unchanged"* ]]
}

@test "bump workflow is serialized via a single concurrency group" {
  run yq '.concurrency.group' "$WF"
  [ -n "$output" ]
  run yq '.concurrency.cancel-in-progress' "$WF"
  [[ "$output" == "false" ]] # 반쯤 끝난 write-back은 절대 취소하지 않는다
}
