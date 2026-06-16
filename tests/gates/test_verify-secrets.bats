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
