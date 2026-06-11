#!/usr/bin/env bats
# M2 의존: platform/cnpg/prod/r2-creds.enc.yaml은 M2의 seed-secrets.sh가 생성한다
# (라이브, 실제 R2 자격증명 필요). 이 테스트들은 M2 실행 이후에만 통과한다.

f=platform/cnpg/prod/r2-creds.enc.yaml # M2 소유 — 여기서는 참조만

@test "M2 seed for cnpg-r2-creds exists" {
  [ -f "$f" ]
}
@test "seed is SOPS-encrypted (has sops metadata)" {
  run grep -q '^sops:' "$f"
  [ "$status" -eq 0 ]
}
@test "seed has NO plaintext AWS secret" {
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+[A-Za-z0-9/+]{20,}' "$f"
  [ "$status" -ne 0 ]
}
@test "seed Secret is named cnpg-r2-creds (canonical)" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+cnpg-r2-creds'"
  [ "$status" -eq 0 ]
}
@test "seed encrypts to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
@test "M4 does NOT author a duplicate R2 creds secret" {
  run bash -c "ls platform/cnpg/prod/object-store-creds.enc.yaml 2>/dev/null"
  [ "$status" -ne 0 ] # 예전 M4 소유 이름이 존재하면 안 된다
}
