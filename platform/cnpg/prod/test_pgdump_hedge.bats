#!/usr/bin/env bats
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge writes a SEPARATE R2 prefix and prunes to 14 days" {
  grep -q 'r2:homelab-pg-backups-prod/pgdump/' "$f"
  grep -qE 'rclone delete .*--min-age 14d' "$f"
}
@test "hedge pulls rclone+aws creds from cnpg-r2-creds secret" {
  grep -q 'name: cnpg-r2-creds' "$f"
}

@test "hedge dumps as the managed superuser so it captures all objects (not just app-owned)" {
  # app 롤은 postgres 소유 객체(restore_canary 등)를 LOCK/덤프하지 못해 실패한다(라이브 검증).
  # 완전한 논리 백업은 superuser로 떠야 한다 — pg-app-credentials가 아니라 pg-superuser를 쓴다.
  grep -q 'name: pg-superuser' "$f"
  run grep -q 'name: pg-app-credentials' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/ukyi-app/pg-tools:16-rclone' "$f"
}

@test "hedge waits for pg-rw to be reachable before pg_dump (kube-router rule-install gap)" {
  # libpq는 첫 연결 거부에서 즉시 포기 — 새 파드의 첫 ClusterIP 접속이 kube-router 룰 설치 전
  # 갭에 떨어지면 RST(Connection refused)로 job이 실패한다(라이브 검증). 도달 대기 루프가 필요.
  grep -q '/dev/tcp/pg-rw.database.svc/5432' "$f"
}
