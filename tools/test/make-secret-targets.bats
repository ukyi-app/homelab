#!/usr/bin/env bats
# 시크릿 make 진입점 — secret-edit 가드 + seed-secrets의 .env.secrets source 통일(E6).
# secret-edit 해피패스는 인터랙티브($EDITOR)라 가드만 검사. dry-run/가드만이라 시크릿 무관.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "secret-edit requires FILE" {
  run make secret-edit
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "FILE"
}

@test "secret-edit rejects a non-enc.yaml FILE" {
  run make secret-edit FILE=README.md
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "enc.yaml"
}

@test "seed-secrets sources .env.secrets before running the seed script" {
  run make -n seed-secrets
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ".env.secrets"
  echo "$output" | grep -q "seed-secrets.sh"
}
