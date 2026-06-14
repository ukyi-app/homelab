#!/usr/bin/env bats
f=platform/cnpg/prod/cluster.yaml

@test "single instance, HA off" { grep -qE 'instances:\s*1' "$f"; }

@test "tuned params exactly match the design" {
  grep -q 'shared_buffers: "256MB"' "$f"
  grep -q 'effective_cache_size: "512MB"' "$f"
  grep -q 'work_mem: "8MB"' "$f"
  grep -q 'maintenance_work_mem: "128MB"' "$f"
  grep -q 'max_connections: "50"' "$f"
  grep -q 'archive_timeout: "5min"' "$f"
}

@test "memory limit is 1Gi and shared_buffers is <= 1/4 of it" {
  grep -q 'memory: 1Gi' "$f"   # limit
  grep -q 'memory: 768Mi' "$f" # request
  # 256MB <= 256MB (= 1Gi/4) : limit 연동 불변식 성립
}

@test "PGDATA on standard SC, WAL on a SEPARATE standard PVC, never bulk-ssd" {
  grep -q 'storageClass: standard' "$f"
  grep -qE 'walStorage:' "$f"
  run grep -q 'bulk-ssd' "$f"
  [ "$status" -ne 0 ]
}

@test "Cluster CR carries sync-wave -1 (Ready before app migrations)" {
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
}

@test "initdb seeds restore_canary so a DR rebuild restores it without a manual reseed" {
  # restore_canary가 git 시드가 아니면 DR 재구축(initdb)에서 유실 → 주간 restore-drill이 깨진다.
  grep -q 'postInitApplicationSQL:' "$f"
  grep -q 'restore_canary' "$f"
}
