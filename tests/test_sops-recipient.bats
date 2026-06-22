#!/usr/bin/env bats
# SOPS recipient 신원 게이트 — recipient '개수'가 아니라 canonical(cluster+recovery) '신원'을 강제해
# recovery 키 스왑/드롭(개수 2 유지)이 통과하는 갭을 닫는다. yq만(age 불요) → run-bats gate 자동 수집.
# @test 이름은 영어(CJK 인코딩 함정). age recipient는 공개키라 fixture 등재 안전(.sops.yaml 주석).

SOPS_GUARD="${BATS_TEST_DIRNAME}/../scripts/sops-guard.sh"
CLUSTER="age1n3j7p70f0unl5dgrjhtr9jxrdntz2a67dtntu446qus9c3jd3fnsp8z960"
RECOVERY="age154tu9q7922xu46x0rkfm5l9x3ulf9u5at5qvxeaqfx9sgtm7cumq75jdwc"

_fixture() { # $1=dir $2=recipient1 $3=recipient2
  cat > "$1/x.enc.yaml" <<YAML
data:
  foo: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
sops:
  mac: ENC[AES256_GCM,data:mmm,type:str]
  lastmodified: "2026-01-01T00:00:00Z"
  age:
    - recipient: $2
      enc: x
    - recipient: $3
      enc: y
YAML
}

@test "sops-guard accepts the canonical cluster+recovery recipient set" {
  tmp="$(mktemp -d)"
  _fixture "$tmp" "$CLUSTER" "$RECOVERY"
  run bash "$SOPS_GUARD" "$tmp/x.enc.yaml"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "sops-guard rejects a non-canonical recipient set (count 2 but swapped/dropped)" {
  tmp="$(mktemp -d)"
  _fixture "$tmp" "$CLUSTER" "age1wrong00000000000000000000000000000000000000000000000000000"
  run bash "$SOPS_GUARD" "$tmp/x.enc.yaml"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}
