#!/usr/bin/env bats
# files 베스포크 이미지 핀 레인 계약: source-repo + .image-pin.json이 deployment.yaml 인라인 핀을
# 정확히 가리키는지 회귀 가드(bump-poll 2차 순회 전제). jq/yq-only(CI-safe). @test 이름 영어.
setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "source-repo binds files to its ukyi-app repo (poll-ghcr discovery key)" {
  run cat "$C/source-repo"
  [ "$output" == "ukyi-app/files" ]
}

@test "image-pin descriptor points at the deployment inline image scalar" {
  run jq -r '.file' "$C/.image-pin.json"
  [ "$output" == "deployment.yaml" ]
  run jq -c '.path' "$C/.image-pin.json"
  [ "$output" == '["spec","template","spec","containers",0,"image"]' ]
}

@test "descriptor path resolves to a repo:sha@digest inline pin in deployment.yaml" {
  run yq '.spec.template.spec.containers[0].image' "$C/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '^ghcr\.io/ukyi-app/files:sha-[0-9a-f]{7,40}@sha256:[0-9a-f]{64}$'
}

@test "descriptor autoDeploy is a boolean the fail-closed gate can read" {
  run jq -e '.autoDeploy | type == "boolean"' "$C/.image-pin.json"
  [ "$status" -eq 0 ]
}
