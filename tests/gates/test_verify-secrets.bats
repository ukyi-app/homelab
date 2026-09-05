#!/usr/bin/env bats
# verify-secrets.sh — 추적 *.enc.yaml 무결성(암호화 + recipient 2개 + 복호가능).
# 구조 검사는 age 키 없이도 동작(CI 안전) → 평문 누출/recipient 드리프트를 게이트로 차단.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. 시크릿 값은 절대 단언/출력 금지.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "verify-secrets passes structural check on all committed enc.yaml" {
  run bash scripts/verify-secrets.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "무결성 OK"
}

@test "verify-secrets flags a non-encrypted (plaintext) enc.yaml" {
  printf 'foo: bar\n' > "$TMP/leak.enc.yaml"
  run bash scripts/verify-secrets.sh "$TMP/leak.enc.yaml"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "FAIL"
}

@test "verify-secrets never prints encrypted/secret payloads" {
  run bash scripts/verify-secrets.sh
  [ "$status" -eq 0 ]
  # sops 페이로드는 ENC[ 접두를 가진다 — 출력에 한 건도 새면 안 됨
  ! echo "$output" | grep -q "ENC\["
}

@test "verify-secrets rejects a non-canonical recipient set (count 2 but swapped)" {
  # tests/test_sops-recipient.bats의 관용구 그대로 — sops-guard.sh는 이 경로를 이미 증인화하지만
  # verify-secrets.sh는 line 37의 신원 비교를 독립 배선하므로 자기 도메인 bats가 따로 필요하다.
  CLUSTER="age1n3j7p70f0unl5dgrjhtr9jxrdntz2a67dtntu446qus9c3jd3fnsp8z960"
  cat > "$TMP/x.enc.yaml" <<YAML
data:
  foo: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
sops:
  mac: ENC[AES256_GCM,data:mmm,type:str]
  lastmodified: "2026-01-01T00:00:00Z"
  age:
    - recipient: $CLUSTER
      enc: x
    - recipient: age1wrong00000000000000000000000000000000000000000000000000000
      enc: y
YAML
  run bash scripts/verify-secrets.sh "$TMP/x.enc.yaml"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'recipient 신원이'
}
