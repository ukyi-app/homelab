#!/usr/bin/env bats
f=platform/cnpg/prod/pooler.yaml
@test "pooler is type rw on cluster pg" {
  grep -q 'type: rw' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "transaction pooling, sane sizing under max_connections=50" {
  grep -q 'poolMode: transaction' "$f"
  # 예약 파라미터 pool_mode가 parameters에 되살아나지 않게 가드 (webhook 거부 → sync 무한 루프)
  # 중간 위치라 `! grep`은 bats가 침묵 통과 → run+status로 강제(check-bats-style.sh).
  run grep -q 'pool_mode:' "$f"
  [ "$status" -ne 0 ]
  grep -q 'max_client_conn:' "$f"
  grep -q 'default_pool_size:' "$f"
}
@test "transaction pooler ignores client server-GUC startup params (libpq/node-pg compat)" {
  # statement_timeout 등을 무시하지 않으면 클라이언트 연결이 "unsupported startup parameter"로 거부됨
  grep -q 'ignore_startup_parameters:' "$f"
  grep -E 'ignore_startup_parameters:' "$f" | grep -q 'statement_timeout'
}
