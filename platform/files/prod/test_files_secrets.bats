#!/usr/bin/env bats
# files SealedSecret 회귀 가드(봉인 전엔 skip). @test 이름은 영어.
D="$BATS_TEST_DIRNAME"

@test "files-keys sealed secret has no plaintext data field" {
  [ -f "$D/files-keys.sealed.yaml" ] || skip "not sealed yet (owner-local)"
  run yq '.spec.encryptedData."keys.json" != null and .spec.template.type == "Opaque"' "$D/files-keys.sealed.yaml"
  [ "$output" = "true" ]
  # 구조적 yq로 평문(data/stringData) 부재 검증 (grep '[^n]data:'는 'metadata:' 오탐)
  run yq '(.data == null) and (.stringData == null) and ((.spec.template.data // null) == null) and ((.spec.template.stringData // null) == null)' "$D/files-keys.sealed.yaml"
  [ "$output" = "true" ]
}

@test "ghcr-pull sealed secret targets files namespace" {
  [ -f "$D/ghcr-pull.sealed.yaml" ] || skip "not sealed yet (owner-local)"
  run yq '.spec.template.metadata.namespace // .metadata.namespace' "$D/ghcr-pull.sealed.yaml"
  [ "$output" = "files" ]
}
