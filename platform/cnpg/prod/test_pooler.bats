#!/usr/bin/env bats
f=platform/cnpg/prod/pooler.yaml
@test "pooler is type rw on cluster pg" {
  grep -q 'type: rw' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "transaction pooling, sane sizing under max_connections=50" {
  grep -q 'poolMode: transaction' "$f"
  # 예약 파라미터 pool_mode가 parameters에 되살아나지 않게 가드 (webhook 거부 → sync 무한 루프)
  ! grep -q 'pool_mode:' "$f"
  grep -q 'max_client_conn:' "$f"
  grep -q 'default_pool_size:' "$f"
}
