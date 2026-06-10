#!/usr/bin/env bats
f=platform/cnpg/prod/pooler.yaml
@test "pooler is type rw on cluster pg" {
  grep -q 'type: rw' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "transaction pooling, sane sizing under max_connections=50" {
  grep -q 'pool_mode: transaction' "$f"
  grep -q 'max_client_conn:' "$f"
  grep -q 'default_pool_size:' "$f"
}
